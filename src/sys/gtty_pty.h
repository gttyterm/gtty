// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef GTTY_PTY_H
#define GTTY_PTY_H

#define GTTY_AGAIN (-1L)
#define GTTY_EOF (-2L)

// Spawn argv on fresh PTYs. On success returns 0 and fills the master fds
// (err_master is -1 unless split != 0) and the child pid. Returns -errno on error.
int gtty_spawn(const char *const argv[], int split, unsigned short cols,
               unsigned short rows, const char *term, const char *cwd,
               const char *const env[],
               int *out_master, int *err_master, int *pid_out);

int gtty_resize(int master_fd, unsigned short cols, unsigned short rows);

// Returns bytes read, GTTY_AGAIN when nothing is available, GTTY_EOF when closed.
long gtty_read(int fd, unsigned char *buf, unsigned long len);
long gtty_write(int fd, const unsigned char *buf, unsigned long len);

// Returns 1 and sets *code once the child has exited, 0 while it runs.
int gtty_poll_exit(int pid, int *code);

void gtty_hangup(int pid);
void gtty_kill(int pid);
void gtty_close(int fd);
void gtty_ignore_sigpipe(void);

// Current folder of a running process; length written, or -1.
long gtty_proc_cwd(int pid, char *buf, unsigned long len);

// Looking at other processes (read-only; remote sessions).
// The process group in front on the terminal of master fd `master`
// (its leader's pid), or -1.
int gtty_fg_pid(int master);
// The command line of the program in front on that terminal: its
// arguments, each ending in a NUL, in buf. Bytes written, or -1.
long gtty_fg_args(int master, char *buf, unsigned long len);
// argv / environment of a process ("NAME=value"), each ending in a NUL.
long gtty_proc_args(int pid, char *buf, unsigned long len);
long gtty_proc_env(int pid, char *buf, unsigned long len);
// The local port of the process's first TCP connection, or -1.
int gtty_proc_tcp_lport(int pid);

// Spawn argv with exactly the environment `env` (NULL-terminated
// "NAME=value"; NULL: gtty's) in folder cwd, stdin / stdout on
// non-blocking pipes, stderr to /dev/null, no terminal (setsid).
int gtty_spawn_pipes(const char *const argv[], const char *const env[], const char *cwd,
                     int *in_fd, int *out_fd, int *pid_out);

#endif
