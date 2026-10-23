#ifndef VIEWFLOW_GPU_DMABUF_ENCODER_CABI_H
#define VIEWFLOW_GPU_DMABUF_ENCODER_CABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VF_GPU_DMABUF_ENCODER_CABI_VERSION 1U
#define VF_GPU_DMABUF_ENCODER_ERROR_CAPACITY 256U

typedef enum vf_gpu_dmabuf_status {
  VF_GPU_DMABUF_OK = 0,
  VF_GPU_DMABUF_INVALID_ARGUMENT = 1,
  VF_GPU_DMABUF_INVALID_CONFIG = 2,
  VF_GPU_DMABUF_ENCODER_FAILED = 3,
  VF_GPU_DMABUF_ALLOCATION_FAILED = 4,
  VF_GPU_DMABUF_BUFFER_TOO_SMALL = 5,
  VF_GPU_DMABUF_WRONG_THREAD = 6,
  VF_GPU_DMABUF_INTERNAL_ERROR = 7,
  VF_GPU_DMABUF_EXPIRED_CLEAN = 8,
  VF_GPU_DMABUF_EXPIRED_AFTER_SUBMISSION = 9,
  VF_GPU_DMABUF_NEEDS_CANVAS = 10,
} vf_gpu_dmabuf_status;

typedef struct vf_gpu_dmabuf_encoder_config {
  uint32_t width;
  uint32_t height;
  uint64_t max_access_unit_bytes;
} vf_gpu_dmabuf_encoder_config;

// Both file descriptors are borrowed for vf_gpu_dmabuf_encoder_encode only.
// deadline_monotonic_ns is an absolute CLOCK_MONOTONIC deadline.
typedef struct vf_gpu_dmabuf_frame {
  int32_t dma_buf_fd;
  int32_t native_fence_fd;
  uint32_t image_width;
  uint32_t image_height;
  uint32_t stride;
  uint32_t offset;
  uint32_t fourcc;
  uint64_t modifier;
  int32_t crop_x;
  int32_t crop_y;
  int32_t crop_width;
  int32_t crop_height;
  uint32_t flip_y;
  uint64_t frame_id;
  uint64_t capture_timestamp_ns;
  uint64_t geometry_epoch;
  uint32_t shadow_enabled;
  double shadow_left;
  double shadow_top;
  double shadow_width;
  double shadow_height;
  double shadow_cutout_left;
  double shadow_cutout_top;
  double shadow_cutout_width;
  double shadow_cutout_height;
  double shadow_range;
  double shadow_rounding;
  double shadow_window_rounding;
  double shadow_rounding_power;
  uint32_t shadow_power;
  uint8_t shadow_red;
  uint8_t shadow_green;
  uint8_t shadow_blue;
  uint8_t shadow_alpha;
  uint32_t shadow_sharp;
} vf_gpu_dmabuf_frame;

#define VF_GPU_DMABUF_ATLAS_VERSION 1U
typedef struct vf_gpu_dmabuf_atlas_tile {
  vf_gpu_dmabuf_frame frame;
  int32_t x, y;
  int64_t deadline_monotonic_ns;
} vf_gpu_dmabuf_atlas_tile;

typedef struct vf_gpu_dmabuf_atlas {
  uint32_t struct_size;
  uint32_t version;
  uint32_t tile_count;
  uint32_t reserved; // must be zero
  const vf_gpu_dmabuf_atlas_tile* tiles;
  uint64_t frame_id;
  uint64_t capture_timestamp_ns;
  uint64_t geometry_epoch;
} vf_gpu_dmabuf_atlas;

typedef struct vf_gpu_dmabuf_sparse_source {
  int64_t x, y;
  uint32_t z, grid;
  uint32_t clip_enabled, clip_x, clip_y, clip_width, clip_height;
} vf_gpu_dmabuf_sparse_source;
typedef struct vf_gpu_dmabuf_sparse_scene {
  uint32_t mode; // 1: opaque culling, 2: transparent precomposition
  uint32_t max_width, max_height, source_count;
  const vf_gpu_dmabuf_sparse_source* sources;
} vf_gpu_dmabuf_sparse_scene;
typedef struct vf_gpu_dmabuf_sparse_patch {
  uint32_t source, source_x, source_y, x, y, width, height;
} vf_gpu_dmabuf_sparse_patch;
typedef struct vf_gpu_dmabuf_sparse_info {
  uint32_t enabled, patch_count, required_width, required_height;
  uint64_t input_pixels, stored_pixels, occluded_pixels, empty_pixels, omitted_pixels;
} vf_gpu_dmabuf_sparse_info;

typedef struct vf_gpu_dmabuf_output_info {
  uint64_t frame_id;
  uint64_t capture_timestamp_ns;
  uint64_t geometry_epoch;
  uint32_t idr;
  uint64_t color_annex_b_bytes;
  uint64_t raw_alpha_bytes;
} vf_gpu_dmabuf_output_info;

typedef struct vf_gpu_dmabuf_encoder vf_gpu_dmabuf_encoder;
typedef struct vf_gpu_dmabuf_output vf_gpu_dmabuf_output;

// Creation, encode, every output operation, and destruction must occur on the
// creating worker thread. No function throws across this ABI.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_create_with_codec(
    const vf_gpu_dmabuf_encoder_config* config, uint32_t codec, vf_gpu_dmabuf_encoder** output);

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_create(
    const vf_gpu_dmabuf_encoder_config* config, vf_gpu_dmabuf_encoder** output);
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_destroy(vf_gpu_dmabuf_encoder* encoder);

// On every non-OK result, *output is set to NULL. force_idr must be 0 or 1.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_frame* frame,
    uint32_t force_idr, int64_t deadline_monotonic_ns,
    vf_gpu_dmabuf_output** output);

// Opt-in extension. EXPIRED_CLEAN returns NULL output and keeps the encoder
// usable: all source GPU reads and import cleanup completed, and this frame
// was never submitted to NVENC. The caller may release this exact capture
// lease and submit a later frame without changing the decoder reference chain.
// EXPIRED_AFTER_SUBMISSION also proves cleanup, but NVENC consumed this frame:
// its matching packet was drained and discarded. The encoder forces the next
// frame to IDR; callers must also reset their alpha/reference cache.
// Every other error retains the legacy terminal-failure behavior. Early
// admission expiry is NOT EXPIRED_CLEAN. Never retry the same expired frame.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_frame* frame,
    uint32_t force_idr, int64_t deadline_monotonic_ns,
    vf_gpu_dmabuf_output** output);

// Additive atlas extension, with the same recoverable-expiry/terminal-failure
// semantics. All descriptors and each tile's capture lease are borrowed through
// return. The effective deadline is the earliest batch/tile deadline. At most
// 4096 tiles; zero tiles clears the atlas. Output identity is the atlas identity;
// this ABI does not transport the layout-to-window mapping or authorize input.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_atlas_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_atlas* atlas,
    uint32_t force_idr, int64_t deadline_monotonic_ns,
    vf_gpu_dmabuf_output** output);

// NEEDS_CANVAS returns an owned output with only sparse_info, after all source
// reads have completed. Release leases before reallocating the encoder.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_sparse_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_atlas* atlas,
    const vf_gpu_dmabuf_sparse_scene* scene, uint32_t force_idr,
    int64_t deadline_monotonic_ns, vf_gpu_dmabuf_output** output);
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_get_sparse_info(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_sparse_info* info);
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_sparse_patches(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_sparse_patch* destination,
    size_t capacity, size_t* required);

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_get_info(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_output_info* info);
// Pass destination=NULL and capacity=0 to obtain *required. A nonempty plane
// then returns VF_GPU_DMABUF_BUFFER_TOO_SMALL.
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_color(
    const vf_gpu_dmabuf_output* output, uint8_t* destination, size_t capacity,
    size_t* required);
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_raw_alpha(
    const vf_gpu_dmabuf_output* output, uint8_t* destination, size_t capacity,
    size_t* required);
// Immutable, output-owned storage. The view remains valid until output_destroy,
// including across later encodes and encoder destruction. Access and destruction
// remain on the output's owner thread. The caller must not mutate this storage.
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_view_raw_alpha(
    const vf_gpu_dmabuf_output* output, const uint8_t** data, size_t* length);
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_destroy(vf_gpu_dmabuf_output* output);

// Copies the bounded, NUL-terminated diagnostic from the last failed encoder
// operation. The diagnostic, including its terminator, never exceeds
// VF_GPU_DMABUF_ENCODER_ERROR_CAPACITY bytes.
vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_copy_last_error(
    const vf_gpu_dmabuf_encoder* encoder, char* destination, size_t capacity,
    size_t* required);

#ifdef __cplusplus
}
#endif

#endif
