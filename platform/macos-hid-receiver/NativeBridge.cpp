#include "NativeBridge.h"
#include "../macos-trackpad-probe/native_protocol.h"
#include "../macos-trackpad-probe/native_descriptor.h"

extern "C" {
void *vf_state_create() { auto *s = new vf_native::State; s->init(); return s; }
void vf_state_destroy(void *state) { delete static_cast<vf_native::State *>(state); }
int32_t vf_state_apply(void *state, const uint8_t *bytes, size_t size, VFSubmit submit, void *context) {
    return static_cast<vf_native::State *>(state)->apply(bytes, size,
        [=](const uint8_t *p, size_t n) { return submit(context, p, n); });
}
int32_t vf_state_release(void *state, VFSubmit submit, void *context) {
    return static_cast<vf_native::State *>(state)->release(
        [=](const uint8_t *p, size_t n) { return submit(context, p, n); });
}
void *vf_features_create() { return new vf_native::Features; }
void vf_features_destroy(void *features) { delete static_cast<vf_native::Features *>(features); }
size_t vf_features_get(void *features, uint8_t id, uint8_t *output) {
    return static_cast<vf_native::Features *>(features)->get(id, output);
}
int vf_features_set(void *features, uint8_t id, const uint8_t *bytes, size_t size) {
    return static_cast<vf_native::Features *>(features)->set(id, bytes, size);
}
const uint8_t *vf_descriptor(size_t *size) { *size = sizeof(vf_native_descriptor); return vf_native_descriptor; }
}
