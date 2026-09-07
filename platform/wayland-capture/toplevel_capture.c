#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "ext-foreign-toplevel-list-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#define DEFAULT_TIMEOUT_MS 5000u
#define MAX_TIMEOUT_MS 30000u
#define DEFAULT_MAX_BYTES (256u * 1024u * 1024u)
#define MAX_TOPLEVELS 4096u
#define MAX_PROPERTY_BYTES 4096u

struct toplevel {
    struct ext_foreign_toplevel_handle_v1 *handle;
    char *identifier;
    char *title;
    char *app_id;
    int ready;
    int closed;
};

struct state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_shm *shm;
    struct ext_foreign_toplevel_list_v1 *list;
    struct ext_foreign_toplevel_image_capture_source_manager_v1 *source_manager;
    struct ext_image_copy_capture_manager_v1 *capture_manager;
    struct toplevel **tops;
    size_t top_count;
    size_t top_capacity;
    int list_finished;
    int protocol_error;
};

struct sync_wait { int done; };
struct constraints {
    uint32_t width, height, generation;
    uint32_t formats[8];
    size_t format_count;
    int done, stopped;
    int *capture_done;
};
struct frame_result {
    int ready, failed, done;
    uint32_t transform;
    int saw_transform;
    uint32_t presentation_hi, presentation_lo, presentation_nsec;
    int saw_presentation;
    uint64_t ready_monotonic_ms;
};
struct capture_spec { uint32_t width, height, format, constraint_generation; size_t size; };

static void fail(const char *message) { fprintf(stderr, "viewflow-wayland-toplevel-capture: %s\n", message); }
static char *copy_string(const char *s) {
    if (!s) return strdup("");
    size_t n = strnlen(s, MAX_PROPERTY_BYTES + 1u);
    if (n > MAX_PROPERTY_BYTES) return NULL;
    char *copy = malloc(n + 1u);
    if (copy) { memcpy(copy, s, n); copy[n] = '\0'; }
    return copy;
}
static uint64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}
static int remaining_ms(uint64_t deadline) {
    uint64_t now = monotonic_ms();
    if (now >= deadline) return 0;
    uint64_t remain = deadline - now;
    return remain > INT32_MAX ? INT32_MAX : (int)remain;
}
static int dispatch_until(struct wl_display *display, int *condition, uint64_t deadline) {
    while (!*condition) {
        if (wl_display_dispatch_pending(display) < 0) return -1;
        if (*condition) return 0;
        if (wl_display_prepare_read(display) != 0) continue;
        int flushed = wl_display_flush(display);
        if (flushed < 0 && errno != EAGAIN) { wl_display_cancel_read(display); return -1; }
        struct pollfd pfd = { .fd = wl_display_get_fd(display), .events = POLLIN | (flushed < 0 ? POLLOUT : 0) };
        int result;
        do {
            int wait = remaining_ms(deadline);
            if (wait == 0) { wl_display_cancel_read(display); errno = ETIMEDOUT; return -1; }
            result = poll(&pfd, 1, wait);
        } while (result < 0 && errno == EINTR);
        if (result <= 0) { wl_display_cancel_read(display); if (result == 0) errno = ETIMEDOUT; return -1; }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) { wl_display_cancel_read(display); errno = EPIPE; return -1; }
        if (pfd.revents & POLLIN) {
            if (wl_display_read_events(display) < 0) return -1;
        } else {
            wl_display_cancel_read(display);
        }
    }
    return 0;
}
static void sync_done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)callback; (void)serial; ((struct sync_wait *)data)->done = 1;
}
static const struct wl_callback_listener sync_listener = { .done = sync_done };
static int bounded_sync(struct wl_display *display, uint64_t deadline) {
    struct sync_wait wait = {0};
    struct wl_callback *callback = wl_display_sync(display);
    if (!callback) return -1;
    wl_callback_add_listener(callback, &sync_listener, &wait);
    int result = dispatch_until(display, &wait.done, deadline);
    wl_callback_destroy(callback);
    return result;
}

static void handle_closed(void *data, struct ext_foreign_toplevel_handle_v1 *handle) {
    (void)handle; ((struct toplevel *)data)->closed = 1;
}
static void handle_done(void *data, struct ext_foreign_toplevel_handle_v1 *handle) {
    (void)handle; ((struct toplevel *)data)->ready = 1;
}
static void replace(char **target, const char *value) {
    char *copy = copy_string(value);
    if (!copy) return;
    free(*target); *target = copy;
}
static void handle_title(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *value) {
    (void)handle; replace(&((struct toplevel *)data)->title, value);
}
static void handle_app_id(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *value) {
    (void)handle; replace(&((struct toplevel *)data)->app_id, value);
}
static void handle_identifier(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *value) {
    (void)handle; replace(&((struct toplevel *)data)->identifier, value);
}
static const struct ext_foreign_toplevel_handle_v1_listener handle_listener = {
    .closed = handle_closed, .done = handle_done, .title = handle_title, .app_id = handle_app_id, .identifier = handle_identifier,
};
static struct toplevel *append_toplevel(struct state *state, struct ext_foreign_toplevel_handle_v1 *handle) {
    if (state->top_count == MAX_TOPLEVELS) { state->protocol_error = 1; return NULL; }
    if (state->top_count == state->top_capacity) {
        size_t new_capacity = state->top_capacity ? state->top_capacity * 2 : 16;
        struct toplevel **tops = realloc(state->tops, new_capacity * sizeof(*tops));
        if (!tops) { state->protocol_error = 1; return NULL; }
        state->tops = tops; state->top_capacity = new_capacity;
    }
    struct toplevel *top = calloc(1, sizeof(*top));
    if (!top) { state->protocol_error = 1; return NULL; }
    *top = (struct toplevel){ .handle = handle, .identifier = copy_string(""), .title = copy_string(""), .app_id = copy_string("") };
    if (!top->identifier || !top->title || !top->app_id) { free(top->identifier); free(top->title); free(top->app_id); free(top); state->protocol_error = 1; return NULL; }
    state->tops[state->top_count++] = top;
    return top;
}
static void list_toplevel(void *data, struct ext_foreign_toplevel_list_v1 *list, struct ext_foreign_toplevel_handle_v1 *handle) {
    (void)list;
    struct toplevel *top = append_toplevel(data, handle);
    if (!top) return;
    ext_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, top);
}
static void list_finished(void *data, struct ext_foreign_toplevel_list_v1 *list) { (void)list; ((struct state *)data)->list_finished = 1; }
static const struct ext_foreign_toplevel_list_v1_listener list_listener = { .toplevel = list_toplevel, .finished = list_finished };

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct state *state = data;
    if (strcmp(interface, wl_shm_interface.name) == 0) state->shm = wl_registry_bind(registry, name, &wl_shm_interface, version < 1 ? version : 1);
    else if (strcmp(interface, ext_foreign_toplevel_list_v1_interface.name) == 0) state->list = wl_registry_bind(registry, name, &ext_foreign_toplevel_list_v1_interface, 1);
    else if (strcmp(interface, ext_foreign_toplevel_image_capture_source_manager_v1_interface.name) == 0) state->source_manager = wl_registry_bind(registry, name, &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
    else if (strcmp(interface, ext_image_copy_capture_manager_v1_interface.name) == 0) state->capture_manager = wl_registry_bind(registry, name, &ext_image_copy_capture_manager_v1_interface, 1);
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = { .global = registry_global, .global_remove = registry_remove };

static void constraints_size(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t width, uint32_t height) {
    (void)session; struct constraints *c = data; c->width = width; c->height = height; ++c->generation;
}
static void constraints_format(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format) {
    (void)session; struct constraints *c = data; ++c->generation; if (c->format_count < sizeof(c->formats) / sizeof(c->formats[0])) c->formats[c->format_count++] = format;
}
static void constraints_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *session, struct wl_array *device) { (void)session; (void)device; ++((struct constraints *)data)->generation; }
static void constraints_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format, struct wl_array *modifiers) { (void)session; (void)format; (void)modifiers; ++((struct constraints *)data)->generation; }
static void constraints_done(void *data, struct ext_image_copy_capture_session_v1 *session) { (void)session; struct constraints *c = data; c->done = 1; ++c->generation; }
static void constraints_stopped(void *data, struct ext_image_copy_capture_session_v1 *session) {
    (void)session;
    struct constraints *c = data;
    c->stopped = 1;
    if (c->capture_done) *c->capture_done = 1;
}
static const struct ext_image_copy_capture_session_v1_listener constraints_listener = {
    .buffer_size = constraints_size, .shm_format = constraints_format, .dmabuf_device = constraints_dmabuf_device,
    .dmabuf_format = constraints_dmabuf_format, .done = constraints_done, .stopped = constraints_stopped,
};
static void frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t transform) { (void)frame; struct frame_result *r = data; r->transform = transform; r->saw_transform = 1; }
static void frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *frame, int32_t x, int32_t y, int32_t width, int32_t height) { (void)data; (void)frame; (void)x; (void)y; (void)width; (void)height; }
static void frame_presentation(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t hi, uint32_t lo, uint32_t nsec) {
    (void)frame;
    struct frame_result *r = data;
    r->presentation_hi = hi; r->presentation_lo = lo; r->presentation_nsec = nsec; r->saw_presentation = 1;
}
static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *frame) {
    (void)frame;
    struct frame_result *r = data;
    r->ready = 1; r->done = 1; r->ready_monotonic_ms = monotonic_ms();
}
static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t reason) {
    (void)frame; (void)reason;
    struct frame_result *r = data;
    r->failed = 1; r->done = 1;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .transform = frame_transform, .damage = frame_damage, .presentation_time = frame_presentation, .ready = frame_ready, .failed = frame_failed,
};

static int supported_format(const struct constraints *c, uint32_t *chosen) {
    const uint32_t preference[] = { WL_SHM_FORMAT_ARGB8888, WL_SHM_FORMAT_ABGR8888, WL_SHM_FORMAT_XRGB8888, WL_SHM_FORMAT_XBGR8888 };
    for (size_t p = 0; p < sizeof(preference) / sizeof(preference[0]); ++p)
        for (size_t i = 0; i < c->format_count; ++i)
            if (c->formats[i] == preference[p]) { *chosen = preference[p]; return 0; }
    return -1;
}
static const char *format_name(uint32_t format) {
    switch (format) {
    case WL_SHM_FORMAT_ARGB8888: return "ARGB8888";
    case WL_SHM_FORMAT_XRGB8888: return "XRGB8888";
    case WL_SHM_FORMAT_ABGR8888: return "ABGR8888";
    case WL_SHM_FORMAT_XBGR8888: return "XBGR8888";
    default: return "unknown";
    }
}
static int checked_size(uint32_t width, uint32_t height, size_t max_bytes, size_t *size) {
    if (!width || !height || width > INT32_MAX || height > INT32_MAX) return -1;
    uint64_t value = (uint64_t)width * 4u * (uint64_t)height;
    if (value == 0 || value > max_bytes || value > SIZE_MAX) return -1;
    *size = (size_t)value;
    return 0;
}
static int snapshot_constraints(const struct constraints *constraints, size_t max_bytes, struct capture_spec *spec) {
    if (!constraints->done || constraints->stopped || supported_format(constraints, &spec->format) ||
        checked_size(constraints->width, constraints->height, max_bytes, &spec->size)) return -1;
    spec->width = constraints->width;
    spec->height = constraints->height;
    spec->constraint_generation = constraints->generation;
    return 0;
}
static void put_be32(unsigned char *out, uint32_t value) { out[0] = value >> 24; out[1] = value >> 16; out[2] = value >> 8; out[3] = value; }
static int write_all(int fd, const void *buffer, size_t length) {
    const unsigned char *p = buffer;
    while (length) { ssize_t n = write(fd, p, length); if (n < 0 && errno == EINTR) continue; if (n <= 0) return -1; p += n; length -= (size_t)n; }
    return 0;
}
static int write_vfbg_new(const char *path, const unsigned char *pixels, uint32_t width, uint32_t height, uint32_t format, size_t size) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    unsigned char header[20] = { 'V', 'F', 'B', 'G', 1, 1, 0, 0 };
    put_be32(header + 8, width); put_be32(header + 12, height); put_be32(header + 16, width * 4u);
    unsigned char *converted = NULL;
    if (format != WL_SHM_FORMAT_ARGB8888) {
        converted = malloc(size);
        if (!converted) { close(fd); return -1; }
        for (size_t i = 0; i < size; i += 4) {
            if (format == WL_SHM_FORMAT_XRGB8888) { converted[i] = pixels[i]; converted[i + 1] = pixels[i + 1]; converted[i + 2] = pixels[i + 2]; }
            else { converted[i] = pixels[i + 2]; converted[i + 1] = pixels[i + 1]; converted[i + 2] = pixels[i]; }
            converted[i + 3] = format == WL_SHM_FORMAT_XRGB8888 || format == WL_SHM_FORMAT_XBGR8888 ? 255 : pixels[i + 3];
        }
        pixels = converted;
    }
    int result = 0;
    if (write_all(fd, header, sizeof(header)) || write_all(fd, pixels, size) || fsync(fd)) result = -1;
    if (close(fd)) result = -1;
    free(converted);
    return result;
}
static void json_string(const char *value) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        switch (*p) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\b': fputs("\\b", stdout); break;
        case '\f': fputs("\\f", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*p < 0x20) printf("\\u%04x", *p);
            else putchar(*p);
        }
    }
    putchar('"');
}
static void cleanup(struct state *state) {
    for (size_t i = 0; i < state->top_count; ++i) { struct toplevel *top = state->tops[i]; if (top->handle) ext_foreign_toplevel_handle_v1_destroy(top->handle); free(top->identifier); free(top->title); free(top->app_id); free(top); }
    free(state->tops);
    if (state->list) ext_foreign_toplevel_list_v1_destroy(state->list);
    if (state->source_manager) ext_foreign_toplevel_image_capture_source_manager_v1_destroy(state->source_manager);
    if (state->capture_manager) ext_image_copy_capture_manager_v1_destroy(state->capture_manager);
    if (state->shm) wl_shm_destroy(state->shm);
    if (state->registry) wl_registry_destroy(state->registry);
    if (state->display) wl_display_disconnect(state->display);
}
static int parse_u32(const char *text, uint32_t upper, uint32_t *value) {
    char *end; errno = 0; unsigned long parsed = strtoul(text, &end, 10);
    if (errno || !text[0] || *end || parsed > upper) return -1;
    *value = (uint32_t)parsed;
    return 0;
}
static void usage(FILE *stream) { fprintf(stream, "Usage: viewflow-wayland-toplevel-capture --list [--timeout-ms N]\n       viewflow-wayland-toplevel-capture --identifier ID --output NEW_FILE [--timeout-ms N] [--max-bytes N]\n"); }

#ifndef VIEWFLOW_CAPTURE_TEST
int main(int argc, char **argv) {
    const char *identifier = NULL, *output = NULL;
    int list_only = 0;
    uint32_t timeout_ms = DEFAULT_TIMEOUT_MS, max_bytes = DEFAULT_MAX_BYTES;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--list")) list_only = 1;
        else if (!strcmp(argv[i], "--identifier") && i + 1 < argc) identifier = argv[++i];
        else if (!strcmp(argv[i], "--output") && i + 1 < argc) output = argv[++i];
        else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) { if (parse_u32(argv[++i], MAX_TIMEOUT_MS, &timeout_ms) || !timeout_ms) { usage(stderr); return 2; } }
        else if (!strcmp(argv[i], "--max-bytes") && i + 1 < argc) { if (parse_u32(argv[++i], DEFAULT_MAX_BYTES, &max_bytes) || !max_bytes) { usage(stderr); return 2; } }
        else { usage(stderr); return 2; }
    }
    if ((list_only && (identifier || output)) || (!list_only && (!identifier || !output))) { usage(stderr); return 2; }
    uint64_t deadline = monotonic_ms() + timeout_ms;
    struct state state = {0};
    state.display = wl_display_connect(NULL);
    if (!state.display) { fail("cannot connect to Wayland display"); return 1; }
    state.registry = wl_display_get_registry(state.display);
    wl_registry_add_listener(state.registry, &registry_listener, &state);
    if (bounded_sync(state.display, deadline) || !state.shm || !state.list || !state.source_manager || !state.capture_manager) { fail("required Wayland capture globals are unavailable or timed out"); cleanup(&state); return 1; }
    ext_foreign_toplevel_list_v1_add_listener(state.list, &list_listener, &state);
    if (bounded_sync(state.display, deadline) || state.protocol_error) { fail("toplevel enumeration failed or timed out"); cleanup(&state); return 1; }
    if (list_only) {
        for (size_t i = 0; i < state.top_count; ++i) {
            struct toplevel *candidate = state.tops[i];
            if (candidate->ready && !candidate->closed && candidate->identifier[0]) {
                fputs("{\"identifier\":", stdout); json_string(candidate->identifier);
                fputs(",\"app_id\":", stdout); json_string(candidate->app_id);
                fputs(",\"title\":", stdout); json_string(candidate->title);
                fputs("}\n", stdout);
            }
        }
        cleanup(&state); return 0;
    }
    struct toplevel *top = NULL;
    for (size_t i = 0; i < state.top_count; ++i) { struct toplevel *candidate = state.tops[i]; if (candidate->ready && !candidate->closed && strcmp(candidate->identifier, identifier) == 0) { top = candidate; break; } }
    if (!top) { fail("identifier was not among currently mapped toplevels"); cleanup(&state); return 1; }
    struct ext_image_capture_source_v1 *source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(state.source_manager, top->handle);
    struct ext_image_copy_capture_session_v1 *session = ext_image_copy_capture_manager_v1_create_session(state.capture_manager, source, 0);
    struct constraints constraints = {0};
    ext_image_copy_capture_session_v1_add_listener(session, &constraints_listener, &constraints);
    struct capture_spec spec = {0};
    if (bounded_sync(state.display, deadline) || snapshot_constraints(&constraints, max_bytes, &spec)) { fail("unsupported, stopped, oversized, or unavailable capture constraints"); ext_image_copy_capture_session_v1_destroy(session); ext_image_capture_source_v1_destroy(source); cleanup(&state); return 1; }
    int fd = memfd_create("viewflow-toplevel-frame", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)spec.size)) { fail("cannot allocate bounded shared-memory frame"); if (fd >= 0) close(fd); ext_image_copy_capture_session_v1_destroy(session); ext_image_capture_source_v1_destroy(source); cleanup(&state); return 1; }
    unsigned char *pixels = mmap(NULL, spec.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { fail("cannot map shared-memory frame"); close(fd); ext_image_copy_capture_session_v1_destroy(session); ext_image_capture_source_v1_destroy(source); cleanup(&state); return 1; }
    struct wl_shm_pool *pool = wl_shm_create_pool(state.shm, fd, (int32_t)spec.size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, (int32_t)spec.width, (int32_t)spec.height, (int32_t)(spec.width * 4u), spec.format);
    struct ext_image_copy_capture_frame_v1 *frame = ext_image_copy_capture_session_v1_create_frame(session);
    struct frame_result result = {0};
    constraints.capture_done = &result.done;
    ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener, &result);
    ext_image_copy_capture_frame_v1_attach_buffer(frame, buffer);
    ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, (int32_t)spec.width, (int32_t)spec.height);
    ext_image_copy_capture_frame_v1_capture(frame);
    int dispatch_status = dispatch_until(state.display, &result.done, deadline);
    int ok = result.ready && !result.failed && !constraints.stopped && constraints.generation == spec.constraint_generation && result.saw_transform && result.transform == WL_OUTPUT_TRANSFORM_NORMAL;
    if (!ok) fail(dispatch_status && errno == ETIMEDOUT ? "capture timed out" : constraints.generation != spec.constraint_generation ? "capture constraints changed during frame" : result.ready && result.saw_transform ? "capture failed or session stopped" : "capture failed or compositor returned an unsupported transform");
    else if (write_vfbg_new(output, pixels, spec.width, spec.height, spec.format, spec.size)) { perror("viewflow-wayland-toplevel-capture: writing output"); ok = 0; }
    else {
        printf("captured\tidentifier=%s\tformat=%s\twidth=%u\theight=%u\tstride=%u\tready_monotonic_ms=%llu",
               identifier, format_name(spec.format), spec.width, spec.height, spec.width * 4u,
               (unsigned long long)result.ready_monotonic_ms);
        if (result.saw_presentation)
            printf("\tpresentation_time=%u:%u.%09u", result.presentation_hi, result.presentation_lo, result.presentation_nsec);
        printf("\n");
    }
    ext_image_copy_capture_frame_v1_destroy(frame); wl_buffer_destroy(buffer); wl_shm_pool_destroy(pool); munmap(pixels, spec.size); close(fd);
    ext_image_copy_capture_session_v1_destroy(session); ext_image_capture_source_v1_destroy(source); cleanup(&state);
    return ok ? 0 : 1;
}
#endif
