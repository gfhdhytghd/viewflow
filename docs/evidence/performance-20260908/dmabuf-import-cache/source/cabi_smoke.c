#include "nvenc_encoder_cabi.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  const uint32_t width = 1556;
  const uint32_t height = 1300;
  vf_nvenc_encoder_config config = {
      .struct_size = sizeof(config),
      .version = VF_NVENC_CABI_VERSION,
      .width = width,
      .height = height,
      .max_access_unit_bytes = 32U * 1024U * 1024U,
      .max_pending_frames = 2,
      .alpha_policy = VF_NVENC_ALPHA_REQUIRED,
      .alpha_fidelity = VF_NVENC_ALPHA_LOSSLESS,
  };
  vf_nvenc_encoder* encoder = NULL;
  if (vf_nvenc_encoder_create(&config, &encoder) != VF_NVENC_OK) return 1;
  const size_t bytes = (size_t)width * height * 4;
  uint8_t* rgba = calloc(bytes, 1);
  if (rgba == NULL) return 1;
  for (size_t pixel = 0; pixel < bytes / 4; ++pixel) rgba[pixel * 4 + 3] = (uint8_t)pixel;
  vf_nvenc_output_list output;
  vf_nvenc_output_list_init(&output);
  const vf_nvenc_status status = vf_nvenc_encoder_submit(
      encoder, rgba, bytes, (vf_nvenc_frame_metadata){7, 123456789, 3}, 1, &output);
  if (status != VF_NVENC_OK || output.count != 1) return 1;
  vf_nvenc_output_au* au = NULL;
  if (vf_nvenc_output_list_take(&output, 0, &au) != VF_NVENC_OK) return 1;
  vf_nvenc_output_info info;
  if (vf_nvenc_output_au_get_info(au, &info) != VF_NVENC_OK || info.metadata.frame_id != 7 ||
      !info.has_alpha_stream || !info.color_is_idr || !info.alpha_is_idr) {
    return 1;
  }
  printf("C ABI paired NVENC smoke passed: color=%zu alpha=%zu\n", info.color_annex_b_bytes,
         info.alpha_annex_b_bytes);
  vf_nvenc_output_au_destroy(au);
  vf_nvenc_output_list_destroy(&output);
  vf_nvenc_encoder_destroy(encoder);
  free(rgba);
  return 0;
}
