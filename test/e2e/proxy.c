/*
 * proxy.c - stand-in for wsl.exe / powershell.exe / fltmc.exe when running
 * wsl-setup.bat under Wine's cmd.exe (see run-e2e.sh).
 *
 * Wine can launch Linux programs directly, but then the exit code is lost,
 * and the .bat's error handling depends on exit codes. So this real Windows
 * .exe hands each call to fake_windows.py through files instead:
 *   %E2E_REQDIR%\req-<pid>-<tick>\args    argv (tool name first), UTF-8, NUL-terminated
 *                                 \env     environment block, UTF-8, NUL-terminated
 *                                 \stdin   2 lines read from our stdin, only when
 *                                          the call contains Read-Host (password prompt);
 *                                          %E2E_REQDIR%\stdin-wanted-* tells driver.py
 *                                          we are waiting for them
 * The directory is renamed to *.req once complete. The handler then writes
 * stdout / stderr / rc into it and creates "done". We replay those and exit
 * with rc.
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static char *to_utf8(const wchar_t *w, int *len) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *s = (char *)malloc(n);
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    *len = n; /* includes the terminating NUL */
    return s;
}

static void put_file(const wchar_t *dir, const wchar_t *name, const char *data, DWORD n) {
    wchar_t p[MAX_PATH * 2];
    swprintf(p, MAX_PATH * 2, L"%ls\\%ls", dir, name);
    HANDLE h = CreateFileW(p, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    DWORD w;
    if (n) WriteFile(h, data, n, &w, NULL);
    CloseHandle(h);
}

/* Copy a reply file to a std handle as raw bytes. */
static void replay(const wchar_t *dir, const wchar_t *name, DWORD std) {
    wchar_t p[MAX_PATH * 2];
    swprintf(p, MAX_PATH * 2, L"%ls\\%ls", dir, name);
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    char buf[8192]; DWORD r, w;
    HANDLE out = GetStdHandle(std);
    while (ReadFile(h, buf, sizeof buf, &r, NULL) && r) WriteFile(out, buf, r, &w, NULL);
    CloseHandle(h);
}

/* Read one line from stdin a byte at a time, so we never consume input that
 * belongs to the next `set /p` in the batch file. */
static int read_line(char *buf, int cap) {
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    int n = 0; char c; DWORD r;
    while (n < cap - 1 && ReadFile(in, &c, 1, &r, NULL) && r) {
        if (c == '\n') break;
        if (c != '\r') buf[n++] = c;
    }
    buf[n++] = '\n';
    return n;
}

int wmain(int argc, wchar_t **argv) {
    wchar_t root[MAX_PATH];
    if (!GetEnvironmentVariableW(L"E2E_REQDIR", root, MAX_PATH)) {
        fwprintf(stderr, L"proxy: E2E_REQDIR not set\n");
        return 99;
    }
    wchar_t tmpdir[MAX_PATH * 2], reqdir[MAX_PATH * 2];
    swprintf(tmpdir, MAX_PATH * 2, L"%ls\\req-%lu-%llu.tmp", root, GetCurrentProcessId(), GetTickCount64());
    swprintf(reqdir, MAX_PATH * 2, L"%ls\\req-%lu-%llu.req", root, GetCurrentProcessId(), GetTickCount64());
    CreateDirectoryW(tmpdir, NULL);

    /* tool name = our own file name without .exe, e.g. "wsl" */
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t *base = wcsrchr(self, L'\\'); base = base ? base + 1 : self;
    wchar_t *dot = wcsrchr(base, L'.'); if (dot) *dot = 0;
    _wcslwr(base);

    /* args */
    size_t cap = 1 << 16, used = 0; char *args = (char *)malloc(cap);
    int needs_stdin = 0;
    for (int i = 0; i < argc; i++) {
        int n; char *u = to_utf8(i == 0 ? base : argv[i], &n);
        if (used + n > cap) { cap = (used + n) * 2; args = (char *)realloc(args, cap); }
        memcpy(args + used, u, n); used += n; free(u);
        if (i && wcsstr(argv[i], L"Read-Host")) needs_stdin = 1;
    }
    put_file(tmpdir, L"args", args, (DWORD)used);

    /* environment */
    wchar_t *env = GetEnvironmentStringsW(), *e = env;
    size_t ecap = 1 << 16, eused = 0; char *eb = (char *)malloc(ecap);
    while (*e) {
        int n; char *u = to_utf8(e, &n);
        if (eused + n > ecap) { ecap = (eused + n) * 2; eb = (char *)realloc(eb, ecap); }
        memcpy(eb + eused, u, n); eused += n; free(u);
        e += wcslen(e) + 1;
    }
    FreeEnvironmentStringsW(env);
    put_file(tmpdir, L"env", eb, (DWORD)eused);

    if (needs_stdin) {
        /* Tell driver.py we are now waiting for the two password lines. */
        wchar_t flag[MAX_PATH * 2];
        swprintf(flag, MAX_PATH * 2, L"%ls\\stdin-wanted-%lu-%llu", root, GetCurrentProcessId(), GetTickCount64());
        HANDLE fh = CreateFileW(flag, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
        CloseHandle(fh);
        char lines[4096]; int n = read_line(lines, 2048);
        n += read_line(lines + n, 2048);
        put_file(tmpdir, L"stdin", lines, n);
    }

    MoveFileW(tmpdir, reqdir);

    wchar_t done[MAX_PATH * 2];
    swprintf(done, MAX_PATH * 2, L"%ls\\done", reqdir);
    for (int waited = 0; GetFileAttributesW(done) == INVALID_FILE_ATTRIBUTES; waited += 20) {
        if (waited > 300000) { fwprintf(stderr, L"proxy: handler timed out\n"); return 98; }
        Sleep(20);
    }
    replay(reqdir, L"stdout", STD_OUTPUT_HANDLE);
    replay(reqdir, L"stderr", STD_ERROR_HANDLE);

    wchar_t rcp[MAX_PATH * 2];
    swprintf(rcp, MAX_PATH * 2, L"%ls\\rc", reqdir);
    FILE *f = _wfopen(rcp, L"r"); int rc = 1;
    if (f) { if (fscanf(f, "%d", &rc) != 1) rc = 1; fclose(f); }
    return rc;
}
