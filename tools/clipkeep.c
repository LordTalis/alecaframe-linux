/* clipkeep.exe - part of alecaframe-linux.
 *
 * Keeps Warframe's own mouse lock through split-second focus blips on the AlecaFrame rig.
 *
 * Why: Wine's server drops the cursor clip on EVERY foreground change (server/queue.c, set_foreground_input() ->
 * set_clip_rectangle(NULL, SET_CURSOR_NOCLIP, 1)). Warframe does not lock the mouse again afterwards, so the pointer
 * slides onto the second monitor mid-mission. Blip sources seen on the rig: Overwolf's windows at startup, and (found
 * 2026-11-07 with an X-side recorder) KWin 6.7.5 moving X focus to another window for ~30 ms, dozens of times per
 * hour - logged here as "(none)" because no Wine window is in front then. That one is a KWin regression with Wine's
 * WM_TAKE_FOCUS windows (KDE bug 525590, fixed in 6.7.6); the rig works around it with UseTakeFocus=N in user.reg
 * (see bin/alecaframe X11_DRIVER_KEYS). The X pointer sits on the clip's edge, so even a 30 ms gap is a slip, and
 * winex11 skips the X grab while another process has focus: a re-lock here can look successful without being one.
 * So this tool is a safety net and a BLIP COUNTER, not the fix; watch its 10-minute summary lines.
 *
 * What it does, and nothing more:
 *  - follows foreground changes (EVENT_SYSTEM_FOREGROUND) and reads the clip (GetClipCursor) every 5 ms while the
 *    game is in front;
 *  - when the game HAD the mouse locked, lost the foreground and got it back within BLIP_MAX_MS, it re-applies the
 *    game's own last lock rectangle with ClipCursor(), unless the game already did;
 *  - Esc keeps freeing the mouse: after such a re-lock, if the user presses Esc and the lock is still on 150 ms later
 *    (the game believes it already released it), it releases it;
 *  - it never touches the lock when the game released it itself (Esc menu) or when focus was away longer (Alt-Tab).
 * It only calls user32 functions in its own process. It does not open, read, write or inject into the game process
 * (game windows are recognised by process id from a Toolhelp snapshot).
 *
 * usage: clipkeep.exe [log file]
 * build: x86_64-w64-mingw32-gcc -O2 -s -Wall -Wextra -mwindows -static-libgcc -o clipkeep.exe clipkeep.c -luser32 -lshell32
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>

#define GAME_EXE        L"Warframe.x64.exe"
#define BLIP_MAX_MS     3000u     /* focus away at most this long counts as a blip; longer = the user left on purpose */
#define RELOCK_DELAY_MS 40u       /* give the game a moment to lock again by itself first */
#define ESC_CHECK_MS    150u
#define POLL_FAST_MS    5u
#define POLL_SLOW_MS    250u
#define EXIT_NO_GAME_MS 120000u   /* exit 2 min after the game is gone */
#define EXIT_NEVER_MS   1800000u  /* exit if no game showed up within 30 min */

static FILE *lg;
static DWORD game_pids[16];
static int n_game_pids;
static RECT vs;                   /* virtual screen = the "no clip" rectangle */

static BOOL game_fg, clip_on, armed, relock_pending, our_lock, esc_down, esc_check;
static RECT clip_rect;
static DWORD clip_seen, away_since, relock_at, esc_at;
static unsigned n_relocks, n_blips, n_blips_at_summary;
#define SUMMARY_MS 600000u   /* 10-minute blip summary */

static void say(const char *fmt, ...)
{
    SYSTEMTIME t;
    va_list ap;
    if (!lg) return;
    GetLocalTime(&t);
    fprintf(lg, "%02u:%02u:%02u.%03u ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_start(ap, fmt); vfprintf(lg, fmt, ap); va_end(ap);
    fputc('\n', lg);
    fflush(lg);
}

static void u8(const WCHAR *w, char *out, int n)
{
    if (!WideCharToMultiByte(CP_UTF8, 0, w, -1, out, n, NULL, NULL)) out[0] = 0;
}

static void read_vs(void)
{
    vs.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    vs.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    vs.right = vs.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    vs.bottom = vs.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
}

/* exe name for a pid (Toolhelp snapshot: no process handle is opened); also refreshes the game pid list */
static void snapshot(DWORD want_pid, WCHAR *exe_out, int n)
{
    PROCESSENTRY32W pe;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (exe_out && n) lstrcpynW(exe_out, L"?", n);
    n_game_pids = 0;
    if (s == INVALID_HANDLE_VALUE) return;
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(s, &pe)) do {
        if (!_wcsicmp(pe.szExeFile, GAME_EXE) && n_game_pids < 16) game_pids[n_game_pids++] = pe.th32ProcessID;
        if (exe_out && pe.th32ProcessID == want_pid) lstrcpynW(exe_out, pe.szExeFile, n);
    } while (Process32NextW(s, &pe));
    CloseHandle(s);
}

static BOOL is_game_window(HWND h)
{
    DWORD pid = 0;
    int i;
    if (!h) return FALSE;
    GetWindowThreadProcessId(h, &pid);
    for (i = 0; i < n_game_pids; i++) if (game_pids[i] == pid) return TRUE;
    return FALSE;
}

static void describe(HWND h, char *out, int n)
{
    WCHAR title[128] = L"", cls[64] = L"", exe[MAX_PATH];
    char t8[256], c8[128], e8[MAX_PATH];
    DWORD pid = 0;
    if (h) {
        InternalGetWindowText(h, title, 128);   /* never sends a message to the window */
        GetClassNameW(h, cls, 64);
        GetWindowThreadProcessId(h, &pid);
    }
    snapshot(pid, exe, MAX_PATH);
    u8(title, t8, sizeof t8); u8(cls, c8, sizeof c8); u8(exe, e8, sizeof e8);
    if (!h) snprintf(out, n, "(none: X focus left all Wine windows, e.g. KWin gave it to another app)");
    else snprintf(out, n, "%s pid=%lu \"%s\" class=%s", e8, (unsigned long)pid, t8, c8);
}

static void handle_fg(HWND hwnd)
{
    DWORD now = GetTickCount();
    BOOL g = is_game_window(hwnd);
    char d[512];
    if (g == game_fg) return;
    if (!g) {
        game_fg = FALSE;
        away_since = now;
        armed = clip_on || (now - clip_seen <= 30);   /* the server already dropped the clip; use the last 5 ms poll */
        relock_pending = FALSE;
        esc_check = FALSE;
        describe(hwnd, d, sizeof d);
        say("focus left the game -> %s (mouse lock was %s)", d, armed ? "ON" : "off");
    } else {
        DWORD away = now - away_since;
        game_fg = TRUE;
        if (armed && away <= BLIP_MAX_MS) {
            n_blips++;
            relock_pending = TRUE;
            relock_at = now + RELOCK_DELAY_MS;
            say("focus back after %lu ms (blip #%u)", (unsigned long)away, n_blips);
        } else {
            say("focus back after %lu ms%s", (unsigned long)away,
                armed ? " - too long for a blip, the lock is left to the game" : "");
        }
        armed = FALSE;
    }
}

static void CALLBACK on_foreground(HWINEVENTHOOK hk, DWORD ev, HWND hwnd, LONG obj, LONG child, DWORD tid, DWORD t)
{
    (void)hk; (void)obj; (void)child; (void)tid; (void)t;
    if (ev != EVENT_SYSTEM_FOREGROUND) return;
    if (!is_game_window(hwnd)) snapshot(0, NULL, 0);   /* the game may have restarted under a new pid */
    handle_fg(hwnd);
}

static BOOL clipped(RECT *r)
{
    return GetClipCursor(r) && !EqualRect(r, &vs);
}

static void poll(DWORD now)
{
    RECT r;
    BOOL c = clipped(&r), esc;
    HWND fg;

    if (game_fg) {
        if (c) { clip_rect = r; clip_seen = now; }
        else if (our_lock && !esc_check) our_lock = FALSE;   /* the game released our re-lock itself */
        clip_on = c;
    }
    if (relock_pending && (LONG)(now - relock_at) >= 0) {
        relock_pending = FALSE;
        if (game_fg && is_game_window(GetForegroundWindow())) {
            if (c) say("  the game locked the mouse again by itself");
            else if (ClipCursor(&clip_rect)) {
                our_lock = TRUE; clip_on = TRUE; clip_seen = now; n_relocks++;
                say("  re-locked the mouse to the game screen (%ld,%ld)-(%ld,%ld) [re-lock #%u]",
                    clip_rect.left, clip_rect.top, clip_rect.right, clip_rect.bottom, n_relocks);
            } else say("  ClipCursor failed, error %lu", GetLastError());
        }
    }
    esc = (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
    if (esc && !esc_down && our_lock && game_fg) { esc_check = TRUE; esc_at = now + ESC_CHECK_MS; }
    esc_down = esc;
    if (esc_check && (LONG)(now - esc_at) >= 0) {
        esc_check = FALSE;
        if (our_lock && clipped(&r)) { ClipCursor(NULL); say("  Esc: the game left the re-applied lock on - released it"); }
        else say("  Esc: the game released the lock itself");
        our_lock = FALSE;
    }
    /* fallback for a foreground change the hook did not report */
    fg = GetForegroundWindow();
    if (is_game_window(fg) != game_fg) handle_fg(fg);
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cl, int show)
{
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    HWINEVENTHOOK hk;
    HANDLE mtx;
    DWORD start, last_pids = 0, last_game = 0, last_summary = 0, now;
    BOOL seen_game = FALSE;
    RECT r;
    MSG m;
    (void)hi; (void)hp; (void)cl; (void)show;

    mtx = CreateMutexW(NULL, TRUE, L"Local\\alecaframe-linux-clipkeep");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;
    SetProcessDPIAware();                       /* raw pixel coordinates, like the game */
    if (argv && argc > 1) lg = _wfopen(argv[1], L"a");
    read_vs();
    hk = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL, on_foreground, 0, 0,
                         WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    snapshot(0, NULL, 0);
    game_fg = is_game_window(GetForegroundWindow());
    clip_on = game_fg && clipped(&r);
    say("--- clipkeep start: hook %s, screen (%ld,%ld)-(%ld,%ld), game %s, in front %s, lock %s",
        hk ? "ok" : "FAILED", vs.left, vs.top, vs.right, vs.bottom, n_game_pids ? "running" : "not running",
        game_fg ? "yes" : "no", clip_on ? "on" : "off");

    start = GetTickCount();
    for (;;) {
        MsgWaitForMultipleObjects(0, NULL, FALSE, (game_fg || relock_pending || esc_check) ? POLL_FAST_MS : POLL_SLOW_MS,
                                  QS_ALLINPUT);
        while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
            if (m.message == WM_QUIT) goto out;
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
        now = GetTickCount();
        if (now - last_pids >= 2000) {
            snapshot(0, NULL, 0);
            read_vs();
            last_pids = now;
            if (n_game_pids) { if (!seen_game) say("game running"); seen_game = TRUE; last_game = now; }
        }
        if (seen_game && n_game_pids && now - last_summary >= SUMMARY_MS) {
            if (last_summary) say("summary: %u blips in the last 10 min (%u total, %u re-locks); 0 is the goal",
                                  n_blips - n_blips_at_summary, n_blips, n_relocks);
            n_blips_at_summary = n_blips; last_summary = now;
        }
        if (seen_game && !n_game_pids && now - last_game > EXIT_NO_GAME_MS) { say("game gone for 2 min"); break; }
        if (!seen_game && now - start > EXIT_NEVER_MS) { say("no game within 30 min"); break; }
        poll(now);
    }
out:
    say("--- clipkeep exit: %u blips, %u re-locks", n_blips, n_relocks);
    if (hk) UnhookWinEvent(hk);
    if (mtx) CloseHandle(mtx);
    return 0;
}
