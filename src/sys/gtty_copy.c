// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Copying dropped files into a folder (see gtty_copy.h).

#include "gtty_copy.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// A free name in `dest` for `base`: "base", else "stem 2.ext", "stem 3.ext"…
static int freeName(char *out, size_t len, const char *dest, const char *base, int is_dir) {
    struct stat st;
    if (snprintf(out, len, "%s/%s", dest, base) >= (int)len) return -1;
    if (lstat(out, &st) != 0) return 0;
    const char *dot = is_dir ? NULL : strrchr(base, '.');
    if (dot == base) dot = NULL; // ".hidden": no extension
    int stem = dot ? (int)(dot - base) : (int)strlen(base);
    for (int k = 2; k < 10000; k++) {
        if (snprintf(out, len, "%s/%.*s %d%s", dest, stem, base, k, dot ? dot : "") >= (int)len) return -1;
        if (lstat(out, &st) != 0) return 0;
    }
    return -1;
}

// Run `argv` and wait; 0 when it exited with 0.
static int run(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int fd = open("/dev/null", O_RDWR);
        if (fd >= 0) {
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    int ws = 0;
    while (waitpid(pid, &ws, 0) < 0 && errno == EINTR) {
    }
    return WIFEXITED(ws) && WEXITSTATUS(ws) == 0 ? 0 : -1;
}

// Where `src` goes in `dest`: a free name there (`target`). -1: can't (a
// folder into itself, no name, too long).
static int targetFor(char *target, size_t len, const char *src, const char *dest) {
    struct stat st;
    if (lstat(src, &st) != 0) return -1;
    int is_dir = S_ISDIR(st.st_mode);
    size_t sl = strlen(src);
    while (sl > 1 && src[sl - 1] == '/') sl--;
    if (is_dir && strncmp(dest, src, sl) == 0 && (dest[sl] == 0 || dest[sl] == '/')) return -1;
    const char *base = src + sl;
    while (base > src && base[-1] != '/') base--;
    char name[PATH_MAX];
    if (sl - (size_t)(base - src) >= sizeof name) return -1;
    memcpy(name, base, sl - (size_t)(base - src));
    name[sl - (size_t)(base - src)] = 0;
    if (name[0] == 0) return -1;
    return freeName(target, len, dest, name, is_dir);
}

static int moveOne(const char *src, const char *dest) {
    char target[PATH_MAX];
    if (targetFor(target, sizeof target, src, dest) != 0) return -1;
    if (rename(src, target) == 0) return 0;
    if (errno != EXDEV) return -1;
    // Another disk: copy, then remove the original.
    char *cp[] = {"cp", "-Rp", "--", (char *)src, target, NULL};
    if (run(cp) != 0) return -1;
    char *rm[] = {"rm", "-rf", "--", (char *)src, NULL};
    return run(rm);
}

static int removeOne(const char *src) {
    char *rm[] = {"rm", "-rf", "--", (char *)src, NULL};
    return run(rm);
}

static int copyOne(const char *src, const char *dest) {
    struct stat st;
    if (lstat(src, &st) != 0) return -1;
    int is_dir = S_ISDIR(st.st_mode);
    // Not a folder into itself (or below it).
    size_t sl = strlen(src);
    while (sl > 1 && src[sl - 1] == '/') sl--;
    if (is_dir && strncmp(dest, src, sl) == 0 && (dest[sl] == 0 || dest[sl] == '/')) return -1;
    const char *base = src + sl;
    while (base > src && base[-1] != '/') base--;
    char name[PATH_MAX];
    if (sl - (size_t)(base - src) >= sizeof name) return -1;
    memcpy(name, base, sl - (size_t)(base - src));
    name[sl - (size_t)(base - src)] = 0;
    if (name[0] == 0) return -1;
    char target[PATH_MAX];
    if (freeName(target, sizeof target, dest, name, is_dir) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int fd = open("/dev/null", O_RDWR);
        if (fd >= 0) {
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
        }
        execlp("cp", "cp", "-Rp", "--", src, target, (char *)NULL);
        _exit(127);
    }
    int ws = 0;
    while (waitpid(pid, &ws, 0) < 0 && errno == EINTR) {
    }
    return WIFEXITED(ws) && WEXITSTATUS(ws) == 0 ? 0 : -1;
}

int gtty_copy_start(const char *const *srcs, int n, const char *dest) {
    if (srcs == NULL || n <= 0 || dest == NULL) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int failed = 0;
        for (int i = 0; i < n; i++)
            if (srcs[i] == NULL || copyOne(srcs[i], dest) != 0) failed++;
        _exit(failed > 255 ? 255 : failed);
    }
    return (int)pid;
}

int gtty_move_start(const char *const *srcs, int n, const char *dest) {
    if (srcs == NULL || n <= 0 || dest == NULL) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int failed = 0;
        for (int i = 0; i < n; i++)
            if (srcs[i] == NULL || moveOne(srcs[i], dest) != 0) failed++;
        _exit(failed > 255 ? 255 : failed);
    }
    return (int)pid;
}

int gtty_remove_start(const char *const *srcs, int n) {
    if (srcs == NULL || n <= 0) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int failed = 0;
        for (int i = 0; i < n; i++)
            if (srcs[i] == NULL || srcs[i][0] != '/' || removeOne(srcs[i]) != 0) failed++;
        _exit(failed > 255 ? 255 : failed);
    }
    return (int)pid;
}

int gtty_copy_poll(int pid) {
    int ws = 0;
    pid_t r = waitpid((pid_t)pid, &ws, WNOHANG);
    if (r == 0) return -1;
    if (r < 0) return errno == EINTR ? -1 : 255;
    return WIFEXITED(ws) ? WEXITSTATUS(ws) : 255;
}
