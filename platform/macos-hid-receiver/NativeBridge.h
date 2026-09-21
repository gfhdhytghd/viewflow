#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int32_t (*VFSubmit)(void *, const uint8_t *, size_t);
void *vf_state_create(void);
void vf_state_destroy(void *state);
int32_t vf_state_apply(void *state, const uint8_t *bytes, size_t size, VFSubmit submit, void *context);
int32_t vf_state_release(void *state, VFSubmit submit, void *context);
void *vf_features_create(void);
void vf_features_destroy(void *features);
size_t vf_features_get(void *features, uint8_t id, uint8_t *output);
int vf_features_set(void *features, uint8_t id, const uint8_t *bytes, size_t size);
const uint8_t *vf_descriptor(size_t *size);
#ifdef __cplusplus
}
#endif
