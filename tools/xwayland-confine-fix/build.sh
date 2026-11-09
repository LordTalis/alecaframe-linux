#!/bin/bash
# builds the patched Xwayland 24.1.14 in a Fedora 44 container (rootless podman); output: /work/build/hw/xwayland/Xwayland
set -ex
cd /work
dnf -y --setopt=install_weak_deps=False builddep srpm/xorg-x11-server-Xwayland.spec
cd xwayland-24.1.14
for p in ../srpm/xwayland-cvt-dotclock-overflow.patch ../srpm/xwayland-pointer-warp-fix.patch; do patch -p1 --forward -i "$p" || true; done
rm -rf ../build
meson setup ../build -Dprefix=/usr -Dbuildtype=release -Ddefault_font_path='catalogue:/etc/X11/fontpath.d,built-ins' -Dbuilder_string="Build ID: xwayland-confine-fix 24.1.14 (talis local, pointer-focus confine patch)" -Dxkb_output_dir=/var/lib/xkb -Dserverconfigdir=/usr/share/xwayland -Dxcsecurity=true -Dglamor=true -Ddri3=true
ninja -C ../build
ls -la ../build/hw/xwayland/Xwayland
