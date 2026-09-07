#define VIEWFLOW_CAPTURE_TEST
#include "toplevel_capture.c"

#include <assert.h>

static void test_format_preference(void) {
    struct constraints c = { .formats = { WL_SHM_FORMAT_XRGB8888, WL_SHM_FORMAT_ABGR8888 }, .format_count = 2 };
    uint32_t selected = 0;
    assert(supported_format(&c, &selected) == 0);
    assert(selected == WL_SHM_FORMAT_ABGR8888);
    c.formats[0] = WL_SHM_FORMAT_RGB565;
    c.formats[1] = WL_SHM_FORMAT_RGB565;
    assert(supported_format(&c, &selected) == -1);
}

static void test_checked_size(void) {
    size_t size = 0;
    assert(checked_size(2, 3, 24, &size) == 0 && size == 24);
    assert(checked_size(0, 3, 24, &size) == -1);
    assert(checked_size(UINT32_MAX, UINT32_MAX, SIZE_MAX, &size) == -1);
}

static void test_constraint_snapshot(void) {
    struct constraints c = { .width = 2, .height = 3, .formats = { WL_SHM_FORMAT_ARGB8888 }, .format_count = 1, .done = 1, .generation = 7 };
    struct capture_spec spec = {0};
    assert(snapshot_constraints(&c, 24, &spec) == 0);
    assert(spec.width == 2 && spec.height == 3 && spec.size == 24 && spec.constraint_generation == 7);
    c.generation++;
    assert(c.generation != spec.constraint_generation);
}

static void test_stable_toplevel_storage(void) {
    struct state state = {0};
    struct toplevel *first[17];
    for (size_t i = 0; i < 17; ++i) {
        first[i] = append_toplevel(&state, NULL);
        assert(first[i] != NULL);
    }
    for (size_t i = 17; i < 40; ++i) assert(append_toplevel(&state, NULL) != NULL);
    for (size_t i = 0; i < 17; ++i) assert(state.tops[i] == first[i]);
    cleanup(&state);
}

static void test_conversion_and_no_clobber(void) {
    char path[] = "/tmp/viewflow-vfbg-test-XXXXXX";
    int temporary = mkstemp(path);
    assert(temporary >= 0);
    assert(close(temporary) == 0);
    assert(unlink(path) == 0); /* reserves no name; writer itself must create it exclusively */
    const unsigned char xrgb[] = { 1, 2, 3, 0, 9, 8, 7, 0 };
    assert(write_vfbg_new(path, xrgb, 2, 1, WL_SHM_FORMAT_XRGB8888, sizeof(xrgb)) == 0);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    unsigned char wire[28];
    assert(read(fd, wire, sizeof(wire)) == (ssize_t)sizeof(wire));
    assert(close(fd) == 0);
    assert(memcmp(wire, "VFBG\1\1\0\0", 8) == 0);
    assert(wire[11] == 2 && wire[15] == 1 && wire[19] == 8);
    const unsigned char expected[] = { 1, 2, 3, 255, 9, 8, 7, 255 };
    assert(memcmp(wire + 20, expected, sizeof(expected)) == 0);
    errno = 0;
    assert(write_vfbg_new(path, xrgb, 2, 1, WL_SHM_FORMAT_XRGB8888, sizeof(xrgb)) == -1);
    assert(errno == EEXIST);
    assert(unlink(path) == 0);
}

int main(void) {
    test_format_preference();
    test_checked_size();
    test_constraint_snapshot();
    test_stable_toplevel_storage();
    test_conversion_and_no_clobber();
    return 0;
}
