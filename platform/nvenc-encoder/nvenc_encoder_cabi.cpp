#include "nvenc_encoder_cabi.h"

#include "nvenc_encoder.hpp"

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

using viewflow::nvenc::AlphaDisposition;
using viewflow::nvenc::AlphaFidelity;
using viewflow::nvenc::AlphaFidelityKind;
using viewflow::nvenc::AlphaPolicy;
using viewflow::nvenc::EncodedAccessUnit;
using viewflow::nvenc::Encoder;
using viewflow::nvenc::EncoderConfig;
using viewflow::nvenc::FrameMetadata;
using viewflow::nvenc::H264Profile;
using viewflow::nvenc::StreamDescriptor;

struct vf_nvenc_encoder {
  std::unique_ptr<Encoder> encoder;
  std::string last_error;
  bool terminal_failed = false;
};

struct vf_nvenc_output_au {
  EncodedAccessUnit value;
};

namespace {

template <typename Function>
vf_nvenc_status no_throw(Function&& function) noexcept {
  try {
    return function();
  } catch (const std::bad_alloc&) {
    return VF_NVENC_ALLOCATION_FAILED;
  } catch (...) {
    return VF_NVENC_INTERNAL_ERROR;
  }
}

[[nodiscard]] vf_nvenc_status validate_output_list(const vf_nvenc_output_list* list,
                                                    bool require_empty) {
  if (list == nullptr) return VF_NVENC_INVALID_ARGUMENT;
  if (list->version != VF_NVENC_CABI_VERSION) return VF_NVENC_UNSUPPORTED_VERSION;
  if (list->struct_size != sizeof(*list)) return VF_NVENC_INVALID_ARGUMENT;
  if ((list->count == 0) != (list->items == nullptr)) return VF_NVENC_INVALID_ARGUMENT;
  if (require_empty && (list->count != 0 || list->items != nullptr)) return VF_NVENC_INVALID_ARGUMENT;
  return VF_NVENC_OK;
}

[[nodiscard]] vf_nvenc_status map_config(const vf_nvenc_encoder_config* source,
                                          EncoderConfig* destination) {
  if (source == nullptr || destination == nullptr) return VF_NVENC_INVALID_ARGUMENT;
  if (source->version != VF_NVENC_CABI_VERSION) return VF_NVENC_UNSUPPORTED_VERSION;
  if (source->struct_size != sizeof(*source)) return VF_NVENC_INVALID_ARGUMENT;
  if (source->alpha_policy > VF_NVENC_ALPHA_COLOR_ONLY_EXTERNAL ||
      source->alpha_fidelity > VF_NVENC_ALPHA_BOUNDED_LOSSY) {
    return VF_NVENC_INVALID_CONFIG;
  }
  if (source->width == 0 || source->height == 0 || source->max_access_unit_bytes == 0 ||
      source->max_pending_frames == 0 ||
      (source->alpha_fidelity == VF_NVENC_ALPHA_BOUNDED_LOSSY &&
       (source->alpha_max_quantizer == 0 || source->alpha_max_quantizer > 51))) {
    return VF_NVENC_INVALID_CONFIG;
  }
  if (source->alpha_fidelity == VF_NVENC_ALPHA_LOSSLESS && source->alpha_max_quantizer != 0) {
    return VF_NVENC_INVALID_CONFIG;
  }
  for (uint8_t byte : source->reserved) {
    if (byte != 0) return VF_NVENC_INVALID_CONFIG;
  }
  *destination = EncoderConfig{
      source->width,
      source->height,
      source->max_access_unit_bytes,
      source->max_pending_frames,
      source->alpha_policy == VF_NVENC_ALPHA_REQUIRED ? AlphaPolicy::Required
      : source->alpha_policy == VF_NVENC_ALPHA_OPAQUE_MAY_OMIT ? AlphaPolicy::OpaqueMayOmit
                                                                : AlphaPolicy::ColorOnlyExternalAlpha,
      AlphaFidelity{source->alpha_fidelity == VF_NVENC_ALPHA_LOSSLESS
                        ? AlphaFidelityKind::Lossless
                        : AlphaFidelityKind::BoundedLossy,
                    source->alpha_max_quantizer},
  };
  return VF_NVENC_OK;
}

[[nodiscard]] vf_nvenc_stream_descriptor convert_descriptor(StreamDescriptor descriptor) {
  return vf_nvenc_stream_descriptor{
      descriptor.profile == H264Profile::High8 ? VF_NVENC_H264_HIGH_8
                                                : VF_NVENC_H264_HIGH_444_PREDICTIVE_8,
      static_cast<uint8_t>(descriptor.full_range),
      static_cast<uint8_t>(descriptor.luma_is_straight_alpha),
      static_cast<uint8_t>(descriptor.chroma_is_neutral),
      0,
  };
}

[[nodiscard]] vf_nvenc_status move_output(std::vector<EncodedAccessUnit>* encoded,
                                           vf_nvenc_output_list* output) {
  if (encoded == nullptr) return VF_NVENC_INVALID_ARGUMENT;
  const auto list_status = validate_output_list(output, true);
  if (list_status != VF_NVENC_OK) return list_status;
  if (encoded->empty()) return VF_NVENC_OK;
  auto items = std::make_unique<vf_nvenc_output_au*[]>(encoded->size());
  size_t constructed = 0;
  try {
    for (; constructed < encoded->size(); ++constructed) {
      items[constructed] = new vf_nvenc_output_au{std::move((*encoded)[constructed])};
    }
  } catch (...) {
    for (size_t index = 0; index < constructed; ++index) delete items[index];
    throw;
  }
  output->items = items.release();
  output->count = encoded->size();
  return VF_NVENC_OK;
}

[[nodiscard]] vf_nvenc_status copy_plane(const std::vector<uint8_t>& source, uint8_t* destination,
                                          size_t capacity, size_t* required) {
  if (required == nullptr) return VF_NVENC_INVALID_ARGUMENT;
  *required = source.size();
  if (capacity < source.size()) return VF_NVENC_BUFFER_TOO_SMALL;
  if (!source.empty() && destination == nullptr) return VF_NVENC_INVALID_ARGUMENT;
  if (!source.empty()) std::memcpy(destination, source.data(), source.size());
  return VF_NVENC_OK;
}

[[nodiscard]] vf_nvenc_status set_error(vf_nvenc_encoder* encoder, std::string error,
                                         vf_nvenc_status status) {
  if (encoder != nullptr) encoder->last_error = std::move(error);
  return status;
}

}  // namespace

extern "C" {

void vf_nvenc_output_list_init(vf_nvenc_output_list* list) {
  if (list == nullptr) return;
  *list = vf_nvenc_output_list{static_cast<uint32_t>(sizeof(*list)), VF_NVENC_CABI_VERSION, nullptr, 0};
}

vf_nvenc_status vf_nvenc_output_list_destroy(vf_nvenc_output_list* list) {
  return no_throw([&] {
    const auto status = validate_output_list(list, false);
    if (status != VF_NVENC_OK) return status;
    for (size_t index = 0; index < list->count; ++index) delete list->items[index];
    delete[] list->items;
    vf_nvenc_output_list_init(list);
    return VF_NVENC_OK;
  });
}

vf_nvenc_status vf_nvenc_output_list_take(vf_nvenc_output_list* list, size_t index,
                                           vf_nvenc_output_au** output) {
  return no_throw([&] {
    if (output == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    *output = nullptr;
    const auto status = validate_output_list(list, false);
    if (status != VF_NVENC_OK) return status;
    if (index >= list->count) return VF_NVENC_INDEX_OUT_OF_RANGE;
    *output = list->items[index];
    std::move(list->items + index + 1, list->items + list->count, list->items + index);
    --list->count;
    if (list->count == 0) {
      delete[] list->items;
      list->items = nullptr;
    }
    return VF_NVENC_OK;
  });
}

void vf_nvenc_output_au_destroy(vf_nvenc_output_au* output) { delete output; }

vf_nvenc_status vf_nvenc_encoder_create(const vf_nvenc_encoder_config* config,
                                         vf_nvenc_encoder** output) {
  return no_throw([&] {
    if (output == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    *output = nullptr;
    EncoderConfig native{};
    const auto status = map_config(config, &native);
    if (status != VF_NVENC_OK) return status;
    std::string error;
    auto created = Encoder::create(native, &error);
    if (!created) return VF_NVENC_ENCODER_FAILED;
    *output = new vf_nvenc_encoder{std::move(created), {}};
    return VF_NVENC_OK;
  });
}

void vf_nvenc_encoder_destroy(vf_nvenc_encoder* encoder) { delete encoder; }

vf_nvenc_status vf_nvenc_encoder_submit(vf_nvenc_encoder* encoder, const uint8_t* straight_rgba,
                                         size_t straight_rgba_bytes,
                                         vf_nvenc_frame_metadata metadata, uint8_t force_idr,
                                         vf_nvenc_output_list* output) {
  try {
    if (encoder == nullptr || straight_rgba == nullptr || force_idr > 1) return VF_NVENC_INVALID_ARGUMENT;
    if (encoder->terminal_failed) return set_error(encoder, "C ABI encoder is terminally failed", VF_NVENC_ENCODER_FAILED);
    const auto output_status = validate_output_list(output, true);
    if (output_status != VF_NVENC_OK) return output_status;
    std::vector<EncodedAccessUnit> encoded;
    std::string error;
    if (!encoder->encoder->submit(std::span<const uint8_t>(straight_rgba, straight_rgba_bytes),
                                  FrameMetadata{metadata.frame_id, metadata.timestamp_ns,
                                                metadata.geometry_epoch},
                                  force_idr != 0, &encoded, &error)) {
      return set_error(encoder, std::move(error), VF_NVENC_ENCODER_FAILED);
    }
    try {
      return move_output(&encoded, output);
    } catch (const std::bad_alloc&) {
      encoder->terminal_failed = true;
      return set_error(encoder, "output ownership allocation failed after NVENC accepted media",
                       VF_NVENC_ALLOCATION_FAILED);
    } catch (...) {
      encoder->terminal_failed = true;
      return set_error(encoder, "output ownership conversion failed after NVENC accepted media",
                       VF_NVENC_INTERNAL_ERROR);
    }
  } catch (const std::bad_alloc&) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      encoder->last_error.clear();
    }
    return VF_NVENC_ALLOCATION_FAILED;
  } catch (...) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      encoder->last_error.clear();
    }
    return VF_NVENC_INTERNAL_ERROR;
  }
}

vf_nvenc_status vf_nvenc_encoder_drain(vf_nvenc_encoder* encoder,
                                        vf_nvenc_output_list* output) {
  try {
    if (encoder == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    if (encoder->terminal_failed) return set_error(encoder, "C ABI encoder is terminally failed", VF_NVENC_ENCODER_FAILED);
    const auto output_status = validate_output_list(output, true);
    if (output_status != VF_NVENC_OK) return output_status;
    std::vector<EncodedAccessUnit> encoded;
    std::string error;
    if (!encoder->encoder->drain(&encoded, &error)) {
      return set_error(encoder, std::move(error), VF_NVENC_ENCODER_FAILED);
    }
    try {
      return move_output(&encoded, output);
    } catch (const std::bad_alloc&) {
      encoder->terminal_failed = true;
      return set_error(encoder, "output ownership allocation failed after NVENC drain",
                       VF_NVENC_ALLOCATION_FAILED);
    } catch (...) {
      encoder->terminal_failed = true;
      return set_error(encoder, "output ownership conversion failed after NVENC drain",
                       VF_NVENC_INTERNAL_ERROR);
    }
  } catch (const std::bad_alloc&) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      encoder->last_error.clear();
    }
    return VF_NVENC_ALLOCATION_FAILED;
  } catch (...) {
    if (encoder != nullptr) {
      encoder->terminal_failed = true;
      encoder->last_error.clear();
    }
    return VF_NVENC_INTERNAL_ERROR;
  }
}

vf_nvenc_status vf_nvenc_output_au_get_info(const vf_nvenc_output_au* output,
                                             vf_nvenc_output_info* info) {
  return no_throw([&] {
    if (output == nullptr || info == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    const auto& value = output->value;
    *info = vf_nvenc_output_info{
        static_cast<uint32_t>(sizeof(*info)),
        VF_NVENC_CABI_VERSION,
        {value.metadata.frame_id, value.metadata.timestamp_ns, value.metadata.geometry_epoch},
        value.alpha == AlphaDisposition::EncodedFullRange ? VF_NVENC_ALPHA_ENCODED_FULL_RANGE
        : value.alpha == AlphaDisposition::OpaqueOmitted ? VF_NVENC_ALPHA_OPAQUE_OMITTED
                                                          : VF_NVENC_ALPHA_EXTERNAL,
        static_cast<uint8_t>(value.color_is_idr),
        static_cast<uint8_t>(value.alpha_is_idr),
        static_cast<uint8_t>(value.alpha_stream.has_value()),
        {0, 0, 0, 0, 0},
        convert_descriptor(value.color_stream),
        value.alpha_stream.has_value() ? convert_descriptor(*value.alpha_stream)
                                       : vf_nvenc_stream_descriptor{},
        value.color_annex_b.size(),
        value.alpha_annex_b.size(),
    };
    return VF_NVENC_OK;
  });
}

vf_nvenc_status vf_nvenc_output_au_copy_color(const vf_nvenc_output_au* output,
                                               uint8_t* destination, size_t capacity,
                                               size_t* required) {
  return no_throw([&] {
    if (output == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    return copy_plane(output->value.color_annex_b, destination, capacity, required);
  });
}

vf_nvenc_status vf_nvenc_output_au_copy_alpha(const vf_nvenc_output_au* output,
                                               uint8_t* destination, size_t capacity,
                                               size_t* required) {
  return no_throw([&] {
    if (output == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    return copy_plane(output->value.alpha_annex_b, destination, capacity, required);
  });
}

vf_nvenc_status vf_nvenc_encoder_copy_last_error(const vf_nvenc_encoder* encoder,
                                                  char* destination, size_t capacity,
                                                  size_t* required) {
  return no_throw([&] {
    if (encoder == nullptr || required == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    *required = encoder->last_error.size() + 1;
    if (capacity < *required) return VF_NVENC_BUFFER_TOO_SMALL;
    if (destination == nullptr) return VF_NVENC_INVALID_ARGUMENT;
    std::memcpy(destination, encoder->last_error.c_str(), *required);
    return VF_NVENC_OK;
  });
}

}  // extern "C"
