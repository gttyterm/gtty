// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux: the desktop's trash through its command-line tools (see
// gtty_trash.h).
#include "gtty_trash.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

enum tool { NONE, GIO, TRASH_PUT, KIO6, KIO5 };
static int tool = -1;

// `name` is an executable in $PATH.
static bool inPath(const char *name) {
    const char *p = getenv("PATH");
    if (p == NULL) return false;
    char buf[PATH_MAX];
    while (*p) {
        const char *e = strchr(p, ':');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n > 0 && snprintf(buf, sizeof buf, "%.*s/%s", (int)n, p, name) < (int)sizeof buf && access(buf, X_OK) == 0) return true;
        if (!e) break;
        p = e + 1;
    }
    return false;
}

bool gtty_trash_supported(void) {
    if (tool < 0) {
        tool = NONE;
        // A desktop session (the trash is the desktop's).
        if (getenv("XDG_CURRENT_DESKTOP") == NULL && getenv("WAYLAND_DISPLAY") == NULL && getenv("DISPLAY") == NULL) return false;
        if (inPath("gio")) tool = GIO;
        else if (inPath("trash-put")) tool = TRASH_PUT;
        else if (inPath("kioclient6")) tool = KIO6;
        else if (inPath("kioclient5")) tool = KIO5;
    }
    return tool != NONE;
}

int gtty_trash(const char *path) {
    if (path == NULL || !gtty_trash_supported()) return -1;
    char *argv[6] = {0};
    switch (tool) {
    case GIO: argv[0] = "gio"; argv[1] = "trash"; argv[2] = "--"; argv[3] = (char *)path; break;
    case TRASH_PUT: argv[0] = "trash-put"; argv[1] = "--"; argv[2] = (char *)path; break;
    case KIO6: argv[0] = "kioclient6"; argv[1] = "move"; argv[2] = (char *)path; argv[3] = "trash:/"; break;
    case KIO5: argv[0] = "kioclient5"; argv[1] = "move"; argv[2] = (char *)path; argv[3] = "trash:/"; break;
    default: return -1;
    }
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
