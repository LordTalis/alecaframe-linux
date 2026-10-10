#!/bin/bash
# Build the patched 64-bit ntdll.dll from the exact Wine commit a Proton build was made from.
#
# Needs: git, gcc, make, flex, bison, autoconf, perl, python3, mingw64-gcc (x86_64-w64-mingw32-gcc).
# Usage: ./build-ntdll.sh <wine commit sha> [workdir]
#   UMU-Proton-10.0-4 / Proton 10.0-4 = b8fdff8e1f855b5276ec4ddca0f31b2792554322
#   (find it: https://api.github.com/repos/Open-Wine-Components/umu-proton/contents/wine?ref=<tag>)
set -eu
SHA="${1:?wine commit sha}"; WORK="${2:-$PWD/wine-build-work}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$WORK"; cd "$WORK"
if [ ! -d wine ]; then
    mkdir wine && cd wine && git init -q && git remote add origin https://github.com/ValveSoftware/wine.git
    git fetch -q --depth 1 origin "$SHA" && git checkout -q FETCH_HEAD && cd ..
fi
cd wine
git apply --check "$HERE/ntdll-cor-entry.patch" 2>/dev/null && git apply "$HERE/ntdll-cor-entry.patch"
grep -q fixup_cor_entry dlls/ntdll/loader.c || { echo "patch not applied"; exit 1; }
# Valve's tree ships without generated files:
[ -f configure ] || autoreconf -f
[ -f include/wine/vulkan.h ] || python3 dlls/winevulkan/make_vulkan
[ -f dlls/ntdll/ntsyscalls.h ] || perl tools/make_specfiles
perl tools/make_requests
cd ..; mkdir -p build; cd build
[ -f Makefile ] || ../wine/configure --enable-win64 --with-mingw --disable-tests --without-x --without-wayland \
    --without-freetype --without-fontconfig --without-alsa --without-pulse --without-oss --without-gstreamer \
    --without-opengl --without-vulkan --without-dbus --without-usb --without-udev --without-unwind --without-gnutls \
    --without-sdl --without-cups --without-krb5 --without-netapi --without-opencl --without-pcap --without-pcsclite \
    --without-v4l2 --without-capi --without-gphoto --without-coreaudio --without-ffmpeg --without-gettext --without-inotify \
    > configure.log 2>&1
make -j"$(nproc)" dlls/ntdll/x86_64-windows/ntdll.dll
x86_64-w64-mingw32-strip --strip-debug -o "$WORK/ntdll.dll" dlls/ntdll/x86_64-windows/ntdll.dll
sha256sum "$WORK/ntdll.dll"
echo "copy $WORK/ntdll.dll over <Proton copy>/files/lib/wine/x86_64-windows/ntdll.dll (keep the original)"
