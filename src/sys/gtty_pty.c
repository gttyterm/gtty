// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// gtty — process spawning on pseudo-terminals.
//
// A job gets one PTY for stdin+stdout (its controlling terminal) and,
// in split mode, a second PTY for stderr. Both slave sides are real
// terminals, so the child still sees isatty() == true on every fd and
// keeps its colors, prompts and progress bars.
//
// This file is plain C on purpose: the PTY headers differ between
// Linux (<pty.h>) and macOS (<util.h>), and fork/exec is easier to keep
// async-signal-safe here than through Zig's translated headers.

#define _GNU_SOURCE
#include "gtty_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <arpa/inet.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <util.h>
#else
#include <pty.h>
#endif

static void set_nonblock_cloexec(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl >= 0) fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
}

int gtty_spawn(const char *const argv[], int split, unsigned short cols,
               unsigned short rows, const char *term, const char *cwd,
               const char *const env[],
               int *out_master, int *err_master, int *pid_out) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols ? cols : 80;
    ws.ws_row = rows ? rows : 24;

    int om = -1, os = -1, em = -1, es = -1;
    if (openpty(&om, &os, NULL, NULL, &ws) != 0) return -errno;
    if (split) {
        if (openpty(&em, &es, NULL, NULL, &ws) != 0) {
            int e = errno;
            close(om);
            close(os);
            return -e;
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(om); close(os);
        if (split) { close(em); close(es); }
        return -e;
    }

    if (pid == 0) {
        // Child. Only async-signal-safe calls (plus setenv, which is fine
        // in practice for a single-threaded child about to exec).
        setsid();
        ioctl(os, TIOCSCTTY, 0);
        dup2(os, 0);
        dup2(os, 1);
        dup2(split ? es : os, 2);
        if (os > 2) close(os);
        if (split && es > 2) close(es);
        close(om);
        if (split) close(em);

        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);

        setenv("TERM", term ? term : "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("GTTY", "1", 1);
        // Extra "NAME=value" pairs (shell hooks), NULL-terminated.
        for (int i = 0; env && env[i]; i++) putenv((char *)env[i]);
        if (cwd && cwd[0]) (void)chdir(cwd);

        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }

    // Parent.
    close(os);
    if (split) close(es);
    set_nonblock_cloexec(om);
    if (split) set_nonblock_cloexec(em);

    *out_master = om;
    *err_master = split ? em : -1;
    *pid_out = (int)pid;
    return 0;
}

int gtty_resize(int master_fd, unsigned short cols, unsigned short rows) {
    if (master_fd < 0) return 0;
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(master_fd, TIOCSWINSZ, &ws) == 0 ? 0 : -errno;
}

long gtty_read(int fd, unsigned char *buf, unsigned long len) {
    ssize_t n = read(fd, buf, len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return GTTY_AGAIN;
        return GTTY_EOF; // EIO: slave side closed (child exited)
    }
    if (n == 0) return GTTY_EOF;
    return (long)n;
}

long gtty_write(int fd, const unsigned char *buf, unsigned long len) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
        return -1;
    }
    return (long)n;
}

int gtty_poll_exit(int pid, int *code) {
    int status = 0;
    pid_t r = waitpid((pid_t)pid, &status, WNOHANG);
    if (r == 0) return 0;     // still running
    if (r < 0) {              // already reaped / not our child
        *code = -1;
        return 1;
    }
    if (WIFEXITED(status)) *code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *code = 128 + WTERMSIG(status);
    else *code = -1;
    return 1;
}

void gtty_hangup(int pid) {
    if (pid <= 0) return;
    // The child called setsid(), so its pid is also its process group.
    kill(-(pid_t)pid, SIGHUP);
    kill((pid_t)pid, SIGHUP);
}

void gtty_kill(int pid) {
    if (pid <= 0) return;
    kill(-(pid_t)pid, SIGKILL);
    kill((pid_t)pid, SIGKILL);
}

void gtty_close(int fd) {
    if (fd >= 0) close(fd);
}

void gtty_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); }

// The current folder of a running process (a shell window follows the
// shell's `cd`). Returns the length written into buf (NUL-terminated), or
// -1 if it can't be read.
long gtty_proc_cwd(int pid, char *buf, unsigned long len) {
    if (pid <= 0 || len < 2) return -1;
#if defined(__APPLE__)
    struct proc_vnodepathinfo vpi;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) != (int)sizeof vpi) return -1;
    size_t n = strnlen(vpi.pvi_cdir.vip_path, sizeof vpi.pvi_cdir.vip_path);
    if (n == 0 || n >= len) return -1;
    memcpy(buf, vpi.pvi_cdir.vip_path, n);
    buf[n] = 0;
    return (long)n;
#else
    char link[64];
    snprintf(link, sizeof link, "/proc/%d/cwd", pid);
    ssize_t n = readlink(link, buf, len - 1);
    if (n <= 0) return -1;
    buf[n] = 0;
    return (long)n;
#endif
}

// ---------------------------------------------------------------- looking
// at other processes (remote sessions: the user's ssh, read-only)

int gtty_fg_pid(int master) {
    if (master < 0) return -1;
    pid_t pg = tcgetpgrp(master);
    return pg > 0 ? (int)pg : -1;
}

// argv (which = 0) or the environment (which = 1) of pid, each string
// ending in a NUL. Returns the bytes written, or -1.
static long proc_strings(int pid, int which, char *buf, unsigned long len) {
    if (pid <= 0 || len < 2) return -1;
#if defined(__APPLE__)
    // KERN_PROCARGS2: argc, the executable path, padding NULs, argv, env.
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    static char raw[256 * 1024];
    size_t size = sizeof raw;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0 || size < sizeof(int)) return -1;
    int argc;
    memcpy(&argc, raw, sizeof argc);
    size_t i = sizeof argc;
    while (i < size && raw[i] != 0) i++; // the executable path
    while (i < size && raw[i] == 0) i++; // padding
    unsigned long n = 0;
    for (int a = 0; i < size; a++) {
        size_t start = i;
        while (i < size && raw[i] != 0) i++;
        size_t k = i - start;
        i++;
        if (a >= argc && k == 0) break; // the end of the environment
        int want = which == 0 ? a < argc : a >= argc;
        if (!want) {
            if (which == 0) break;
            continue;
        }
        if (n + k + 1 > len) break;
        memcpy(buf + n, raw + start, k);
        buf[n + k] = 0;
        n += k + 1;
    }
    return n > 0 ? (long)n : -1;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/%s", pid, which == 0 ? "cmdline" : "environ");
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    unsigned long n = 0;
    for (;;) {
        ssize_t r = read(fd, buf + n, len - n);
        if (r <= 0) break;
        n += (unsigned long)r;
        if (n == len) break;
    }
    close(fd);
    return n > 0 ? (long)n : -1;
#endif
}

long gtty_proc_args(int pid, char *buf, unsigned long len) { return proc_strings(pid, 0, buf, len); }
long gtty_proc_env(int pid, char *buf, unsigned long len) { return proc_strings(pid, 1, buf, len); }

long gtty_fg_args(int master, char *buf, unsigned long len) {
    int pid = gtty_fg_pid(master);
    return pid > 0 ? gtty_proc_args(pid, buf, len) : -1;
}

int gtty_proc_tcp_lport(int pid) {
    if (pid <= 0) return -1;
#if defined(__APPLE__)
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    struct proc_fdinfo fds[512];
    if (bytes > (int)sizeof fds) bytes = sizeof fds;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int count = bytes / (int)sizeof(struct proc_fdinfo);
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo si;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != (int)sizeof si) continue;
        if (si.psi.soi_kind != SOCKINFO_TCP) continue;
        return ntohs((unsigned short)si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
    }
    return -1;
#else
    // The socket inodes of its fds, then their local port in /proc/net/tcp*.
    char dir[64];
    snprintf(dir, sizeof dir, "/proc/%d/fd", pid);
    DIR *d = opendir(dir);
    if (!d) return -1;
    unsigned long inodes[64];
    int ni = 0;
    struct dirent *e;
    while ((e = readdir(d)) && ni < 64) {
        char p[128], link[64];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        ssize_t n = readlink(p, link, sizeof link - 1);
        if (n <= 0) continue;
        link[n] = 0;
        unsigned long ino;
        if (sscanf(link, "socket:[%lu]", &ino) == 1) inodes[ni++] = ino;
    }
    closedir(d);
    const char *tables[2] = {"/proc/net/tcp", "/proc/net/tcp6"};
    for (int t = 0; t < 2; t++) {
        FILE *f = fopen(tables[t], "r");
        if (!f) continue;
        char line[512];
        if (!fgets(line, sizeof line, f)) { fclose(f); continue; } // header
        while (fgets(line, sizeof line, f)) {
            char local[128];
            unsigned long ino = 0;
            // sl local rem st tx:rx tr:tm retr uid timeout inode
            if (sscanf(line, "%*s %127s %*s %*s %*s %*s %*s %*s %*s %lu", local, &ino) != 2) continue;
            for (int k = 0; k < ni; k++) if (inodes[k] == ino) {
                char *colon = strrchr(local, ':');
                fclose(f);
                return colon ? (int)strtol(colon + 1, NULL, 16) : -1;
            }
        }
        fclose(f);
    }
    return -1;
#endif
}

int gtty_spawn_pipes(const char *const argv[], const char *const env[], const char *cwd,
                     int *in_fd, int *out_fd, int *pid_out) {
    int in[2], out[2];
    if (pipe(in) != 0) return -errno;
    if (pipe(out) != 0) {
        int e = errno;
        close(in[0]); close(in[1]);
        return -e;
    }
    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(in[0]); close(in[1]); close(out[0]); close(out[1]);
        return -e;
    }
    if (pid == 0) {
        // No terminal at all (setsid, stdin a pipe): nothing can ask the
        // user anything.
        setsid();
        dup2(in[0], 0);
        dup2(out[1], 1);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, 2);
        close(in[0]); close(in[1]); close(out[0]); close(out[1]);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        if (cwd && cwd[0]) (void)chdir(cwd);
        if (env) {
            extern char **environ;
            environ = (char **)env;
        }
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(in[0]);
    close(out[1]);
    set_nonblock_cloexec(in[1]);
    set_nonblock_cloexec(out[0]);
    *in_fd = in[1];
    *out_fd = out[0];
    *pid_out = (int)pid;
    return 0;
}
