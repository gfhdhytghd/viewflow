#include "gpu_dmabuf_encoder_cabi.h"
#include "alpha_copy_profile.hpp"

#include "gpu_dmabuf_encoder.cuh"

#include <cstdio>
#include <cstring>
#include <exception>
#include <climits>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <thread>
#include <utility>

using viewflow::gpu::DmabufFrame;
using viewflow::gpu::EncodedDmabufFrame;
using viewflow::gpu::FrameMetadata;
using viewflow::gpu::GpuDmabufEncoder;
using viewflow::gpu::GpuDmabufEncoderConfig;
using viewflow::gpu::ShadowSnapshot;

struct vf_gpu_dmabuf_encoder {
  std::unique_ptr<GpuDmabufEncoder> value;
  std::thread::id owner;
  std::string last_error;
  bool terminal_failed = false;
};

struct vf_gpu_dmabuf_output {
  EncodedDmabufFrame value;
  std::thread::id owner;
};

namespace {

constexpr size_t kMaxErrorBytes = VF_GPU_DMABUF_ENCODER_ERROR_CAPACITY - 1U;

template <typename Function>
vf_gpu_dmabuf_status no_throw(Function&& function) noexcept {
  try {
    return function();
  } catch (const std::bad_alloc&) {
    return VF_GPU_DMABUF_ALLOCATION_FAILED;
  } catch (...) {
    return VF_GPU_DMABUF_INTERNAL_ERROR;
  }
}

void set_error(vf_gpu_dmabuf_encoder* encoder, const std::string& error) noexcept {
  if (encoder == nullptr) return;
  try {
    encoder->last_error.assign(error.data(), error.size() < kMaxErrorBytes ? error.size() : kMaxErrorBytes);
  } catch (...) {
    // A diagnostic failure must never turn an ABI error path into an exception.
    encoder->last_error.clear();
  }
}

vf_gpu_dmabuf_status require_owner(const vf_gpu_dmabuf_encoder* encoder) {
  if (encoder == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
  return encoder->owner == std::this_thread::get_id() ? VF_GPU_DMABUF_OK
                                                        : VF_GPU_DMABUF_WRONG_THREAD;
}

vf_gpu_dmabuf_status require_owner(const vf_gpu_dmabuf_output* output) {
  if (output == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
  return output->owner == std::this_thread::get_id() ? VF_GPU_DMABUF_OK
                                                       : VF_GPU_DMABUF_WRONG_THREAD;
}

vf_gpu_dmabuf_status copy_plane(const std::vector<unsigned char>& source,
                                 uint8_t* destination, size_t capacity,
                                 size_t* required) {
  if (required == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
  *required = source.size();
  if (capacity < source.size()) return VF_GPU_DMABUF_BUFFER_TOO_SMALL;
  if (!source.empty() && destination == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
  if (!source.empty()) std::memcpy(destination, source.data(), source.size());
  return VF_GPU_DMABUF_OK;
}

vf_gpu_dmabuf_status map_config(const vf_gpu_dmabuf_encoder_config* source,
                                GpuDmabufEncoderConfig* destination) {
  if (source == nullptr || destination == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
  if (source->width < 2 || source->height < 2 || (source->width & 1U) != 0 ||
      (source->height & 1U) != 0 ||
      source->width > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      source->height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      source->max_access_unit_bytes == 0 ||
      source->max_access_unit_bytes > std::numeric_limits<size_t>::max()) {
    return VF_GPU_DMABUF_INVALID_CONFIG;
  }
  *destination = GpuDmabufEncoderConfig{static_cast<int>(source->width),
                                        static_cast<int>(source->height),
                                        static_cast<size_t>(source->max_access_unit_bytes)};
  return VF_GPU_DMABUF_OK;
}

bool shadow_is_zero(const vf_gpu_dmabuf_frame& source) {
  return source.shadow_left == 0.0 && source.shadow_top == 0.0 &&
         source.shadow_width == 0.0 && source.shadow_height == 0.0 &&
         source.shadow_cutout_left == 0.0 && source.shadow_cutout_top == 0.0 &&
         source.shadow_cutout_width == 0.0 && source.shadow_cutout_height == 0.0 &&
         source.shadow_range == 0.0 && source.shadow_rounding == 0.0 &&
         source.shadow_window_rounding == 0.0 && source.shadow_rounding_power == 0.0 &&
         source.shadow_power == 0 && source.shadow_red == 0 && source.shadow_green == 0 &&
         source.shadow_blue == 0 && source.shadow_alpha == 0 && source.shadow_sharp == 0;
}

bool valid_frame_flags(const vf_gpu_dmabuf_frame& source) {
  if (source.flip_y > 1 || source.shadow_enabled > 1 || source.shadow_sharp > 1)
    return false;
  if (source.shadow_enabled == 0) return shadow_is_zero(source);
  return source.shadow_power <= static_cast<uint32_t>(INT_MAX);
}

DmabufFrame map_frame(const vf_gpu_dmabuf_frame& source) {
  DmabufFrame destination{};
  destination.dmaBufFd = source.dma_buf_fd;
  destination.nativeFenceFd = source.native_fence_fd;
  destination.imageWidth = source.image_width;
  destination.imageHeight = source.image_height;
  destination.stride = source.stride;
  destination.offset = source.offset;
  destination.fourcc = source.fourcc;
  destination.modifier = source.modifier;
  destination.cropX = source.crop_x;
  destination.cropY = source.crop_y;
  destination.cropWidth = source.crop_width;
  destination.cropHeight = source.crop_height;
  destination.flipVertical = source.flip_y != 0;
  destination.metadata = FrameMetadata{source.frame_id, source.capture_timestamp_ns,
                                        source.geometry_epoch};
  if (source.shadow_enabled != 0) {
    destination.shadow = ShadowSnapshot{
        source.shadow_left, source.shadow_top, source.shadow_width, source.shadow_height,
        source.shadow_cutout_left, source.shadow_cutout_top, source.shadow_cutout_width,
        source.shadow_cutout_height, source.shadow_range, source.shadow_rounding,
        source.shadow_window_rounding, source.shadow_rounding_power,
        static_cast<int>(source.shadow_power), source.shadow_red, source.shadow_green,
        source.shadow_blue, source.shadow_alpha, source.shadow_sharp != 0};
  }
  return destination;
}

}  // namespace

extern "C" {

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_create(
    const vf_gpu_dmabuf_encoder_config* config, vf_gpu_dmabuf_encoder** output) {
  return vf_gpu_dmabuf_encoder_create_with_codec(config, 2, output);
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_create_with_codec(
    const vf_gpu_dmabuf_encoder_config* config, uint32_t codec, vf_gpu_dmabuf_encoder** output) {
  return no_throw([&] {
    if (output == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    *output = nullptr;
    if (codec != 2 && codec != 4) return VF_GPU_DMABUF_INVALID_CONFIG;
    GpuDmabufEncoderConfig native{};
    const auto status = map_config(config, &native);
    if (status != VF_GPU_DMABUF_OK) return status;
    native.colorCodec = codec;
    std::string error;
    auto created = std::make_unique<GpuDmabufEncoder>(native, &error);
    if (!created->ready()) {
      std::fprintf(stderr, "GPU encoder initialization failed: %s\n", error.c_str());
      return VF_GPU_DMABUF_ENCODER_FAILED;
    }
    *output = new vf_gpu_dmabuf_encoder{std::move(created), std::this_thread::get_id(), {}};
    return VF_GPU_DMABUF_OK;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_destroy(vf_gpu_dmabuf_encoder* encoder) {
  return no_throw([&] {
    const auto status = require_owner(encoder);
    if (status != VF_GPU_DMABUF_OK) return status;
    delete encoder;
    return VF_GPU_DMABUF_OK;
  });
}

static vf_gpu_dmabuf_status encode_impl(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_frame* frame,
    uint32_t force_idr, int64_t deadline_monotonic_ns, vf_gpu_dmabuf_output** output,
    bool allow_clean_expiry, const vf_gpu_dmabuf_atlas* atlas = nullptr,
    const vf_gpu_dmabuf_sparse_scene* sparse = nullptr) {
  try {
    if (encoder == nullptr) {
      if (output != nullptr) *output = nullptr;
      return VF_GPU_DMABUF_INVALID_ARGUMENT;
    }
    const auto status = require_owner(encoder);
    if (status != VF_GPU_DMABUF_OK) return status;
    if (output == nullptr) {
      encoder->terminal_failed = true;
      set_error(encoder, "encode requires a non-null output pointer; retire the capture path");
      return VF_GPU_DMABUF_INVALID_ARGUMENT;
    }
    *output = nullptr;
    if (encoder->terminal_failed) {
      set_error(encoder, "C ABI encoder is terminally failed; retire the capture path");
      return VF_GPU_DMABUF_ENCODER_FAILED;
    }
    bool valid_input = force_idr <= 1;
    if (atlas) {
      valid_input = valid_input && atlas->struct_size == sizeof(*atlas) &&
          atlas->version == VF_GPU_DMABUF_ATLAS_VERSION && atlas->reserved == 0 &&
          atlas->tile_count <= 4096 && (atlas->tile_count == 0 || atlas->tiles != nullptr);
      for (uint32_t i = 0; valid_input && i < atlas->tile_count; ++i)
        valid_input = valid_frame_flags(atlas->tiles[i].frame);
    } else {
      valid_input = valid_input && frame != nullptr && valid_frame_flags(*frame);
    }
    valid_input = valid_input && (!sparse || (atlas && (sparse->mode == 1 || sparse->mode == 2) &&
        sparse->source_count == atlas->tile_count && (!sparse->source_count || sparse->sources)));
    if (!valid_input) {
      encoder->terminal_failed = true;
      set_error(encoder, "invalid encode input; retire the capture path");
      return VF_GPU_DMABUF_INVALID_ARGUMENT;
    }
    EncodedDmabufFrame encoded{};
    std::string error;
    auto disposition = viewflow::gpu::EncodeDisposition::Failed;
    bool success = false;
    if (atlas) {
      std::vector<viewflow::gpu::DmabufAtlasTile> tiles;
      tiles.reserve(atlas->tile_count);
      for (uint32_t i = 0; i < atlas->tile_count; ++i) {
        const auto& tile = atlas->tiles[i];
        tiles.push_back({map_frame(tile.frame), tile.x, tile.y, tile.deadline_monotonic_ns});
      }
      std::optional<viewflow::gpu::SparseOptions> options;
      if (sparse) {
        options = viewflow::gpu::SparseOptions{sparse->mode == 2, sparse->max_width, sparse->max_height, {}};
        for(uint32_t i=0;i<sparse->source_count;++i) {
          const auto& a=sparse->sources[i]; options->sources.push_back({a.x,a.y,a.z,a.grid,a.clip_enabled,a.clip_x,a.clip_y,a.clip_width,a.clip_height});
        }
      }
      success = encoder->value->encodeAtlas(tiles,
          {atlas->frame_id, atlas->capture_timestamp_ns, atlas->geometry_epoch},
          force_idr != 0, deadline_monotonic_ns, encoded, &error, &disposition, options ? &*options : nullptr);
    } else {
      success = encoder->value->encode(map_frame(*frame), force_idr != 0, deadline_monotonic_ns,
                                       encoded, &error, &disposition);
    }
    if (!success && disposition == viewflow::gpu::EncodeDisposition::NeedsCanvas && sparse && encoded.sparse) {
      *output = new vf_gpu_dmabuf_output{std::move(encoded), std::this_thread::get_id()};
      return VF_GPU_DMABUF_NEEDS_CANVAS;
    }
    if (!success) {
      set_error(encoder, error);
      if (allow_clean_expiry &&
          disposition == viewflow::gpu::EncodeDisposition::ExpiredBeforeSubmission)
        return VF_GPU_DMABUF_EXPIRED_CLEAN;
      if (allow_clean_expiry &&
          disposition == viewflow::gpu::EncodeDisposition::ExpiredAfterSubmission)
        return VF_GPU_DMABUF_EXPIRED_AFTER_SUBMISSION;
      encoder->terminal_failed = true;
      return VF_GPU_DMABUF_ENCODER_FAILED;
    }
    try {
      *output = new vf_gpu_dmabuf_output{std::move(encoded), std::this_thread::get_id()};
    } catch (const std::bad_alloc&) {
      encoder->terminal_failed = true;
      set_error(encoder, "output allocation failed after encoder accepted media; retire the capture path");
      return VF_GPU_DMABUF_ALLOCATION_FAILED;
    } catch (...) {
      encoder->terminal_failed = true;
      set_error(encoder, "output conversion failed after encoder accepted media; retire the capture path");
      return VF_GPU_DMABUF_INTERNAL_ERROR;
    }
    return VF_GPU_DMABUF_OK;
  } catch (const std::bad_alloc&) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      set_error(encoder, "C ABI allocation failure; retire the capture path");
    }
    return VF_GPU_DMABUF_ALLOCATION_FAILED;
  } catch (...) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      set_error(encoder, "C ABI internal failure; retire the capture path");
    }
    return VF_GPU_DMABUF_INTERNAL_ERROR;
  }
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_frame* frame,
    uint32_t force_idr, int64_t deadline_monotonic_ns, vf_gpu_dmabuf_output** output) {
  return encode_impl(encoder, frame, force_idr, deadline_monotonic_ns, output, false);
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_frame* frame,
    uint32_t force_idr, int64_t deadline_monotonic_ns, vf_gpu_dmabuf_output** output) {
  return encode_impl(encoder, frame, force_idr, deadline_monotonic_ns, output, true);
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_atlas_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_atlas* atlas,
    uint32_t force_idr, int64_t deadline_monotonic_ns, vf_gpu_dmabuf_output** output) {
  return encode_impl(encoder, nullptr, force_idr, deadline_monotonic_ns, output, true, atlas);
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_encode_sparse_recoverable(
    vf_gpu_dmabuf_encoder* encoder, const vf_gpu_dmabuf_atlas* atlas,
    const vf_gpu_dmabuf_sparse_scene* scene, uint32_t force_idr,
    int64_t deadline, vf_gpu_dmabuf_output** output) {
  if (!scene) { if(output) *output=nullptr; return VF_GPU_DMABUF_INVALID_ARGUMENT; }
  return encode_impl(encoder, nullptr, force_idr, deadline, output, true, atlas, scene);
}
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_get_sparse_info(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_sparse_info* info) {
  return no_throw([&] {
    const auto status=require_owner(output);
    if(status!=VF_GPU_DMABUF_OK) return status;
    if(!info) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    *info={};
    if(output->value.sparse) {
      const auto& s=*output->value.sparse;
      *info={1, uint32_t(s.patches.size()), s.requiredWidth,s.requiredHeight,
             s.inputPixels,s.storedPixels,s.occludedPixels,s.emptyPixels,s.omittedPixels};
    }
    return VF_GPU_DMABUF_OK;
  });
}
vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_sparse_patches(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_sparse_patch* destination,
    size_t capacity,size_t* required) {
  return no_throw([&] {
    const auto status=require_owner(output);
    if(status!=VF_GPU_DMABUF_OK) return status;
    if(!required) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    *required=output->value.sparse ? output->value.sparse->patches.size() : 0;
    if(capacity<*required) return VF_GPU_DMABUF_BUFFER_TOO_SMALL;
    if(*required && !destination) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    for(size_t i=0;i<*required;++i) {
      const auto& p=output->value.sparse->patches[i];
      destination[i]={p.source,p.sourceX,p.sourceY,p.x,p.y,p.width,p.height};
    }
    return VF_GPU_DMABUF_OK;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_get_info(
    const vf_gpu_dmabuf_output* output, vf_gpu_dmabuf_output_info* info) {
  return no_throw([&] {
    const auto status = require_owner(output);
    if (status != VF_GPU_DMABUF_OK || info == nullptr) return info == nullptr ? VF_GPU_DMABUF_INVALID_ARGUMENT : status;
    const auto& value = output->value;
    *info = vf_gpu_dmabuf_output_info{value.metadata.frameId, value.metadata.captureTimestampNs,
                                      value.metadata.geometryEpoch, static_cast<uint32_t>(value.idr),
                                      value.colorAnnexB.size(), value.rawAlpha.size()};
    return VF_GPU_DMABUF_OK;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_color(
    const vf_gpu_dmabuf_output* output, uint8_t* destination, size_t capacity, size_t* required) {
  return no_throw([&] {
    const auto status = require_owner(output);
    return status == VF_GPU_DMABUF_OK ? copy_plane(output->value.colorAnnexB, destination, capacity, required) : status;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_copy_raw_alpha(
    const vf_gpu_dmabuf_output* output, uint8_t* destination, size_t capacity, size_t* required) {
  return no_throw([&] {
    const auto status = require_owner(output);
    if (status != VF_GPU_DMABUF_OK) return status;
    viewflow::gpu::AlphaCopyProfile profile("cabi_to_rust", output->value.metadata.frameId, output->value.rawAlpha.size());
    return copy_plane(output->value.rawAlpha, destination, capacity, required);
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_view_raw_alpha(
    const vf_gpu_dmabuf_output* output, const uint8_t** data, size_t* length) {
  return no_throw([&] {
    if (!data || !length) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    *data = nullptr;
    *length = 0;
    const auto status = require_owner(output);
    if (status != VF_GPU_DMABUF_OK) return status;
    *data = output->value.rawAlpha.data();
    *length = output->value.rawAlpha.size();
    return VF_GPU_DMABUF_OK;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_output_destroy(vf_gpu_dmabuf_output* output) {
  return no_throw([&] {
    const auto status = require_owner(output);
    if (status != VF_GPU_DMABUF_OK) return status;
    delete output;
    return VF_GPU_DMABUF_OK;
  });
}

vf_gpu_dmabuf_status vf_gpu_dmabuf_encoder_copy_last_error(
    const vf_gpu_dmabuf_encoder* encoder, char* destination, size_t capacity, size_t* required) {
  return no_throw([&] {
    const auto status = require_owner(encoder);
    if (status != VF_GPU_DMABUF_OK || required == nullptr) return required == nullptr ? VF_GPU_DMABUF_INVALID_ARGUMENT : status;
    *required = encoder->last_error.size() + 1;
    if (capacity < *required) return VF_GPU_DMABUF_BUFFER_TOO_SMALL;
    if (destination == nullptr) return VF_GPU_DMABUF_INVALID_ARGUMENT;
    std::memcpy(destination, encoder->last_error.c_str(), *required);
    return VF_GPU_DMABUF_OK;
  });
}

}  // extern "C"
