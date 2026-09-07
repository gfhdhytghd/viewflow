#include "window_codec.hpp"
#include "../reverse-common/annex_b.hpp"
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <optional>
#include <fstream>
#include "../reverse-common/pipe_io.hpp"

namespace viewflow::macos {
namespace {
void check(OSStatus status, const char* operation) {
    if (status != noErr) throw std::runtime_error(std::string(operation) + ": " + std::to_string(status));
}
template<class T> struct CF {
    T value{};
    ~CF() { if (value) CFRelease(value); }
    operator T() const { return value; }
};
struct Encoded {
    OSStatus status{};
    CMSampleBufferRef sample{};
    ~Encoded() { if (sample) CFRelease(sample); }
};
void encoded(void*, void* context, OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
    auto& output = *static_cast<Encoded*>(context);
    output.status = status;
    if (sample) { CFRetain(sample); output.sample = sample; }
}
struct Decoded {
    OSStatus status{};
    CVPixelBufferRef image{};
    ~Decoded() { if (image) CVPixelBufferRelease(image); }
};
void decoded(void*, void* context, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
    auto& output = *static_cast<Decoded*>(context);
    output.status = status;
    if (image) output.image = CVPixelBufferRetain(image);
}
}

struct Encoder::Impl {
    VTCompressionSessionRef session{};
    unsigned width{}, height{}, codec{};
    void reset() {
        if (session) { VTCompressionSessionInvalidate(session); CFRelease(session); session = nullptr; }
    }
    ~Impl() { reset(); }
    void prepare(const reverse::Frame& frame) {
        if (session && width == frame.width && height == frame.height && codec == frame.codec) return;
        reset();
        width = frame.width; height = frame.height; codec = frame.codec;
        auto specification = @{(__bridge NSString*)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES};
        check(VTCompressionSessionCreate(kCFAllocatorDefault, static_cast<int32_t>(width), static_cast<int32_t>(height),
            codec == 2 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)specification, nullptr, nullptr, encoded, nullptr, &session), "create encoder");
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue), "encoder real time");
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse), "encoder ordering");
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
            codec == 2 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel), "encoder profile");
        const int interval = 60;
        CF<CFNumberRef> number{CFNumberCreate(nullptr, kCFNumberIntType, &interval)};
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, number), "encoder IDR interval");
        check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare encoder");
    }
};
Encoder::Encoder() : impl_(std::make_unique<Impl>()) {}
Encoder::~Encoder() = default;
reverse::Frame Encoder::encode(CVPixelBufferRef color, reverse::Frame frame) {
    if (!color || frame.width != CVPixelBufferGetWidth(color) || frame.height != CVPixelBufferGetHeight(color) ||
        !frame.width || !frame.height || frame.width > 8192 || frame.height > 8192 ||
        std::uint64_t(frame.width) * frame.height > reverse::max_pixels || (frame.codec != 1 && frame.codec != 2))
        throw std::runtime_error("encoder input extent/codec mismatch");
    impl_->prepare(frame);
    Encoded output;
    const CMTime pts = CMTimeMake(frame.pts, 1'000'000);
    // The explicit completion keeps the pixel buffer and frame metadata alive
    // through GPU reads. A delayed encode is measured by the owner, not aborted.
    check(VTCompressionSessionEncodeFrame(impl_->session, color, pts, kCMTimeInvalid,
        nullptr, &output, nullptr), "encode frame");
    check(VTCompressionSessionCompleteFrames(impl_->session, pts), "complete encode");
    check(output.status, "encoded callback");
    if (!output.sample) throw std::runtime_error("encoder produced no sample");
    const auto attachments = CMSampleBufferGetSampleAttachmentsArray(output.sample, false);
    frame.keyframe = !attachments || !CFArrayGetCount(attachments) ||
        !CFDictionaryContainsKey(static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0)), kCMSampleAttachmentKey_NotSync);
    const auto format = CMSampleBufferGetFormatDescription(output.sample);
    int length_size = 4;
    size_t count = 0;
    const uint8_t* parameter = nullptr;
    size_t parameter_size = 0;
    const auto parameter_at = [&](size_t index) {
        return frame.codec == 2
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, index, &parameter, &parameter_size, &count, &length_size)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &parameter, &parameter_size, &count, &length_size);
    };
    check(parameter_at(0), "encoder parameter sets");
    if (frame.keyframe) {
        for (size_t i = 0; i < count; ++i) {
            check(parameter_at(i), "encoder parameter set");
            reverse::append_annex_b(frame.color, {parameter, parameter_size});
        }
    }
    const auto block = CMSampleBufferGetDataBuffer(output.sample);
    if (!block) throw std::runtime_error("encoder missing block buffer");
    const auto size = CMBlockBufferGetDataLength(block);
    if (size > 32u * 1024u * 1024u) throw std::runtime_error("encoded access unit too large");
    std::vector<uint8_t> bytes(size);
    check(CMBlockBufferCopyDataBytes(block, 0, size, bytes.data()), "copy encoded access unit");
    auto annex = reverse::length_prefixed_to_annex_b(bytes, static_cast<unsigned>(length_size));
    frame.color.insert(frame.color.end(), annex.begin(), annex.end());
    reverse::validate(frame);
    return frame;
}

struct Decoder::Impl {
    VTDecompressionSessionRef session{};
    CMVideoFormatDescriptionRef format{};
    unsigned codec{};
    std::vector<uint8_t> vps, sps, pps;
    void reset() {
        if (session) { VTDecompressionSessionInvalidate(session); CFRelease(session); session = nullptr; }
        if (format) { CFRelease(format); format = nullptr; }
    }
    ~Impl() { reset(); }
    void prepare() {
        reset();
        if (sps.empty() || pps.empty() || (codec == 2 && vps.empty())) return;
        const uint8_t* h264_sets[] = {sps.data(), pps.data()};
        const size_t h264_sizes[] = {sps.size(), pps.size()};
        const uint8_t* hevc_sets[] = {vps.data(), sps.data(), pps.data()};
        const size_t hevc_sizes[] = {vps.size(), sps.size(), pps.size()};
        check(codec == 2
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(nullptr, 3, hevc_sets, hevc_sizes, 4, nullptr, &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, 2, h264_sets, h264_sizes, 4, &format), "decoder format");
        auto attributes = @{
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        auto specification = @{(__bridge NSString*)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES};
        VTDecompressionOutputCallbackRecord callback{decoded, nullptr};
        check(VTDecompressionSessionCreate(nullptr, format, (__bridge CFDictionaryRef)specification,
            (__bridge CFDictionaryRef)attributes, &callback, &session), "create decoder");
    }
};
Decoder::Decoder() : impl_(std::make_unique<Impl>()) {}
Decoder::~Decoder() = default;
CVPixelBufferRef Decoder::decode(const reverse::Frame& frame) {
    reverse::validate(frame);
    auto& s = *impl_;
    bool changed = s.codec != frame.codec;
    if (changed) { s.reset(); s.vps.clear(); s.sps.clear(); s.pps.clear(); s.codec = frame.codec; }
    auto units = reverse::annex_b_units(frame.color);
    std::vector<uint8_t> avcc;
    for (const auto unit : units) {
        const unsigned type = frame.codec == 2 ? (unit[0] >> 1) & 63 : unit[0] & 31;
        auto* parameter = frame.codec == 2 ? (type == 32 ? &s.vps : type == 33 ? &s.sps : type == 34 ? &s.pps : nullptr)
                                           : (type == 7 ? &s.sps : type == 8 ? &s.pps : nullptr);
        if (parameter) {
            if (parameter->size() != unit.size() || !std::equal(unit.begin(), unit.end(), parameter->begin())) {
                parameter->assign(unit.begin(), unit.end()); changed = true;
            }
            continue;
        }
        const auto count = static_cast<uint32_t>(unit.size());
        for (int shift : {24, 16, 8, 0}) avcc.push_back(static_cast<uint8_t>(count >> shift));
        avcc.insert(avcc.end(), unit.begin(), unit.end());
    }
    if (changed || !s.session) s.prepare();
    if (!s.session || avcc.empty()) return nullptr; // Wait for the next in-band IDR.
    CF<CMBlockBufferRef> block;
    check(CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, avcc.size(), nullptr, nullptr, 0, avcc.size(), 0, &block.value), "decoder block");
    check(CMBlockBufferReplaceDataBytes(avcc.data(), block, 0, avcc.size()), "decoder sample data");
    const CMSampleTimingInfo timing{kCMTimeInvalid, CMTimeMake(frame.pts, 1'000'000), kCMTimeInvalid};
    const size_t size = avcc.size();
    CF<CMSampleBufferRef> sample;
    check(CMSampleBufferCreateReady(nullptr, block, s.format, 1, 1, &timing, 1, &size, &sample.value), "decoder sample");
    Decoded output;
    const auto status = VTDecompressionSessionDecodeFrame(s.session, sample, 0, &output, nullptr);
    // Wait even when DecodeFrame reports an error: callback refcon lives here.
    check(VTDecompressionSessionWaitForAsynchronousFrames(s.session), "complete decode");
    check(status, "decode frame");
    check(output.status, "decoded callback");
    if (!output.image) return nullptr;
    if (CVPixelBufferGetWidth(output.image) != frame.width || CVPixelBufferGetHeight(output.image) != frame.height)
        throw std::runtime_error("decoded geometry differs from frame metadata");
    const auto result = output.image; output.image = nullptr; return result;
}

void codec_self_test(const char* fixture_path) {
    std::ofstream fixture;
    if (fixture_path) {
        fixture.open(fixture_path, std::ios::binary | std::ios::trunc);
        if (!fixture) throw std::runtime_error("open generated codec fixture");
    }
    for (const unsigned codec : {1u, 2u}) {
        if (fixture_path && codec != 1) continue;
        Encoder encoder;
        Decoder decoder;
        for (const unsigned width : {64u, 64u, 80u, 64u}) {
            CF<CVPixelBufferRef> buffer;
            auto attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            check(CVPixelBufferCreate(nullptr, width, 64, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer.value), "fixture pixels");
            check(CVPixelBufferLockBaseAddress(buffer, 0), "fixture lock");
            auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
            const auto stride = CVPixelBufferGetBytesPerRow(buffer);
            for (unsigned y = 0; y < 64; ++y) for (unsigned x = 0; x < width; ++x) {
                auto* p = base + y * stride + 4 * x; p[0] = 40; p[1] = 100; p[2] = 200; p[3] = 255;
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            reverse::Frame frame; frame.codec = codec; frame.width = width; frame.height = 64;
            static int64_t pts = 0; frame.pts = ++pts * 16'667;
            frame.tiles.push_back({1, 0, -120, 80, width, 64, 0, 0, "codec fixture", 0, 0});
            frame.alpha = reverse::encode_alpha(std::vector<uint8_t>(width * 64, 127));
            frame = reverse::unpack_frame(reverse::pack_frame(encoder.encode(buffer, std::move(frame))));
            if (fixture_path) {
                const auto bytes = reverse::pack_frame(frame);
                reverse::Writer prefix; prefix.u32(static_cast<uint32_t>(bytes.size()));
                fixture.write(reinterpret_cast<const char*>(prefix.bytes.data()), static_cast<std::streamsize>(prefix.bytes.size()));
                fixture.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
                if (!fixture) throw std::runtime_error("write generated codec fixture");
            }
            CF<CVPixelBufferRef> decoded_buffer{decoder.decode(frame)};
            if (!decoded_buffer.value) throw std::runtime_error("fixture decode missing");
            check(CVPixelBufferLockBaseAddress(decoded_buffer, kCVPixelBufferLock_ReadOnly), "decoded fixture lock");
            const auto* pixel = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(decoded_buffer));
            const bool matches = std::abs(int(pixel[0]) - 40) < 20 && std::abs(int(pixel[1]) - 100) < 20 && std::abs(int(pixel[2]) - 200) < 20;
            CVPixelBufferUnlockBaseAddress(decoded_buffer, kCVPixelBufferLock_ReadOnly);
            if (!matches || reverse::decode_alpha(frame.alpha, width * 64)[0] != 127)
                throw std::runtime_error("codec fixture color/alpha mismatch");
        }
    }
    std::fprintf(stderr, "macos-window codec self-test passed: H264/HEVC, alpha, resize; no capture/input\n");
}
}
