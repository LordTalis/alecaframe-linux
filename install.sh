#!/bin/bash
# alecaframe-linux installer: Overwolf + AlecaFrame next to Warframe on Linux (umu-launcher + Proton).
#
# What it does (resumable; each step records itself in $DIR/.install-state):
#   1 proton    pin UMU-Proton-10.0-4 and make a private copy with the patched ntdll.dll (see wine-patch/)
#   2 game      reflink/copy your Steam install of Warframe into $DIR/Warframe (or use DE's standalone installer)
#   3 prefix    create the Proton prefix
#   4 webview2  Microsoft Edge WebView2 runtime (Overwolf's installer UI needs it)
#   5 overwolf  Overwolf full offline installer, silent
#   6 dotnet48  .NET Framework 4.8 (Overwolf requires it); the 4.8 installer only runs with winver=win7
#   7 aleca     install AlecaFrame through Overwolf's own -installapp
#   8 registry  Warframe launcher DownloadDir -> $DIR/Downloaded
#   9 tool      ~/.local/bin/alecaframe + profile (+ KWin rules on Plasma)
#
# Nothing proprietary is bundled: Overwolf, AlecaFrame, WebView2, .NET and Warframe are fetched from their
# official sources at install time. Read README.md first, especially the DE policy section.
#
# Usage: ./install.sh [--dir DIR] [--steam-game PATH | --standalone] [--yes] [--no-kwin] [--until N]
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HOME/Games/AlecaFrame-Warframe"
STEAM_GAME=""; STANDALONE=0; YES=0; NO_KWIN=0; UNTIL=99
PROTON_VER="UMU-Proton-10.0-4"
PROTON_URL="https://github.com/Open-Wine-Components/umu-proton/releases/download/$PROTON_VER/$PROTON_VER.tar.gz"
PROTON_SHA_URL="https://github.com/Open-Wine-Components/umu-proton/releases/download/$PROTON_VER/$PROTON_VER.sha512sum"
NETFIX="$PROTON_VER-netfix"
COMPAT="$HOME/.local/share/Steam/compatibilitytools.d"
AF_EXTID="afmcagbpgggkpdkokjhjkllpegnadmkignlonpjm"
WEBVIEW2_URL="https://go.microsoft.com/fwlink/?linkid=2124701"
OVERWOLF_LATEST="https://content.overwolf.com/downloads/setup/latest/regular.html"
WARFRAME_MSI="https://content.warframe.com/dl/Warframe.msi"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2;;
        --steam-game) STEAM_GAME="$2"; shift 2;;
        --standalone) STANDALONE=1; shift;;
        --yes|-y) YES=1; shift;;
        --no-kwin) NO_KWIN=1; shift;;
        --until) UNTIL="$2"; shift 2;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) echo "unknown option $1"; exit 2;;
    esac
done

PFX="$DIR/pfx"; DL="$DIR/downloads"; LOGS="$DIR/logs"; STATE="$DIR/.install-state"
mkdir -p "$DIR" "$DL" "$LOGS"; touch "$STATE"
log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
done_step() { grep -qx "$1" "$STATE"; }
mark() { echo "$1" >> "$STATE"; }
ask()  { [ "$YES" = 1 ] && return 0; read -r -p "$1 [Y/n] " a; [ -z "$a" ] || [[ "$a" =~ ^[Yy] ]]; }
umu()  { env WINEPREFIX="$PFX" GAMEID=umu-warframe STORE=none PROTONPATH="$NETFIX" SteamDeck=0 PROTON_USE_XALIA=0 UMU_CONTAINER_NSENTER=1 umu-run "$@"; }
umu_bg(){ setsid nohup env WINEPREFIX="$PFX" GAMEID=umu-warframe STORE=none PROTONPATH="$NETFIX" SteamDeck=0 PROTON_USE_XALIA=0 UMU_CONTAINER_NSENTER=1 umu-run "$@" </dev/null >"$LOGS/bg.log" 2>&1 & }
winpath() { printf 'Z:%s' "$(printf '%s' "$1" | sed 's|/|\\|g')"; }
stop_overwolf() { for p in $(ps -eo pid,comm | awk '$2 ~ /^Overwolf|^ow-overlay/ {print $1}'); do kill "$p" 2>/dev/null; done; sleep 3; }
wineserver_kill() { "$COMPAT/$NETFIX/files/bin/wineserver" -k 2>/dev/null; WINEPREFIX="$PFX" "$COMPAT/$NETFIX/files/bin/wineserver" -k 2>/dev/null; sleep 2; }

# ---------------------------------------------------------------- 0 preflight
log "preflight"
for t in umu-run curl python3 md5sum sha256sum sha512sum; do command -v $t >/dev/null || die "$t is required (umu-launcher: https://github.com/Open-Wine-Components/umu-launcher)"; done
command -v bsdtar >/dev/null || command -v unzip >/dev/null || command -v 7z >/dev/null || die "need bsdtar, unzip or 7z to unpack Overwolf's installer zip"
for t in xdotool wmctrl; do command -v $t >/dev/null || echo "  note: $t not found (optional: overlay window containment)"; done
PS=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo "?")
if [ "$PS" != "0" ]; then
    cat <<EOF
  kernel.yama.ptrace_scope is $PS on this system (Fedora/Nobara ship 0; Ubuntu/Arch ship 1).
  Overwolf's data scanner reads the game's memory with ReadProcessMemory, which Wine's wineserver performs
  through ptrace. With scope 1 the scanner may read nothing. Setting it to 0 (sudo sysctl kernel.yama.ptrace_scope=0,
  persist in /etc/sysctl.d/) lowers a system-wide hardening knob: any process of your user may then read another's
  memory. This installer does NOT change it; decide for yourself and re-run.
EOF
    ask "Continue anyway?" || exit 1
fi
echo "  install dir: $DIR"; echo "  steam game:  ${STEAM_GAME:-<none>} standalone=$STANDALONE"
df -h "$DIR" | tail -1 | awk '{print "  free space on target: "$4}'
[ "$UNTIL" -lt 1 ] && exit 0

# ---------------------------------------------------------------- 1 proton
if ! done_step proton; then
    log "1/9 Proton: $PROTON_VER + patched ntdll.dll -> $NETFIX"
    mkdir -p "$COMPAT"
    if [ ! -d "$COMPAT/$PROTON_VER" ]; then
        [ -f "$DL/$PROTON_VER.tar.gz" ] || curl -fL --progress-bar -o "$DL/$PROTON_VER.tar.gz" "$PROTON_URL"
        curl -fsSL -o "$DL/$PROTON_VER.sha512sum" "$PROTON_SHA_URL"
        (cd "$DL" && sha512sum -c "$PROTON_VER.sha512sum") || die "UMU-Proton checksum mismatch"
        tar -xzf "$DL/$PROTON_VER.tar.gz" -C "$COMPAT" || die "could not unpack UMU-Proton"
    fi
    [ -f "$COMPAT/$PROTON_VER/files/lib/wine/x86_64-windows/ntdll.dll" ] || die "$COMPAT/$PROTON_VER looks incomplete"
    if [ ! -d "$COMPAT/$NETFIX" ]; then
        cp -a --reflink=auto "$COMPAT/$PROTON_VER" "$COMPAT/$NETFIX"
        sed -i "s/\"$PROTON_VER-proton\"/\"$NETFIX-proton\"/; s/\"display_name\" \"$PROTON_VER\"/\"display_name\" \"$NETFIX\"/" "$COMPAT/$NETFIX/compatibilitytool.vdf"
        echo "$(cut -d' ' -f1 "$COMPAT/$NETFIX/version") $NETFIX" > "$COMPAT/$NETFIX/version"
    fi
    PB="$REPO_DIR/prebuilt/$PROTON_VER/ntdll.dll"
    (cd "$REPO_DIR/prebuilt/$PROTON_VER" && sha256sum -c SHA256SUMS >/dev/null) || die "prebuilt ntdll.dll checksum mismatch"
    cp -n "$COMPAT/$NETFIX/files/lib/wine/x86_64-windows/ntdll.dll" "$COMPAT/$NETFIX/files/lib/wine/x86_64-windows/ntdll.dll.valve-orig"
    cp -f "$PB" "$COMPAT/$NETFIX/files/lib/wine/x86_64-windows/ntdll.dll"; chmod 755 "$COMPAT/$NETFIX/files/lib/wine/x86_64-windows/ntdll.dll"
    echo "  installed $NETFIX (original ntdll kept as ntdll.dll.valve-orig)"
    mark proton
fi
[ "$UNTIL" -lt 2 ] && exit 0

# ---------------------------------------------------------------- 2 game
if ! done_step game; then
    log "2/9 game content"
    if [ -n "$STEAM_GAME" ]; then
        [ -f "$STEAM_GAME/Warframe.x64.exe" ] || die "$STEAM_GAME does not look like a Warframe install"
        if [ ! -d "$DIR/Warframe" ]; then
            echo "  copying $STEAM_GAME -> $DIR/Warframe (reflink when the filesystem supports it, else a full copy)"
            cp -a --reflink=auto "$STEAM_GAME" "$DIR/Warframe" || die "copy failed"
        fi
        mkdir -p "$DIR/Downloaded"; ln -sfn ../Warframe "$DIR/Downloaded/Public"
    elif [ "$STANDALONE" = 1 ]; then
        mkdir -p "$DIR/Downloaded/Public"
        [ -f "$DL/Warframe.msi" ] || curl -fL --progress-bar -A "$UA" -o "$DL/Warframe.msi" "$WARFRAME_MSI"
        echo "  (standalone mode: DE's launcher will download the game into $DIR/Downloaded/Public on first run)"
    else
        die "give --steam-game <path to steamapps/common/Warframe> or --standalone"
    fi
    mark game
fi
[ "$UNTIL" -lt 3 ] && exit 0

# ---------------------------------------------------------------- 3 prefix
if ! done_step prefix; then
    log "3/9 Proton prefix at $PFX"
    mkdir -p "$PFX"
    umu wineboot > "$LOGS/prefix.log" 2>&1 || die "prefix creation failed, see $LOGS/prefix.log"
    [ -d "$PFX/drive_c" ] || die "prefix not created"
    mark prefix
fi
[ "$UNTIL" -lt 4 ] && exit 0

# ---------------------------------------------------------------- 4 webview2
if ! done_step webview2; then
    log "4/9 WebView2 runtime"
    [ -f "$DL/WebView2_x64.exe" ] || curl -fL --progress-bar --compressed -A "$UA" -o "$DL/WebView2_x64.exe" "$WEBVIEW2_URL"
    umu "$DL/WebView2_x64.exe" /silent /install > "$LOGS/webview2.log" 2>&1
    ls "$PFX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/" >/dev/null 2>&1 || die "WebView2 did not install, see $LOGS/webview2.log"
    mark webview2
fi
[ "$UNTIL" -lt 5 ] && exit 0

# ---------------------------------------------------------------- 5 overwolf
if ! done_step overwolf; then
    log "5/9 Overwolf (full offline installer from Overwolf's CDN)"
    if [ ! -f "$DL/OverwolfSetup/OverwolfSetup.exe" ]; then
        ZIPURL=$(curl -fsSL -A "$UA" "$OVERWOLF_LATEST" | grep -o 'https://setup.overwolf.com/[^"]*OverwolfSetup.zip' | head -1)
        [ -n "$ZIPURL" ] || die "could not find the Overwolf setup zip link on $OVERWOLF_LATEST"
        echo "  $ZIPURL"
        curl -fL --progress-bar -A "$UA" -o "$DL/OverwolfSetup.zip" "$ZIPURL"
        rm -rf "$DL/OverwolfSetup"; mkdir -p "$DL/OverwolfSetup"
        if command -v bsdtar >/dev/null; then bsdtar -xf "$DL/OverwolfSetup.zip" -C "$DL/OverwolfSetup"
        elif command -v unzip >/dev/null; then unzip -q "$DL/OverwolfSetup.zip" -d "$DL/OverwolfSetup"
        else 7z x -y -o"$DL/OverwolfSetup" "$DL/OverwolfSetup.zip" >/dev/null; fi
    fi
    [ -f "$DL/OverwolfSetup/OverwolfSetup.exe" ] || die "OverwolfSetup.exe not found after unpacking"
    echo "  running the installer silently (/S); if a wizard window appears instead, click: accept terms, Next, Install, Finish"
    umu "$DL/OverwolfSetup/OverwolfSetup.exe" /S > "$LOGS/overwolf-setup.log" 2>&1
    [ -f "$PFX/drive_c/Program Files (x86)/Overwolf/OverwolfLauncher.exe" ] || die "Overwolf did not install, see $LOGS/overwolf-setup.log"
    mark overwolf
fi
[ "$UNTIL" -lt 6 ] && exit 0

# ---------------------------------------------------------------- 6 dotnet48
if ! done_step dotnet48; then
    log "6/9 .NET Framework 4.8 (takes several minutes; the 4.8 installer refuses on a Windows 10 prefix, so winver is set to 7 temporarily)"
    umu winetricks -q win7 > "$LOGS/winetricks-win7.log" 2>&1
    umu winetricks -q dotnet48 > "$LOGS/winetricks-dotnet48.log" 2>&1
    if ! grep -q '"Release"=dword:00080' "$PFX/system.reg"; then
        echo "  winetricks did not land 4.8; running the installer directly"
        NDP=$(ls "$HOME/.cache/winetricks/dotnet48/ndp48-x86-x64-allos-enu.exe" 2>/dev/null | head -1)
        [ -n "$NDP" ] || die "ndp48 installer not found in winetricks cache"
        umu "$NDP" /q /norestart > "$LOGS/ndp48.log" 2>&1
    fi
    umu winetricks -q win10 > "$LOGS/winetricks-win10.log" 2>&1
    grep -q '"Release"=dword:00080' "$PFX/system.reg" || die ".NET 4.8 still missing (registry Release), see $LOGS"
    mark dotnet48
fi
[ "$UNTIL" -lt 7 ] && exit 0

# ---------------------------------------------------------------- 7 alecaframe
if ! done_step aleca; then
    log "7/9 AlecaFrame via Overwolf (-installapp); Overwolf windows will open and close"
    umu_bg "$PFX/drive_c/Program Files (x86)/Overwolf/OverwolfLauncher.exe" -installapp "$AF_EXTID"
    i=0; while [ $i -lt 180 ]; do [ -d "$PFX/drive_c/users/steamuser/AppData/Local/Overwolf/Extensions/$AF_EXTID" ] && ls "$PFX/drive_c/users/steamuser/AppData/Local/Overwolf/Extensions/$AF_EXTID"/*/manifest.json >/dev/null 2>&1 && break; sleep 5; i=$((i+5)); done
    ls "$PFX/drive_c/users/steamuser/AppData/Local/Overwolf/Extensions/$AF_EXTID"/*/manifest.json >/dev/null 2>&1 || die "AlecaFrame did not install (see $LOGS/bg.log and Overwolf's Log folder in the prefix)"
    sleep 20; stop_overwolf; wineserver_kill
    echo "  AlecaFrame $(ls "$PFX/drive_c/users/steamuser/AppData/Local/Overwolf/Extensions/$AF_EXTID" | tail -1) installed"
    mark aleca
fi
[ "$UNTIL" -lt 8 ] && exit 0

# ---------------------------------------------------------------- 8 registry
if ! done_step registry; then
    log "8/9 Warframe launcher DownloadDir"
    WP=$(winpath "$DIR/Downloaded")
    umu reg add 'HKCU\Software\Digital Extremes\Warframe\Launcher' /v DownloadDir /t REG_SZ /d "$WP" /f > "$LOGS/reg.log" 2>&1
    wineserver_kill
    grep -q 'DownloadDir' "$PFX/user.reg" || die "registry write failed, see $LOGS/reg.log"
    echo "  DownloadDir = $WP"
    if [ "$STANDALONE" = 1 ]; then
        umu msiexec /i "$DL/Warframe.msi" /qn > "$LOGS/msi.log" 2>&1; wineserver_kill
    fi
    mark registry
fi
[ "$UNTIL" -lt 9 ] && exit 0

# ---------------------------------------------------------------- 9 tool + profile
log "9/9 alecaframe tool + profile"
mkdir -p "$HOME/.local/bin" "${XDG_CONFIG_HOME:-$HOME/.config}/alecaframe-linux"
install -m 755 "$REPO_DIR/bin/alecaframe" "$HOME/.local/bin/alecaframe"
PROFILE="${XDG_CONFIG_HOME:-$HOME/.config}/alecaframe-linux/profile.conf"
if [ ! -f "$PROFILE" ]; then
    cat > "$PROFILE" <<EOF
# alecaframe-linux profile (written by install.sh $(date +%F))
WINEPREFIX="$PFX"
GAME_DIR="$DIR/Downloaded"
GAMEID="umu-warframe"
STORE="none"
PROTONPATH="$NETFIX"
# LAUNCHER_EXE is auto-resolved (the launcher moves itself into the prefix's AppData on first run)
OOPO_MODE="on"
NEUTER_REMOTE_DISABLE="0"
OVERLAY_KILL_WHEN_LOADED="1"
REATTACH_AFTER="75"
EOF
    echo "  wrote $PROFILE"
else
    echo "  kept existing $PROFILE"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  NOTE: add ~/.local/bin to your PATH";; esac
if [ "$NO_KWIN" = 0 ] && command -v kwriteconfig6 >/dev/null && [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ]; then
    ask "Install KWin window rules that keep Overwolf's overlay surface below the game?" && "$HOME/.local/bin/alecaframe" install-kwin-rules
fi
"$HOME/.local/bin/alecaframe" doctor
cat <<EOF

Done. Daily use:
  alecaframe warframe     # launcher + Overwolf + AlecaFrame; wait for READY, then press Play and log in
  alecaframe check-data   # after the game is up
  alecaframe stop
First launch: the Warframe launcher shows DE's EULA (accept it yourself), then "WARFRAME IS UP TO DATE" and Play.
EOF
