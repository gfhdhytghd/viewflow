// Dedicated, non-business Wayland target for cross-host input acceptance.
// Build with generated xdg-shell client headers and wayland-client.
#define _GNU_SOURCE
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static volatile sig_atomic_t running = 1;
static double px, py;
static unsigned buttons, count;
enum { WIDTH = 800, HEIGHT = 500 };

static void stop(int sig) { (void)sig; running = 0; }
static void enter(void *data, struct wl_pointer *p, uint32_t serial,
                  struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p;
    px = wl_fixed_to_double(x); py = wl_fixed_to_double(y);
    printf("{\"event\":\"enter\",\"serial\":%u,\"own_surface\":%s,\"x\":%.3f,\"y\":%.3f}\n",
           serial, s == surface ? "true" : "false", px, py);
}
static void leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
    (void)data; (void)p; (void)s;
    printf("{\"event\":\"leave\",\"serial\":%u,\"held\":%u}\n", serial, buttons);
}
static void motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p;
    px = wl_fixed_to_double(x); py = wl_fixed_to_double(y);
    if (count++ < 2048) printf("{\"event\":\"motion\",\"time\":%u,\"x\":%.3f,\"y\":%.3f,\"held\":%u}\n", time, px, py, buttons);
}
static void button(void *data, struct wl_pointer *p, uint32_t serial, uint32_t time,
                   uint32_t code, uint32_t state) {
    (void)data; (void)p;
    if (code >= 272 && code <= 276) {
        unsigned bit = 1u << (code - 272);
        if (state) buttons |= bit; else buttons &= ~bit;
    }
    printf("{\"event\":\"button\",\"serial\":%u,\"time\":%u,\"button\":%u,\"state\":%u,\"x\":%.3f,\"y\":%.3f,\"held\":%u}\n",
           serial, time, code, state, px, py, buttons);
}
static void axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {(void)d;(void)p;(void)t;(void)a;(void)v;}
static void frame(void *d, struct wl_pointer *p) {(void)d;(void)p;}
static void source(void *d, struct wl_pointer *p, uint32_t a) {(void)d;(void)p;(void)a;}
static void axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) {(void)d;(void)p;(void)t;(void)a;}
static void discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) {(void)d;(void)p;(void)a;(void)v;}
static const struct wl_pointer_listener pointer_listener = {
    .enter=enter, .leave=leave, .motion=motion, .button=button, .axis=axis,
    .frame=frame, .axis_source=source, .axis_stop=axis_stop, .axis_discrete=discrete,
};
static void capabilities(void *d, struct wl_seat *s, uint32_t caps) {
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *name) {(void)d;(void)s;(void)name;}
static const struct wl_seat_listener seat_listener = {.capabilities=capabilities, .name=seat_name};
static void ping(void *d, struct xdg_wm_base *w, uint32_t serial) {(void)d; xdg_wm_base_pong(w, serial);}
static const struct xdg_wm_base_listener wm_listener = {.ping=ping};
static void global(void *d, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)d;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "wl_seat") && !seat) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, version < 7 ? version : 7);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t n) {(void)d;(void)r;(void)n;}
static const struct wl_registry_listener registry_listener = {.global=global, .global_remove=removed};
static void configure(void *d, struct xdg_surface *s, uint32_t serial) {
    (void)d;
    xdg_surface_ack_configure(s, serial);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(surface);
    printf("{\"event\":\"configured\",\"width\":%d,\"height\":%d}\n", WIDTH, HEIGHT);
}
static const struct xdg_surface_listener surface_listener = {.configure=configure};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {(void)d;(void)t;(void)w;(void)h;(void)s;}
static void top_close(void *d, struct xdg_toplevel *t) {(void)d;(void)t;running=0;}
static const struct xdg_toplevel_listener top_listener = {.configure=top_configure, .close=top_close};
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGALRM, stop); alarm(180);
    display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !wm || !seat) return 2;
    int fd = memfd_create("viewflow-button-probe", MFD_CLOEXEC);
    size_t bytes = WIDTH * HEIGHT * 4;
    if (fd < 0 || ftruncate(fd, (off_t)bytes)) return 3;
    uint32_t *pixels = mmap(NULL, bytes, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) return 4;
    for (int y=0; y<HEIGHT; ++y) for (int x=0; x<WIDTH; ++x) {
        uint32_t color = 0xff162635;
        if (x>80 && x<720 && y>80 && y<420) color = 0xffddeeff;
        if (y<40) color = x<WIDTH/2 ? 0xff32ba70 : 0xff367ed0;
        if (y>460) color = x<WIDTH/2 ? 0xffd24b4b : 0xffeeb949;
        pixels[y*WIDTH+x] = color;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)bytes);
    buffer = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, WIDTH*4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool); close(fd);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "Viewflow button acceptance probe");
    xdg_toplevel_set_app_id(top, "viewflow.button-probe");
    xdg_toplevel_set_min_size(top, WIDTH, HEIGHT);
    xdg_toplevel_set_max_size(top, WIDTH, HEIGHT);
    wl_surface_commit(surface);
    printf("{\"event\":\"started\",\"pid\":%d}\n", getpid());
    while (running) {
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) goto done;
        }
        wl_display_flush(display);
        struct pollfd ready = {.fd=wl_display_get_fd(display), .events=POLLIN};
        int result = poll(&ready, 1, 500);
        if (result > 0 && (ready.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) break;
        } else {
            wl_display_cancel_read(display);
            if (result > 0 && (ready.revents & (POLLERR|POLLHUP|POLLNVAL))) break;
        }
        if (wl_display_dispatch_pending(display) < 0) break;
    }
done:
    printf("{\"event\":\"ended\",\"held\":%u}\n", buttons);
    wl_display_disconnect(display);
    return 0;
}
