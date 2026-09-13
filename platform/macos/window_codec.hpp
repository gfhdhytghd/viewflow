#pragma once
#include "../reverse-common/wire.hpp"
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <memory>

namespace viewflow::macos {
// Submit/flush have one serial owner; finish may run on an ordered completion
// worker. Tickets retain input through the callback. Decoder outputs have +1 ownership.
class Encoder {
public:
    struct Pending;
    using Ticket = std::shared_ptr<Pending>;
    explicit Encoder(unsigned fps = 60, bool latency = false);
    ~Encoder();
    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;
    reverse::Frame encode(CVPixelBufferRef color, reverse::Frame metadata);
    Ticket submit(CVPixelBufferRef color, reverse::Frame metadata);
    static reverse::Frame finish(Ticket ticket);
    void flush();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
class Decoder {
public:
    explicit Decoder(bool native_yuv = true);
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
