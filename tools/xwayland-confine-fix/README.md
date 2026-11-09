# Xwayland pointer-confinement fix (KDE Wayland + Wine + Overwolf overlay)

Symptom: in a borderless Wine game the mouse escapes to the other monitor while the game
has `ClipCursor` active, with no focus change. `xdotool getmouselocation` still shows the X
pointer pinned at the clip edge, but the compositor's real pointer is on the other screen.

Cause (Xwayland 24.1, `hw/xwayland/xwayland-screen.c`): Wine confines the pointer with an
InputOnly window. Xwayland maps that to the *most recently realized* toplevel that covers the
clip rectangle. Overwolf's "ow overlay" window (same size as the game, kept below it, created
after the game window) wins, so the Wayland constraint is requested on a surface that never
has pointer focus and the compositor ignores it (KWin only applies constraints on the
pointer-focus surface of the active window).

Patch: prefer the window the pointer is currently in when it covers the clip rectangle.

Build (rootless podman, Fedora 44, same options and patches as the Fedora package):

    mkdir xw && cd xw && mkdir srpm && (cd srpm && dnf download --source xorg-x11-server-Xwayland && rpm2cpio *.src.rpm | cpio -idm)
    tar xf srpm/xwayland-24.1.14.tar.xz && patch -d xwayland-24.1.14 -p1 < xwayland-confine-prefer-pointer-focus.patch
    cp build.sh . && podman run --rm -v "$PWD":/work:Z registry.fedoraproject.org/fedora:44 bash /work/build.sh

Install: copy `build/hw/xwayland/Xwayland` to `~/.local/bin/Xwayland` (KWin finds Xwayland
through PATH) and log out/in. `Xwayland -version` shows "Build ID: xwayland-confine-fix".
Rollback: delete that file and log in again.
