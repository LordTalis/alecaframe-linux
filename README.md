# alecaframe-linux

Run **AlecaFrame** (the Overwolf-based Warframe companion app) next to **Warframe** on Linux, with the
same behaviour and the same user-level permissions it has on Windows. Tested on Nobara 44 / KDE Plasma
(Wayland), umu-launcher 1.4.4, UMU-Proton 10.0-4, Overwolf 0.311, AlecaFrame 2.6.95, AMD RADV, 2026-10.

This is an unofficial community setup, not affiliated with or endorsed by Overwolf, AlecaFrame or Digital
Extremes. Overwolf does not support Linux, AlecaFrame's developers do not support this
setup (don't report issues there), and Digital Extremes' policy for all third-party software is
"at your own risk". Read the [policy section](#digital-extremes-policy) before using a main account.

## What you get

- `alecaframe warframe` starts Warframe's standalone launcher in its own Proton prefix and brings up
  Overwolf + AlecaFrame inside the same container; press Play, log in, and AlecaFrame's **desktop window**
  populates from the live game: inventory, the relic planner, mastery, market, and the rivens you own.
- What does **not** work is anything Overwolf draws **inside the game** or reads from a **screenshot**, because
  DXVK has no cross-process shared D3D11 textures: the Ctrl+Tab overlay, the relic-reward reader that OCRs the
  mission reward screen, and the riven side panel / live price-check all render black or fail to capture. These
  are a real loss (the relic and riven overlays are among AlecaFrame's biggest draws). For live reward/riven
  recognition on Linux, a native tool such as [TennoScope](https://github.com/Deftera186/tennoscope) or a Wine
  build of a riven/relic analyzer is the route; AlecaFrame here gives you the window-based views instead.
- A watchdog handles Overwolf's Wine quirks for you: the events provider missing the game (it idles out ~20 s
  after start), and the overlay process grabbing keyboard/mouse. The overlay is killed to free your input, but
  only **after** the inventory has been captured (a large account's inventory takes longer to scan than the
  overlay survives otherwise; killing it early makes Overwolf drop the game before the data is read).

## Why there is a patched Proton copy

Overwolf 0.311's browser subprocess host is a .NET executable Wine's loader refuses to start (it jumps to a
zero entry point). Overwolf verifies its own files so the fix has to be in Wine: a 39-line loader patch
that mirrors what Windows does. The installer makes a **private copy** of UMU-Proton-10.0-4 named
`UMU-Proton-10.0-4-netfix` with the patched 64-bit `ntdll.dll`; your other Proton versions are untouched.
Details, repro and build script: [`wine-patch/`](wine-patch/README.md). The patch is being submitted
upstream ([`docs/wine-bug-report.md`](docs/wine-bug-report.md)); once it lands, this copy becomes unnecessary.

## Requirements

- [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher) (`umu-run`), `curl`, `python3`,
  `bsdtar`/`unzip`/`7z`. Optional: `xdotool` + `wmctrl` (overlay window containment), KDE Plasma 6 for the
  window rules.
- Warframe: either your existing **Steam** install (the installer makes a reflink copy, instant and
  space-free on btrfs/XFS, a full ~55 GB copy elsewhere) or `--standalone` to let DE's launcher download it.
- A Warframe account. Nothing here logs in for you: the launcher shows DE's EULA and the game shows the login
  screen; you type your own credentials, in-game.
- `kernel.yama.ptrace_scope = 0`. Overwolf reads the game's memory with `ReadProcessMemory`; Wine's
  wineserver performs that through ptrace between sibling processes. Fedora/Nobara ship 0 (via
  `elfutils-default-yama-scope`), so nothing changes there. Ubuntu and Arch ship 1: the installer tells you
  and leaves the decision to you (`sudo sysctl kernel.yama.ptrace_scope=0`, persisted in `/etc/sysctl.d/`).
  Note that this lowers a system-wide hardening knob: any process of your user can then read another's memory.
- ~3.5 GB for the prefix (.NET 4.8, WebView2, Overwolf) plus the game copy.

## Install

```
git clone https://github.com/LordTalis/alecaframe-linux && cd alecaframe-linux
./install.sh --steam-game ~/.local/share/Steam/steamapps/common/Warframe      # or --standalone
```

The installer is resumable (re-run it after a failure; finished steps are skipped). It downloads
UMU-Proton-10.0-4 (490 MB, checksum-verified), WebView2, Overwolf's full offline installer and .NET 4.8 from
their official sources. Overwolf's windows open briefly when AlecaFrame is installed through Overwolf's own
`-installapp`. Expect 10-20 minutes, most of it the .NET installer.

Daily use:

```
alecaframe warframe      # launcher + Overwolf + AlecaFrame; wait for READY (tail -f ~/.config/alecaframe-linux/logs/autostart.log)
                         # then press Play (soon after READY) and log in in-game
alecaframe check-data    # "LOADED" = Overwolf's scanner is reading the game
alecaframe status | logs | stop
alecaframe reattach      # scanner never attached: restart Overwolf+AlecaFrame under the running game
alecaframe unfreeze      # controls frozen: kill the overlay process (data keeps flowing)
alecaframe doctor        # checks prerequisites and the install
NO_ALECA=1 alecaframe warframe   # game only
```

## How it works, in one paragraph

Warframe runs through umu-launcher + Proton inside Valve's pressure-vessel container. `alecaframe prepare`
re-enters that container (`UMU_CONTAINER_NSENTER=1`) and starts `OverwolfLauncher.exe -launchapp <AlecaFrame>`
so Overwolf shares the game's Wine session. Overwolf injects its overlay (needed once: its first rendered frame
is how Overwolf detects the renderer under DXVK, which is what loads its game-events plugin
`gep_warframeext.dll`), the plugin opens `Warframe.x64.exe` read-only and finds the inventory JSON the game
already synced from DE's servers, and hands it to AlecaFrame. Before each launch the tool re-applies the
Overwolf-local config this needs: `<OOPO>True</OOPO>` for Warframe in Overwolf's `GamesList*.xml`, the
per-game overlay enabled, AlecaFrame's `MainWindow` set to a normal (clickable) window, and AlecaFrame's data
cache present so its .NET plugin does not hang on startup. No game file is modified.

## Permissions compared with Windows

| | Windows | this setup |
|---|---|---|
| Inventory data | Overwolf GEP opens `Warframe.x64.exe` with `PROCESS_VM_READ` and scans memory | identical calls, same Wine session |
| Kernel side | `NtReadVirtualMemory` | wineserver reads `/proc/<pid>/mem` of a same-user process (ptrace) |
| Overlay | injected into the game | same; the visible overlay is black under DXVK |
| Privileges | normal user | normal user: no sudo at runtime, no sysctl change on Fedora-family, no capabilities, no kernel modules |
| Game files | unmodified | unmodified (verified by diffing against the Steam install) |

Two things differ from a stock Windows install, both inside Overwolf's own configuration rather than the
game: Overwolf runs its overlay for Warframe in its out-of-process mode (a mode Overwolf uses for other
games), and the overlay process is killed after the scanner attaches, which is less interaction with the
game, not more.

## Digital Extremes policy

DE's ["Third-Party Software and You"](https://forums.warframe.com/topic/1320042-third-party-software-and-you/)
(Aug 2022) publishes no list of permitted software: "If you use external software in conjunction with
Warframe, then you do so at your own risk." Bans are for "altering game files, cheating and/or exploiting."
DE describes its Overwolf involvement as conversations ensuring the EULA/ToS are not breached. The
[EULA](https://www.warframe.com/eula) prohibits unauthorized programs that intercept or redirect
communication, hacks, bots, trainers, automation and altering game files; it says nothing about Linux.
DE has said Linux is neither forbidden nor supported, and DE's own launcher has a "WINE detected" code path.

So the risk here is the same grey-zone risk every AlecaFrame user on Windows accepts, with nothing added.
If you want no memory reading at all, use [TennoScope](https://github.com/Deftera186/tennoscope) instead.

## Known limitations

- **In-game overlays and screenshot features do not work** (DXVK, no cross-process shared textures): the
  Ctrl+Tab overlay, the relic-reward reader (OCRs the reward screen), and the riven side panel / price-check.
  Everything memory-based works in AlecaFrame's desktop window; for live reward/riven OCR use a native tool.
- Large inventories: the overlay must stay alive until the inventory is captured, or Overwolf drops the game
  before the scan finishes. The tool handles this (it kills the overlay only after the data is cached), so the
  first capture after login can take up to a minute during which a brief input grab is possible.
- Press Play soon after READY; the watchdog recovers if you don't, about a minute into the game.
- Dragging AlecaFrame's window may make it jump (Overwolf native drag under Wine).
- Only the 64-bit `ntdll.dll` is patched. The prebuilt DLL matches UMU-Proton-10.0-4 exactly.
- `--standalone` (DE's installer instead of a Steam copy) and the Steam-prefix mode of the tool are
  implemented but less tested than the Steam-copy route.

## Test record

2026-10-10, Nobara 44 / KDE 6 / RX 9070 XT (RADV): `install.sh --steam-game ... --yes` on a fresh directory ran
all nine steps unattended (Proton pin + patched DLL, reflink copy, prefix, WebView2 155, Overwolf 0.311.0.6
installed silently with `/S`, .NET 4.8 via the win7 dance, AlecaFrame 2.6.95 via `-installapp`, registry,
tool). `alecaframe warframe` on that install brought the launcher to DE's EULA and reported READY with
Overwolf + AlecaFrame injected. `repro/make-repro.sh` in the same prefix: stock UMU-Proton-10.0-4 crashes at
`0x140000000`, the patched copy prints hello. On a second machine-local install (same pipeline) a dummy
account logged in and AlecaFrame received the inventory from the memory scanner.

Same day, evening: a full main account (large inventory) logged in and AlecaFrame captured and cached the
inventory (2.24 MB) in its desktop window, after the overlay-kill was gated on the inventory actually being
captured. Before that gate, the watchdog killed the overlay seconds after attach and Overwolf dropped the game
before the big inventory finished scanning, so nothing populated; the fix holds the overlay alive until the
first `New inventory data`, then kills it to free input. The in-game relic-reward overlay and riven side panel
were confirmed non-functional under DXVK (overlay renders null; the screenshot OCR path errors), as expected.

## Credits and license

Scripts and docs: MIT (see `LICENSE`). `wine-patch/` and `prebuilt/`: LGPL-2.1-or-later (Wine).
The approach, the OOPO/overlay findings and parts of the tool derive from Deftera186's guides; see
[`CREDITS.md`](CREDITS.md). Overwolf, AlecaFrame and Warframe are trademarks of their owners; none of their
software is redistributed here.
