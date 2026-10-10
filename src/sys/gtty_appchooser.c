// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux: choose the app that opens a file (see gtty_appchooser.h) through
// the desktop portal: org.freedesktop.portal.OpenURI.OpenFile with
// "ask" = true shows the desktop's own app chooser (GNOME, KDE, …), and
// the portal opens the file with the app picked. Called on a thread
// (D-Bus activation of the portal can take a moment); libgio through
// dlopen, its few types declared here.

#include "gtty_appchooser.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <SDL3/SDL.h>

typedef struct {
    unsigned int domain;
    int code;
    char *message;
} GError;

typedef void *(*bus_get_sync_fn)(int, void *, GError **);
typedef void *(*fd_list_new_fn)(void);
typedef int (*fd_list_append_fn)(void *, int, GError **);
typedef void *(*builder_new_fn)(const char *);
typedef void (*builder_add_fn)(void *, const char *, ...);
typedef void (*builder_unref_fn)(void *);
typedef void *(*variant_new_fn)(const char *, ...);
typedef void *(*variant_new_boolean_fn)(int);
typedef void *(*call_fd_sync_fn)(void *, const char *, const char *, const char *, const char *, void *,
                                 const char *, int, int, void *, void **, void *, GError **);
typedef void (*unref_fn)(void *);
typedef void (*error_free_fn)(GError *);

static atomic_int busy;
static atomic_int result;
static char result_text[512];

struct job {
    char *path;
    char parent[64];
};

static void finish(int r, const char *text) {
    snprintf(result_text, sizeof result_text, "%s", text ? text : "");
    atomic_store(&result, r);
    atomic_store(&busy, 0);
}

static void *run(void *arg) {
    struct job *j = arg;
    void *gio = dlopen("libgio-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!gio) {
        finish(-1, "no app chooser here (libgio is missing)");
        goto out;
    }
    bus_get_sync_fn bus_get_sync = (bus_get_sync_fn)dlsym(gio, "g_bus_get_sync");
    fd_list_new_fn fd_list_new = (fd_list_new_fn)dlsym(gio, "g_unix_fd_list_new");
    fd_list_append_fn fd_list_append = (fd_list_append_fn)dlsym(gio, "g_unix_fd_list_append");
    builder_new_fn builder_new = (builder_new_fn)dlsym(gio, "g_variant_builder_new");
    builder_add_fn builder_add = (builder_add_fn)dlsym(gio, "g_variant_builder_add");
    builder_unref_fn builder_unref = (builder_unref_fn)dlsym(gio, "g_variant_builder_unref");
    variant_new_fn variant_new = (variant_new_fn)dlsym(gio, "g_variant_new");
    variant_new_boolean_fn variant_new_boolean = (variant_new_boolean_fn)dlsym(gio, "g_variant_new_boolean");
    call_fd_sync_fn call = (call_fd_sync_fn)dlsym(gio, "g_dbus_connection_call_with_unix_fd_list_sync");
    unref_fn variant_unref = (unref_fn)dlsym(gio, "g_variant_unref");
    unref_fn object_unref = (unref_fn)dlsym(gio, "g_object_unref");
    error_free_fn error_free = (error_free_fn)dlsym(gio, "g_error_free");
    if (!bus_get_sync || !fd_list_new || !fd_list_append || !builder_new || !builder_add || !builder_unref ||
        !variant_new || !variant_new_boolean || !call || !variant_unref || !object_unref || !error_free) {
        finish(-1, "no app chooser here (libgio too old)");
        goto out;
    }
    GError *err = NULL;
    void *bus = bus_get_sync(2 /* G_BUS_TYPE_SESSION */, NULL, &err);
    if (!bus) {
        finish(-1, "no app chooser here (no session bus)");
        if (err) error_free(err);
        goto out;
    }
    int fd = open(j->path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        finish(-1, "can't read the file");
        object_unref(bus);
        goto out;
    }
    void *fds = fd_list_new();
    int handle = fd_list_append(fds, fd, NULL); // dups it
    close(fd);
    void *opts = builder_new("a{sv}"); // a GVariantType is its type string
    builder_add(opts, "{sv}", "ask", variant_new_boolean(1));
    builder_add(opts, "{sv}", "writable", variant_new_boolean(0));
    void *params = variant_new("(sha{sv})", j->parent, handle, opts);
    builder_unref(opts);
    void *reply = call(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                       "org.freedesktop.portal.OpenURI", "OpenFile", params, "(o)", 0, 10000, fds, NULL, NULL,
                       &err);
    object_unref(fds);
    object_unref(bus);
    if (reply) {
        variant_unref(reply);
        finish(3, NULL);
    } else {
        char why[400];
        snprintf(why, sizeof why, "no app chooser here (%s)", err && err->message ? err->message : "no desktop portal");
        finish(-1, why);
        if (err) error_free(err);
    }
out:
    // libgio stays loaded: GDBus keeps a worker thread running.
    free(j->path);
    free(j);
    return NULL;
}

int gtty_choose_app(void *sdl_window, const char *path, char *why, unsigned long len) {
    if (atomic_load(&busy)) {
        if (len) snprintf(why, len, "the app chooser is still starting");
        return 0;
    }
    struct job *j = calloc(1, sizeof *j);
    if (!j || !(j->path = strdup(path))) {
        free(j);
        if (len) snprintf(why, len, "out of memory");
        return 0;
    }
    // X11: the dialog belongs to gtty's window ("x11:<hex id>").
    if (sdl_window) {
        SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
        long long xid = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (xid) snprintf(j->parent, sizeof j->parent, "x11:%llx", xid);
    }
    atomic_store(&busy, 1);
    atomic_store(&result, 0);
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&t, &attr, run, j);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        atomic_store(&busy, 0);
        free(j->path);
        free(j);
        if (len) snprintf(why, len, "can't start the app chooser");
        return 0;
    }
    return 1;
}

int gtty_choose_app_take(char *name, unsigned long len) {
    int r = atomic_exchange(&result, 0);
    if (r != 0 && len) snprintf(name, len, "%s", result_text);
    return r;
}

int gtty_app_icon(const char *id, int px, unsigned char *rgba) {
    (void)id;
    (void)px;
    (void)rgba;
    return 0;
}
