#!/usr/bin/env python3
"""Clear COMIMAGE_FLAGS_ILONLY in a .NET PE's CLR header (in place). Usage: strip-ilonly.py file.exe"""
import struct, sys
p = sys.argv[1]; d = bytearray(open(p, 'rb').read())
e = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, e + 6)[0]; optsz = struct.unpack_from('<H', d, e + 20)[0]
o = e + 24; magic = struct.unpack_from('<H', d, o)[0]
entry = struct.unpack_from('<I', d, o + 16)[0]
dirs = o + (112 if magic == 0x20b else 96)
clr_rva, clr_sz = struct.unpack_from('<II', d, dirs + 14 * 8)
assert clr_rva, "not a .NET image (no CLR header)"
so = o + optsz
secs = [struct.unpack_from('<8sIIII', d, so + i * 40) for i in range(nsec)]
def off(rva):
    for n, vs, va, rs, ro in secs:
        if va <= rva < va + max(vs, rs): return ro + rva - va
fo = off(clr_rva) + 16
flags = struct.unpack_from('<I', d, fo)[0]
print(f"magic={magic:#x} entry_rva={entry:#x} clr_flags={flags:#x}")
if magic != 0x20b or entry != 0:
    print("NOTE: build with /platform:x64 so the entry point RVA is 0 (that is the failing shape)")
struct.pack_into('<I', d, fo, flags & ~1)
open(p, 'wb').write(d)
print(f"cleared ILONLY -> clr_flags={flags & ~1:#x}")
