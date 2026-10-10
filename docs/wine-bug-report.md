# Upstream submission drafts (WineHQ)

Two pieces: a Bugzilla report (https://bugs.winehq.org) and a merge request against
https://gitlab.winehq.org/wine/wine with the patch. File the bug first, then reference it in the MR with a
`Wine-Bug:` trailer. Replace the placeholders in angle brackets. Attach `hello-noilonly.exe` built with
`repro/make-repro.sh` (or describe the build) and the patch.

---

## 1. Bugzilla

**Product:** Wine  **Component:** ntdll  **Version:** 10.0 (also reproduced on 11.0-based Proton Experimental and git master as of 2026-10)
**Hardware:** x86-64  **OS:** Linux  **Severity:** normal  **Keywords:** download, regression? (no: never worked)

**Summary:**
ntdll: managed (CLR) executables that are not IL-only and have AddressOfEntryPoint == 0 crash at the image base instead of being started through mscoree (Overwolf 0.311 OverwolfBrowser.exe)

**Description:**

Windows' loader (LdrpInitializeProcess) hands every image that has a COM descriptor directory to mscoree:
LdrpCorValidateImage, then LdrpCorReplaceStartContext replaces the start address with _CorExeMain. It does
this regardless of COMIMAGE_FLAGS_ILONLY.

Wine only takes the mscoree path for IL-only images: server/mapping.c sets IMAGE_FLAGS_ComPlusILOnly only
when the CLR header has COMIMAGE_FLAGS_ILONLY, and dlls/ntdll/loader.c (loader_init / build_module) calls
fixup_imports_ilonly() only for LDR_COR_ILONLY modules. A PE32+ managed executable whose CLR header lacks
ILONLY (for example because a post-build tool added a native import) has AddressOfEntryPoint == 0, so Wine
resolves its imports and then jumps to the image base:

  Unhandled exception: page fault on execute access to 0x0000000140000000 in 64-bit code (0x00000140000000).
  Backtrace:
  =>0 0x00000140000000 EntryPoint() in overwolfbrowser
    1 0x006fffffec1649 in kernel32 (+0x11649)
    2 0x006ffffff40e0f in ntdll (+0x10e0f)

Real-world case: Overwolf 0.311.0.6's OverwolfBrowser.exe (its CEF subprocess host) is a strong-name signed
PE32+ assembly with CLR flags 0x8 (COMIMAGE_FLAGS_STRONGNAMESIGNED only), entry point 0, and an import
table containing only owutils.dll!CreateHooker. Every Overwolf subprocess dies with 0xC0000005 and the
client is unusable. Overwolf refuses to start if its files are modified, so the IL-only bit cannot be set
on the file as a workaround.

**Steps to reproduce** (self-contained, no Overwolf needed):

1. In a prefix with .NET Framework 4.8 (winetricks dotnet48; csc.exe is only needed to build the file):
     csc /platform:x64 /out:hello.exe Hello.cs
   where Hello.cs is:  class H { static int Main() { System.Console.WriteLine("hello"); return 0; } }
   An x64 build gives AddressOfEntryPoint = 0 and CLR flags 0x1 (ILONLY). It runs fine.
2. Clear the ILONLY bit in the CLR header (IMAGE_COR20_HEADER.Flags &= ~1); the attached strip-ilonly.py does
   this. The file is now exactly the shape of OverwolfBrowser.exe: COR header present, not ILONLY, entry 0.
3. wine hello.exe

**Actual:** page fault on execute access at the image base (0x140000000).
**Expected:** "hello" (Windows runs it; the OS loader routes any COR image through mscoree).

Reproduced with wine-mono and with real .NET Framework 4.8 as the runtime; the crash happens in ntdll before
either is involved.

**Proposed fix** (attached, 39 lines, dlls/ntdll/loader.c): after the normal fixup_imports() of the main
image, if the module is a COR image (LDR_COR_IMAGE) and its AddressOfEntryPoint is 0, load mscoree.dll and
use its _CorExeMain as the entry point. IL-only images keep the existing fixup_imports_ilonly() path;
mixed-mode images with a native entry point are unaffected. Tested on Proton 10.0-4's wine
(b8fdff8e): the reproducer prints hello and Overwolf 0.311 runs (CEF subprocesses start, "Browser subprocess
preflight: Ok").

Attachments: 0001-ntdll-Start-COR-images-without-ILONLY-through-mscoree.patch, hello-noilonly.exe, strip-ilonly.py

---

## 2. Merge request (gitlab.winehq.org/wine/wine)

Create the commit on current master (the hunk applies there; `fixup_imports_ilonly` and `loader_init` are
unchanged since 10.0):

    git clone https://gitlab.winehq.org/wine/wine && cd wine
    git apply ../alecaframe-linux/wine-patch/ntdll-cor-entry.patch
    git commit -as

**Commit message:**

    ntdll: Start managed executables that are not IL-only through mscoree.

    The Windows loader routes every image that has a COM descriptor directory
    through mscoree (_CorExeMain), not only IL-only ones. A PE32+ managed
    executable whose CLR flags lack COMIMAGE_FLAGS_ILONLY (e.g. one with a
    native import added by a post-build tool) has AddressOfEntryPoint == 0;
    Wine resolved its imports and then jumped to the image base.

    Resolve such an image's imports normally and then use _CorExeMain as its
    entry point, like the IL-only path does. Fixes Overwolf 0.311's
    OverwolfBrowser.exe.

    Wine-Bug: https://bugs.winehq.org/show_bug.cgi?id=<NNNNN>
    Signed-off-by: <Your Name> <you@example.com>

**MR description:** same text as the bug's description plus "Reproducer and analysis in the bug."
Reviewers will likely ask (a) whether build_module() should get the same treatment for DLLs with a COR
header and no entry point (not needed for the reported case: managed DLLs are loaded by the runtime, not
via LdrLoadDll's entry point), and (b) for a conformance test. A test can be added to dlls/kernel32/tests
or dlls/mscoree/tests by generating the stripped-ILONLY image at test time; happy to follow up if asked.

---

## 3. Courtesy note for the upstream guide author (gist comment)

> Hi, thanks for this guide; it got AlecaFrame working for me on Nobara. I've packaged a setup script around
> the same approach (container re-entry, OOPO/overlay/manifest self-heal; the code is my own implementation,
> your findings are credited) at <repo URL>, given away free under MIT. Two additions you may find useful: Overwolf 0.311's
> OverwolfBrowser.exe now crashes in Wine's loader (non-ILONLY managed exe with entry point 0); I have a Wine
> patch for it in the repo and am submitting it upstream. And the overlay's --game-pid is a Windows PID, so
> the dead-pid reaper check kills every overlay on Linux. If you'd rather I not reuse your pieces, or want a
> different attribution, tell me and I'll change it.
