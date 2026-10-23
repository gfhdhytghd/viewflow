#ifndef VIEWFLOW_NVENC_ENCODER_CABI_H
#define VIEWFLOW_NVENC_ENCODER_CABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VF_NVENC_CABI_VERSION 1U

typedef enum vf_nvenc_status {
  VF_NVENC_OK = 0,
  VF_NVENC_INVALID_ARGUMENT = 1,
  VF_NVENC_UNSUPPORTED_VERSION = 2,
  VF_NVENC_INVALID_CONFIG = 3,
  VF_NVENC_ENCODER_FAILED = 4,
  VF_NVENC_ALLOCATION_FAILED = 5,
  VF_NVENC_BUFFER_TOO_SMALL = 6,
  VF_NVENC_INDEX_OUT_OF_RANGE = 7,
  VF_NVENC_INTERNAL_ERROR = 8,
} vf_nvenc_status;

typedef enum vf_nvenc_alpha_policy {
  VF_NVENC_ALPHA_REQUIRED = 0,
  VF_NVENC_ALPHA_OPAQUE_MAY_OMIT = 1,
  VF_NVENC_ALPHA_COLOR_ONLY_EXTERNAL = 2,
} vf_nvenc_alpha_policy;

typedef enum vf_nvenc_alpha_fidelity {
  VF_NVENC_ALPHA_LOSSLESS = 0,
  VF_NVENC_ALPHA_BOUNDED_LOSSY = 1,
} vf_nvenc_alpha_fidelity;

typedef enum vf_nvenc_alpha_disposition {
  VF_NVENC_ALPHA_ENCODED_FULL_RANGE = 0,
  VF_NVENC_ALPHA_OPAQUE_OMITTED = 1,
  VF_NVENC_ALPHA_EXTERNAL = 2,
} vf_nvenc_alpha_disposition;

typedef enum vf_nvenc_h264_profile {
  VF_NVENC_H264_HIGH_8 = 0,
  VF_NVENC_H264_HIGH_444_PREDICTIVE_8 = 1,
} vf_nvenc_h264_profile;

typedef struct vf_nvenc_encoder_config {
  uint32_t struct_size;
  uint32_t version;
  uint32_t width;
  uint32_t height;
  size_t max_access_unit_bytes;
  size_t max_pending_frames;
  uint32_t alpha_policy;
  uint32_t alpha_fidelity;
  uint8_t alpha_max_quantizer;
  uint8_t reserved[7];
} vf_nvenc_encoder_config;

typedef struct vf_nvenc_frame_metadata {
  uint64_t frame_id;
  uint64_t timestamp_ns;
  uint64_t geometry_epoch;
} vf_nvenc_frame_metadata;

typedef struct vf_nvenc_stream_descriptor {
  uint32_t profile;
  uint8_t full_range;
  uint8_t luma_is_straight_alpha;
  uint8_t chroma_is_neutral;
  uint8_t reserved;
} vf_nvenc_stream_descriptor;

typedef struct vf_nvenc_output_info {
  uint32_t struct_size;
  uint32_t version;
  vf_nvenc_frame_metadata metadata;
  uint32_t alpha_disposition;
  uint8_t color_is_idr;
  uint8_t alpha_is_idr;
  uint8_t has_alpha_stream;
  uint8_t reserved[5];
  vf_nvenc_stream_descriptor color_stream;
  vf_nvenc_stream_descriptor alpha_stream;
  size_t color_annex_b_bytes;
  size_t alpha_annex_b_bytes;
} vf_nvenc_output_info;

typedef struct vf_nvenc_encoder vf_nvenc_encoder;
typedef struct vf_nvenc_output_au vf_nvenc_output_au;

typedef struct vf_nvenc_output_list {
  uint32_t struct_size;
  uint32_t version;
  vf_nvenc_output_au** items;
  size_t count;
} vf_nvenc_output_list;

// Initializes an empty list. It must be initialized before submit/drain and
// destroyed before reuse when it owns output AUs.
void vf_nvenc_output_list_init(vf_nvenc_output_list* list);
vf_nvenc_status vf_nvenc_output_list_destroy(vf_nvenc_output_list* list);
vf_nvenc_status vf_nvenc_output_list_take(vf_nvenc_output_list* list, size_t index,
                                           vf_nvenc_output_au** output);
void vf_nvenc_output_au_destroy(vf_nvenc_output_au* output);

vf_nvenc_status vf_nvenc_encoder_create(const vf_nvenc_encoder_config* config,
                                         vf_nvenc_encoder** output);
void vf_nvenc_encoder_destroy(vf_nvenc_encoder* encoder);

// RGBA is borrowed only for this synchronous call. The byte count must equal
// width*height*4 and output must be an initialized, empty output list.
vf_nvenc_status vf_nvenc_encoder_submit(vf_nvenc_encoder* encoder, const uint8_t* straight_rgba,
                                         size_t straight_rgba_bytes,
                                         vf_nvenc_frame_metadata metadata, uint8_t force_idr,
                                         vf_nvenc_output_list* output);
vf_nvenc_status vf_nvenc_encoder_drain(vf_nvenc_encoder* encoder,
                                        vf_nvenc_output_list* output);

// Reads metadata and descriptors without transferring AU ownership.
vf_nvenc_status vf_nvenc_output_au_get_info(const vf_nvenc_output_au* output,
                                             vf_nvenc_output_info* info);
// Copies one encoded plane. Pass destination=NULL and capacity=0 to query the
// required size; this returns BUFFER_TOO_SMALL for a nonempty plane. Otherwise
// a too-small destination also returns BUFFER_TOO_SMALL.
vf_nvenc_status vf_nvenc_output_au_copy_color(const vf_nvenc_output_au* output,
                                               uint8_t* destination, size_t capacity,
                                               size_t* required);
vf_nvenc_status vf_nvenc_output_au_copy_alpha(const vf_nvenc_output_au* output,
                                               uint8_t* destination, size_t capacity,
                                               size_t* required);

// Copies a stable diagnostic message for the last failed encoder call.
vf_nvenc_status vf_nvenc_encoder_copy_last_error(const vf_nvenc_encoder* encoder,
                                                  char* destination, size_t capacity,
                                                  size_t* required);

#ifdef __cplusplus
}
#endif

#endif
