# Wine loader fix: managed executables without the IL-only flag

**Symptom.** Overwolf 0.311's `OverwolfBrowser.exe` (its CEF subprocess host) dies instantly under every
Proton/Wine with:

```
Unhandled exception: page fault on execute access to 0x0000000140000000 in 64-bit code
```

Overwolf's main client then shows "Utility: Network Service process exit (exit code:-1073741819)" dozens of
times and gives up. Overwolf refuses to start if any of its own files are modified, so this cannot be fixed
on the Overwolf side.

**Cause.** The file is a PE32+ .NET assembly whose CLR header has `Flags = 0x8` (strong-name signed, **not**
`COMIMAGE_FLAGS_ILONLY`), `AddressOfEntryPoint = 0`, and an import table rewritten to import only
`owutils.dll!CreateHooker`. Windows' loader hands **every** image with a COM descriptor directory to
`mscoree` (`LdrpCorValidateImage` / `LdrpCorReplaceStartContext`), regardless of the IL-only flag. Wine only
does that for IL-only images (`LDR_COR_ILONLY`, from `server/mapping.c` setting `ComPlusILOnly` only when
`COMIMAGE_FLAGS_ILONLY` is set), so it resolves the imports and then jumps to entry point 0, i.e. the
image base, which is the (non-executable) PE header.

**Fix.** `ntdll-cor-entry.patch` adds `fixup_cor_entry()` to `dlls/ntdll/loader.c`: when the main image is
a COR image (`LDR_COR_IMAGE`) with a zero entry point and is not IL-only, resolve its imports normally and
then use mscoree's `_CorExeMain` as the entry point. IL-only images keep the existing path. 39 lines.

**Reproducer.** `../repro/` builds a hello-world x64 assembly, clears the IL-only bit and shows the crash on
stock Wine and the fix with the patch (`make-repro.sh`).

**Prebuilt.** `../prebuilt/UMU-Proton-10.0-4/ntdll.dll` was built with `build-ntdll.sh` from
ValveSoftware/wine commit `b8fdff8e1f855b5276ec4ddca0f31b2792554322` (the wine submodule of
Proton 10.0-4 and UMU-Proton-10.0-4) plus this patch, with mingw-w64 gcc 16.2. The PE/unix split means only
the Windows-side `ntdll.dll` changes; the unix `ntdll.so` from the Proton build is untouched. The DLL only
matches that exact Proton build (the syscall table is generated from the same sources); for another build,
run `build-ntdll.sh` with that build's wine commit.

**License.** Wine is LGPL-2.1-or-later; this patch and the prebuilt DLL are distributed under the same
license. Source: the commit above plus `ntdll-cor-entry.patch`.

Upstream status: see `../docs/wine-bug-report.md` (bug report + merge request text).
