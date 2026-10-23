#include "nvenc_encoder_cabi.h"

#include <assert.h>
#include <stddef.h>

int main(void) {
  vf_nvenc_output_list list;
  vf_nvenc_output_list_init(&list);
  assert(list.struct_size == sizeof(list));
  assert(list.version == VF_NVENC_CABI_VERSION);
  assert(vf_nvenc_output_list_destroy(NULL) == VF_NVENC_INVALID_ARGUMENT);
  assert(vf_nvenc_encoder_create(NULL, NULL) == VF_NVENC_INVALID_ARGUMENT);

  vf_nvenc_encoder* encoder = NULL;
  vf_nvenc_encoder_config invalid = {
      .struct_size = sizeof(invalid),
      .version = VF_NVENC_CABI_VERSION,
      .width = 0,
      .height = 1,
      .max_access_unit_bytes = 1024,
      .max_pending_frames = 1,
      .alpha_policy = VF_NVENC_ALPHA_REQUIRED,
      .alpha_fidelity = VF_NVENC_ALPHA_LOSSLESS,
  };
  assert(vf_nvenc_encoder_create(&invalid, &encoder) == VF_NVENC_INVALID_CONFIG);
  invalid.width = 2;
  invalid.height = 2;
  invalid.alpha_policy = VF_NVENC_ALPHA_COLOR_ONLY_EXTERNAL + 1U;
  assert(vf_nvenc_encoder_create(&invalid, &encoder) == VF_NVENC_INVALID_CONFIG);
  invalid.width = 1;
  invalid.alpha_policy = VF_NVENC_ALPHA_REQUIRED;
  invalid.version++;
  assert(vf_nvenc_encoder_create(&invalid, &encoder) == VF_NVENC_UNSUPPORTED_VERSION);
  assert(vf_nvenc_output_list_take(&list, 0, NULL) == VF_NVENC_INVALID_ARGUMENT);
  assert(vf_nvenc_output_list_destroy(&list) == VF_NVENC_OK);
  return 0;
}
