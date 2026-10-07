// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// A stand-in "ssh" for tests: the "remote machine" is this one.
// With a remote command (gtty's own connection): runs it with sh -c
// (FAKE_SSH_NOLINK set: fails, like a host that wants a password).
// Without one (the user's session): an interactive bash on its own
// terminal (via script(1)) with SSH_CONNECTION set, while this process
// stays in front on the window's terminal, as a real ssh does.
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static const char *with_value = "BbcDEeFIiJLlmOoPpQRSWw";
int main(int argc, char **argv) {
    int i = 1;
    for (; i < argc; i++) {
        const char *a = argv[i];
        if (a[0] != '-' || !a[1]) break;
        for (int k = 1; a[k]; k++) if (strchr(with_value, a[k])) { if (!a[k + 1]) i++; break; }
    }
    if (i >= argc) return 255;
    if (i + 1 < argc) { // a remote command
        // A host gtty can't log in to (e.g. it wants a password).
        if (getenv("FAKE_SSH_NOLINK")) return 255;
        execlp("sh", "sh", "-c", argv[i + 1], (char *)0);
        return 127;
    }
    pid_t pid = fork();
    if (pid == 0 && getenv("FAKE_SSH_NESTED")) {
        // A hop from inside a session: no second stand-in sshd (it would
        // make the session ambiguous for gtty without a real TCP port).
        execlp("script", "script", "-q", "/dev/null", "bash", "--norc", "-i", (char *)0);
        _exit(127);
    }
    if (pid == 0) {
        setenv("SSH_CONNECTION", "127.0.0.1 40000 127.0.0.1 22", 1);
        // A stand-in for the session's sshd ("sshd: me@ttysNNN") on the new
        // terminal, then the user's shell.
        execlp("script", "script", "-q", "/dev/null", "bash", "-c",
               "t=$(tty); (exec -a \"sshd: $USER@${t#/dev/}\" sleep 100000 </dev/null >/dev/null 2>&1 &); exec bash --norc -i",
               (char *)0);
        _exit(127);
    }
    int st;
    waitpid(pid, &st, 0);
    return 0;
}
