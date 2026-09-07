#include "gpu_dmabuf_encoder_cabi.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

_Static_assert(sizeof(vf_gpu_dmabuf_encoder_config) == 16, "Rust config ABI");
_Static_assert(sizeof(vf_gpu_dmabuf_frame) == 208, "Rust frame ABI");
_Static_assert(offsetof(vf_gpu_dmabuf_frame, modifier) == 32, "Rust modifier ABI");
_Static_assert(offsetof(vf_gpu_dmabuf_frame, frame_id) == 64, "Rust frame id ABI");
_Static_assert(offsetof(vf_gpu_dmabuf_frame, shadow_left) == 96, "Rust shadow ABI");
_Static_assert(sizeof(vf_gpu_dmabuf_output_info) == 48, "Rust output info ABI");
_Static_assert(sizeof(vf_gpu_dmabuf_atlas_tile) == 224, "Rust atlas tile ABI");
_Static_assert(offsetof(vf_gpu_dmabuf_atlas_tile, deadline_monotonic_ns) == 216, "Rust atlas deadline ABI");
_Static_assert(sizeof(vf_gpu_dmabuf_atlas) == 48, "Rust atlas ABI");
_Static_assert(offsetof(vf_gpu_dmabuf_atlas, tiles) == 16, "Rust atlas pointer ABI");

// This test intentionally needs no GPU: it proves C compilation plus the ABI's
// pre-admission failure rules. The integration fixture can use this same header
// for a real exported DMA-BUF/fence encode when wired into CMake.
int main(void) {
  vf_gpu_dmabuf_encoder* encoder = (vf_gpu_dmabuf_encoder*)(uintptr_t)1;
  assert(vf_gpu_dmabuf_encoder_create(0, &encoder) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  assert(encoder == 0);

  vf_gpu_dmabuf_encoder_config bad = {0, 2, 1};
  assert(vf_gpu_dmabuf_encoder_create(&bad, &encoder) == VF_GPU_DMABUF_INVALID_CONFIG);
  assert(encoder == 0);

  vf_gpu_dmabuf_output* output = (vf_gpu_dmabuf_output*)(uintptr_t)1;
  assert(vf_gpu_dmabuf_encoder_encode(0, 0, 0, 0, &output) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  assert(output == 0);
  output = (vf_gpu_dmabuf_output*)(uintptr_t)1;
  assert(vf_gpu_dmabuf_encoder_encode_recoverable(0, 0, 0, 0, &output) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  assert(output == 0);
  assert(vf_gpu_dmabuf_encoder_encode_recoverable(0, 0, 0, 0, 0) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  assert(vf_gpu_dmabuf_output_get_info(0, 0) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  output = (vf_gpu_dmabuf_output*)(uintptr_t)1;
  assert(vf_gpu_dmabuf_encoder_encode_atlas_recoverable(0, 0, 0, 0, &output) == VF_GPU_DMABUF_INVALID_ARGUMENT);
  assert(output == 0);
  return 0;
}
