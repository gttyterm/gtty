// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Opening files with other apps, for gtty's `show` command.
//
// macOS: LaunchServices (the same database Finder uses): the default app,
// every app that can open the file, and opening it with one of them.
// Linux: the freedesktop way: the file's MIME type and default app from
// xdg-mime, the other apps from the mimeinfo.cache files, opening with
// xdg-open (default) or `gio launch` / `gtk-launch` (a chosen app).

#include "gtty_open.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int by_name(const void *a, const void *b) {
    const gtty_app *x = a, *y = b;
    if (x->is_default != y->is_default) return y->is_default - x->is_default;
    return strcasecmp(x->name, y->name);
}

#if defined(__APPLE__)

#include <CoreServices/CoreServices.h>
#include <sys/stat.h>

static CFURLRef file_url(const char *path) {
    struct stat st;
    Boolean dir = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), dir);
}

// "/Applications/TextEdit.app" → "TextEdit".
static void app_name(CFURLRef app, char *out, unsigned long len) {
    out[0] = 0;
    CFStringRef last = CFURLCopyLastPathComponent(app);
    if (!last) return;
    if (!CFStringGetCString(last, out, (CFIndex)len, kCFStringEncodingUTF8)) out[0] = 0;
    CFRelease(last);
    size_t n = strlen(out);
    if (n > 4 && strcmp(out + n - 4, ".app") == 0) out[n - 4] = 0;
}

static int app_path(CFURLRef app, char *out, unsigned long len) {
    return CFURLGetFileSystemRepresentation(app, true, (UInt8 *)out, (CFIndex)len) ? 1 : 0;
}

int gtty_open_default_app(const char *path, char *name, unsigned long len) {
    CFURLRef url = file_url(path);
    if (!url) return 0;
    CFURLRef app = LSCopyDefaultApplicationURLForURL(url, kLSRolesAll, NULL);
    CFRelease(url);
    if (!app) return 0;
    app_name(app, name, len);
    CFRelease(app);
    return 1;
}

int gtty_open_apps(const char *path, gtty_app *out, int max) {
    CFURLRef url = file_url(path);
    if (!url) return 0;
    char def[1024] = "";
    CFURLRef d = LSCopyDefaultApplicationURLForURL(url, kLSRolesAll, NULL);
    if (d) {
        app_path(d, def, sizeof def);
        CFRelease(d);
    }
    int n = 0;
    CFArrayRef apps = LSCopyApplicationURLsForURL(url, kLSRolesAll);
    CFRelease(url);
    if (!apps) return 0;
    for (CFIndex i = 0; i < CFArrayGetCount(apps) && n < max; i++) {
        CFURLRef app = CFArrayGetValueAtIndex(apps, i);
        gtty_app a = {0};
        if (!app_path(app, a.id, sizeof a.id)) continue;
        app_name(app, a.name, sizeof a.name);
        if (!a.name[0]) continue;
        a.is_default = def[0] && strcmp(a.id, def) == 0;
        // The same app installed twice (another version): keep the first,
        // unless the second is the default.
        int dup = -1;
        for (int k = 0; k < n; k++) if (strcmp(out[k].name, a.name) == 0) dup = k;
        if (dup >= 0) {
            if (a.is_default) out[dup] = a;
            continue;
        }
        out[n++] = a;
    }
    CFRelease(apps);
    qsort(out, (size_t)n, sizeof *out, by_name);
    return n;
}

int gtty_open_with(const char *path, const char *id) {
    CFURLRef url = file_url(path);
    if (!url) return -1;
    CFURLRef app = NULL;
    if (id) app = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)id, (CFIndex)strlen(id), true);
    CFArrayRef items = CFArrayCreate(NULL, (const void **)&url, 1, &kCFTypeArrayCallBacks);
    LSLaunchURLSpec spec = {
        .appURL = app,
        .itemURLs = items,
        .launchFlags = kLSLaunchDefaults,
    };
    OSStatus st = LSOpenFromURLSpec(&spec, NULL);
    CFRelease(items);
    if (app) CFRelease(app);
    CFRelease(url);
    return st == noErr ? 0 : -1;
}

#else // Linux and other freedesktop systems

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

static void copy_str(char *dst, unsigned long len, const char *src) {
    if (len == 0) return;
    strncpy(dst, src, len - 1);
    dst[len - 1] = 0;
}

// Run argv, its stdout's first line into out (trimmed). 1: got a line.
static int run_line(char *const argv[], char *out, unsigned long len) {
    int fds[2];
    if (len == 0 || pipe(fds) != 0) return 0;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return 0;
    }
    if (pid == 0) {
        dup2(fds[1], 1);
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) {
            dup2(null, 0);
            dup2(null, 2);
        }
        close(fds[0]);
        close(fds[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(fds[1]);
    size_t n = 0;
    ssize_t r;
    while (n + 1 < len && (r = read(fds[0], out + n, len - 1 - n)) > 0) n += (size_t)r;
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    out[n] = 0;
    char *nl = strchr(out, '\n');
    if (nl) *nl = 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 && out[0] != 0;
}

static int mime_type(const char *path, char *out, unsigned long len) {
    char *argv[] = {"xdg-mime", "query", "filetype", (char *)path, NULL};
    return run_line(argv, out, len);
}

// The folders that hold applications/*.desktop, most specific first.
static int data_dirs(char dirs[][1024], int max) {
    int n = 0;
    const char *home = getenv("XDG_DATA_HOME");
    if (home && home[0]) {
        snprintf(dirs[n++], 1024, "%s", home);
    } else if ((home = getenv("HOME"))) {
        snprintf(dirs[n++], 1024, "%s/.local/share", home);
    }
    const char *sys = getenv("XDG_DATA_DIRS");
    if (!sys || !sys[0]) sys = "/usr/local/share:/usr/share";
    while (*sys && n < max) {
        const char *end = strchr(sys, ':');
        size_t l = end ? (size_t)(end - sys) : strlen(sys);
        if (l > 0 && l < 1024) {
            memcpy(dirs[n], sys, l);
            dirs[n++][l] = 0;
        }
        if (!end) break;
        sys = end + 1;
    }
    return n;
}

// Where a desktop id ("org.gnome.TextEditor.desktop") lives, and its Name=.
static int desktop_file(const char *desktop_id, char *path, unsigned long plen, char *name, unsigned long nlen) {
    char dirs[16][1024];
    int nd = data_dirs(dirs, 16);
    for (int i = 0; i < nd; i++) {
        snprintf(path, plen, "%s/applications/%s", dirs[i], desktop_id);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char line[1024];
        int in_entry = 0;
        copy_str(name, nlen, desktop_id);
        char *dot = strstr(name, ".desktop");
        if (dot) *dot = 0;
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '[') in_entry = strncmp(line, "[Desktop Entry]", 15) == 0;
            if (in_entry && strncmp(line, "Name=", 5) == 0) {
                char *nl = strchr(line, '\n');
                if (nl) *nl = 0;
                copy_str(name, nlen, line + 5);
                break;
            }
        }
        fclose(f);
        return 1;
    }
    return 0;
}

int gtty_open_default_app(const char *path, char *name, unsigned long len) {
    char mime[256], id[512], file[1024];
    if (!mime_type(path, mime, sizeof mime)) return -1;
    char *argv[] = {"xdg-mime", "query", "default", mime, NULL};
    if (!run_line(argv, id, sizeof id)) return 0;
    if (!desktop_file(id, file, sizeof file, name, len)) copy_str(name, len, id);
    return 1;
}

static void add_app(gtty_app *out, int *n, int max, const char *desktop_id, int is_default) {
    if (*n >= max) return;
    gtty_app a = {0};
    if (!desktop_file(desktop_id, a.id, sizeof a.id, a.name, sizeof a.name)) return;
    for (int k = 0; k < *n; k++) if (strcmp(out[k].id, a.id) == 0) {
        if (is_default) out[k].is_default = 1;
        return;
    }
    a.is_default = is_default;
    out[(*n)++] = a;
}

int gtty_open_apps(const char *path, gtty_app *out, int max) {
    char mime[256];
    if (!mime_type(path, mime, sizeof mime)) return 0;
    int n = 0;
    char def[512];
    char *argv[] = {"xdg-mime", "query", "default", mime, NULL};
    if (run_line(argv, def, sizeof def)) add_app(out, &n, max, def, 1);

    char dirs[16][1024];
    int nd = data_dirs(dirs, 16);
    size_t ml = strlen(mime);
    for (int i = 0; i < nd; i++) {
        char cache[1100];
        snprintf(cache, sizeof cache, "%s/applications/mimeinfo.cache", dirs[i]);
        FILE *f = fopen(cache, "r");
        if (!f) continue;
        char line[8192];
        while (fgets(line, sizeof line, f)) {
            if (strncmp(line, mime, ml) != 0 || line[ml] != '=') continue;
            char *save = NULL;
            for (char *id = strtok_r(line + ml + 1, ";\n", &save); id; id = strtok_r(NULL, ";\n", &save))
                add_app(out, &n, max, id, 0);
        }
        fclose(f);
    }
    qsort(out, (size_t)n, sizeof *out, by_name);
    return n;
}

int gtty_open_with(const char *path, const char *id) {
    // Detached: the app outlives gtty and leaves no zombie.
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        if (fork() != 0) _exit(0);
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) {
            dup2(null, 0);
            dup2(null, 1);
            dup2(null, 2);
        }
        if (!id) {
            char *argv[] = {"xdg-open", (char *)path, NULL};
            execvp(argv[0], argv);
            _exit(127);
        }
        char *gio[] = {"gio", "launch", (char *)id, (char *)path, NULL};
        execvp(gio[0], gio);
        // No gio: gtk-launch takes the desktop id ("org.x.App", no folder).
        char base[512];
        const char *slash = strrchr(id, '/');
        copy_str(base, sizeof base, slash ? slash + 1 : id);
        char *dot = strstr(base, ".desktop");
        if (dot) *dot = 0;
        char *gtk[] = {"gtk-launch", base, (char *)path, NULL};
        execvp(gtk[0], gtk);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return 0;
}

#endif

// ---------------------------------------------------------------- new gtty

#include <fcntl.h>
#include <limits.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

int gtty_open_new_instance(const char *cwd, const char *geometry) {
    char exe[PATH_MAX];
#if defined(__APPLE__)
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return -1;
#else
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) return -1;
    exe[n] = 0;
#endif
    char real[PATH_MAX];
    if (realpath(exe, real) == NULL) return -1;
    // Twice forked: the new gtty is nobody's child here (no zombie, and
    // it outlives this one). The middle child sends its pid back.
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);
        setsid();
        pid_t gtty = fork();
        if (gtty != 0) {
            if (gtty > 0) (void)!write(fds[1], &gtty, sizeof gtty);
            _exit(gtty > 0 ? 0 : 1);
        }
        if (cwd && chdir(cwd) != 0) _exit(127);
        if (geometry) setenv("GTTY_WINDOW", geometry, 1);
        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) {
            dup2(fd, 0);
            if (fd > 2) close(fd);
        }
        for (int i = 3; i < 1024; i++) close(i);
        execl(real, real, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    pid_t gtty = -1;
    if (read(fds[0], &gtty, sizeof gtty) != (ssize_t)sizeof gtty) gtty = -1;
    close(fds[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
    }
    return gtty;
}
