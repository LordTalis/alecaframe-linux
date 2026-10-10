// Minimal reproducer for the Wine loader issue (see ../wine-patch/README.md).
// Build as x64 so csc emits AddressOfEntryPoint = 0, then strip the IL-only flag with strip-ilonly.py.
using System;
class Hello { static int Main() { Console.WriteLine("hello from a managed exe without COMIMAGE_FLAGS_ILONLY"); return 0; } }
