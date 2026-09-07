#pragma once
#include "../reverse-common/wire.hpp"
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <memory>

namespace viewflow::macos {
// All methods run on one serial owner. Returned pixel buffers have +1 ownership.
class Encoder {
public:
    Encoder();
    ~Encoder();
    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;
    reverse::Frame encode(CVPixelBufferRef color, reverse::Frame metadata);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
class Decoder {
public:
    Decoder();
    ~Decoder();
    Decoder(const Decoder&) = delete;
    Decoder& operator=(const Decoder&) = delete;
    CVPixelBufferRef decode(const reverse::Frame& frame);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
void codec_self_test(const char* fixture_path = nullptr); // Generated pixels only; never captures or posts input.
}
