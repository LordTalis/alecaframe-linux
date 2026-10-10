#!/bin/bash
# Build hello-noilonly.exe inside a Proton prefix that has real .NET Framework 4.8 (csc.exe), then run it
# under a stock Proton (crashes) and under the patched one (prints hello).
# Usage: WINEPREFIX=<prefix with .NET 4.8> ./make-repro.sh [stock-proton-name] [patched-proton-name]
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOCK="${1:-UMU-Proton-10.0-4}"; PATCHED="${2:-UMU-Proton-10.0-4-netfix}"
: "${WINEPREFIX:?set WINEPREFIX to a Proton prefix that has .NET Framework 4.8 installed}"
CSC="$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
[ -f "$CSC" ] || { echo "csc.exe not found in $WINEPREFIX (install .NET 4.8 first)"; exit 1; }
LOGD="$(mktemp -d)"
run() { local proton="$1"; shift; env WINEPREFIX="$WINEPREFIX" GAMEID=umu-repro STORE=none PROTONPATH="$proton" PROTON_USE_XALIA=0 PROTON_LOG=1 PROTON_LOG_DIR="$LOGD" umu-run "$@"; }
verdict() {   # $1 = proton log; with PROTON_LOG=1 the program's output and the crash message both go to the log
    if grep -q 'Unhandled exception: page fault on execute access' "$1" 2>/dev/null; then echo "  -> CRASHED: $(grep -m1 -o 'Unhandled exception: page fault on execute access to 0x[0-9a-f]*' "$1")"
    elif grep -q 'hello from a managed exe' "$1" 2>/dev/null; then echo "  -> OK: $(grep -m1 -o 'hello from a managed exe.*' "$1")"
    else echo "  -> neither hello nor a crash found in $1"; fi
}
cp "$HERE/Hello.cs" "$WINEPREFIX/drive_c/Hello.cs"
EXE="$WINEPREFIX/drive_c/hello-noilonly.exe"
run "$STOCK" "$CSC" /nologo /platform:x64 /out:'C:\hello-noilonly.exe' 'C:\Hello.cs' >/dev/null 2>&1
python3 "$HERE/strip-ilonly.py" "$EXE"
echo; echo "=== stock $STOCK (expect: page fault on execute access to 0x140000000, no hello) ==="
rm -f "$LOGD"/steam-*.log; run "$STOCK" "$EXE" 2>&1 | grep -E 'hello' || true; verdict "$(ls "$LOGD"/steam-*.log 2>/dev/null | head -1)"
echo; echo "=== patched $PATCHED (expect: hello) ==="
rm -f "$LOGD"/steam-*.log; run "$PATCHED" "$EXE" 2>&1 | grep -E 'hello' || true; verdict "$(ls "$LOGD"/steam-*.log 2>/dev/null | head -1)"
echo; echo "(reproducer binary: $EXE; attach it to the bug report)"
