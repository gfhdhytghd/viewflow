#include "window_codec.hpp"
#include "../reverse-common/annex_b.hpp"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <optional>
#include <condition_variable>
#include <mutex>
#include <future>
#include "../reverse-common/blur_recipe.hpp"
#include <fstream>
#include "../reverse-common/pipe_io.hpp"

namespace viewflow::macos {
struct Encoder::Pending {
    std::mutex mutex;
    std::condition_variable changed;
    bool done{};
    OSStatus status{};
    VTEncodeInfoFlags flags{};
    CMSampleBufferRef sample{};
    CVPixelBufferRef pixels{};
    reverse::Frame frame;
    ~Pending() { if (sample) CFRelease(sample); if (pixels) CVPixelBufferRelease(pixels); }
};
namespace {
void check(OSStatus status, const char* operation) {
    if (status != noErr) throw std::runtime_error(std::string(operation) + ": " + std::to_string(status));
}
template<class T> struct CF {
    T value{};
    ~CF() { if (value) CFRelease(value); }
    operator T() const { return value; }
};
void encoded(void*, void* context, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    auto& output = *static_cast<Encoder::Pending*>(context);
    {
        std::lock_guard lock(output.mutex);
        output.status = status;
        output.flags = flags;
        if (sample) { CFRetain(sample); output.sample = sample; }
        output.done = true;
    }
    output.changed.notify_all();
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
    unsigned width{}, height{}, codec{}, fps{60};
    bool latency{}, pipeline{};
    std::vector<Ticket> pending;
    void reset() {
        if (session) {
            VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
            VTCompressionSessionInvalidate(session); CFRelease(session); session = nullptr;
        }
        for (auto& ticket : pending) {
            std::lock_guard lock(ticket->mutex);
            if (!ticket->done) { ticket->status = kVTInvalidSessionErr; ticket->done = true; ticket->changed.notify_all(); }
        }
        pending.clear(); pipeline = false;
    }
    ~Impl() { reset(); }
    void prepare(const reverse::Frame& frame) {
        if (session && width == frame.width && height == frame.height && codec == frame.codec) return;
        reset();
        width = frame.width; height = frame.height; codec = frame.codec;
        NSMutableDictionary* specification = [@{(__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES} mutableCopy];
        const bool low_latency = latency && codec == 1;
        if (low_latency) specification[(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
        auto create = [&] { return VTCompressionSessionCreate(kCFAllocatorDefault, static_cast<int32_t>(width), static_cast<int32_t>(height),
            codec == 2 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)specification, nullptr, nullptr, encoded, nullptr, &session); };
        auto status = create();
        if (status != noErr && low_latency) {
            reset();
            [specification removeObjectForKey:(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl];
            std::fprintf(stderr, "macos-encoder low-latency rate control unavailable=%d; using hardware fallback\n", int(status));
            status = create();
        }
        check(status, "create encoder");
        pipeline = codec == 2 || (low_latency && specification[(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] != nil);
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue), "encoder real time");
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse), "encoder ordering");
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
            codec == 2 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel), "encoder profile");
        const int interval = static_cast<int>(fps * 2);
        CF<CFNumberRef> number{CFNumberCreate(nullptr, kCFNumberIntType, &interval)};
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, number), "encoder IDR interval");
        const int expected = static_cast<int>(fps);
        CF<CFNumberRef> expected_number{CFNumberCreate(nullptr, kCFNumberIntType, &expected)};
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, expected_number), "encoder expected frame rate");
        // Keep the existing floor for small windows, and budget 0.125 bits per
        // pixel per frame for 4K60 instead of starving its low-latency controller.
        const int bitrate = static_cast<int>(std::clamp(uint64_t(width) * height * fps / 8,
            uint64_t(24'000'000), uint64_t(80'000'000)));
        CF<CFNumberRef> bitrate_number{CFNumberCreate(nullptr, kCFNumberIntType, &bitrate)};
        check(VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrate_number), "encoder bitrate");
        const int delay = latency ? 1 : 3;
        CF<CFNumberRef> delay_number{CFNumberCreate(nullptr, kCFNumberIntType, &delay)};
        const auto delay_status = VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, delay_number);
        const auto speed_status = VTSessionSetProperty(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
        std::fprintf(stderr, "macos-encoder mode=%s fps=%u bitrate=%d max-delay-status=%d speed-status=%d\n",
            latency ? "latency" : "frame-rate", fps, bitrate, int(delay_status), int(speed_status));
        check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare encoder");
    }
};
Encoder::Encoder(unsigned fps, bool latency) : impl_(std::make_unique<Impl>()) {
    impl_->fps = fps; impl_->latency = latency;
}
Encoder::~Encoder() = default;
reverse::Frame Encoder::encode(CVPixelBufferRef color, reverse::Frame frame) {
    auto ticket = submit(color, std::move(frame));
    flush();
    return finish(std::move(ticket));
}
void Encoder::flush() {
    if (impl_->session) check(VTCompressionSessionCompleteFrames(impl_->session, kCMTimeInvalid), "complete encode");
}
Encoder::Ticket Encoder::submit(CVPixelBufferRef color, reverse::Frame frame) {
    if (!color || frame.width != CVPixelBufferGetWidth(color) || frame.height != CVPixelBufferGetHeight(color) ||
        !frame.width || !frame.height || frame.width > 8192 || frame.height > 8192 ||
        std::uint64_t(frame.width) * frame.height > reverse::max_pixels || (frame.codec != 1 && frame.codec != 2))
        throw std::runtime_error("encoder input extent/codec mismatch");
    impl_->prepare(frame);
    std::erase_if(impl_->pending, [](const auto& ticket) {
        std::lock_guard lock(ticket->mutex); return ticket->done;
    });
    auto output = std::make_shared<Pending>();
    output->pixels = CVPixelBufferRetain(color);
    const CMTime pts = CMTimeMake(frame.pts, 1'000'000);
    output->frame = std::move(frame);
    impl_->pending.push_back(output);
    const auto status = VTCompressionSessionEncodeFrame(impl_->session, color, pts, kCMTimeInvalid,
        nullptr, output.get(), nullptr);
    if (status != noErr) {
        std::lock_guard lock(output->mutex);
        output->status = status; output->done = true;
        output->changed.notify_all();
    }
    // Encoders without the selected low-latency mode may buffer more than our
    // bounded pipeline. Complete their submission locally rather than waiting
    // for an extra input frame that might never arrive on a static desktop.
    if (!impl_->pipeline) flush();
    return output;
}
reverse::Frame Encoder::finish(Ticket ticket) {
    auto& output = *ticket;
    std::unique_lock lock(output.mutex);
    output.changed.wait(lock, [&] { return output.done; });
    check(output.status, "encoded callback");
    if (!output.sample) throw std::runtime_error(output.flags & kVTEncodeInfo_FrameDropped ? "encoder dropped frame" : "encoder produced no sample");
    auto frame = std::move(output.frame);
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
    bool native_yuv{true};
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
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(native_yuv ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA),
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        auto specification = @{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        VTDecompressionOutputCallbackRecord callback{decoded, nullptr};
        check(VTDecompressionSessionCreate(nullptr, format, (__bridge CFDictionaryRef)specification,
            (__bridge CFDictionaryRef)attributes, &callback, &session), "create decoder");
        check(VTSessionSetProperty(session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue), "decoder real time");
        CF<CFTypeRef> hardware;
        const auto hardware_status = VTSessionCopyProperty(session,
            kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, kCFAllocatorDefault, &hardware.value);
        const bool hardware_active = hardware.value && CFGetTypeID(hardware.value) == CFBooleanGetTypeID() &&
            CFBooleanGetValue(static_cast<CFBooleanRef>(hardware.value));
        std::fprintf(stderr, "macos-decoder hardware-required=true hardware-status=%d hardware-active=%u output=%s\n",
            int(hardware_status), unsigned(hardware_active), native_yuv ? "nv12" : "bgra");
        if (hardware_status != noErr || !hardware_active) throw std::runtime_error("hardware VideoToolbox decoder unavailable");
    }
};
Decoder::Decoder(bool native_yuv) : impl_(std::make_unique<Impl>()) { impl_->native_yuv = native_yuv; }
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
        Decoder bgra_decoder(false);
        CIContext* context = [CIContext contextWithOptions:nil];
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
            if(codec==1) {
                const reverse::BlurRecipe recipe{true,5,4,.8916f,1,.0117f,.1696f,0};
                auto sei=reverse::h264_blur_recipe_sei(recipe);
                frame.color.insert(frame.color.begin(),sei.begin(),sei.end());
                if(reverse::blur_recipe_from_annex_b(frame.color,codec)!=recipe)throw std::runtime_error("codec blur metadata mismatch");
            }
            if (fixture_path) {
                const auto bytes = reverse::pack_frame(frame);
                reverse::Writer prefix; prefix.u32(static_cast<uint32_t>(bytes.size()));
                fixture.write(reinterpret_cast<const char*>(prefix.bytes.data()), static_cast<std::streamsize>(prefix.bytes.size()));
                fixture.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
                if (!fixture) throw std::runtime_error("write generated codec fixture");
            }
            CF<CVPixelBufferRef> decoded_buffer{decoder.decode(frame)};
            if (!decoded_buffer.value) throw std::runtime_error("fixture decode missing");
            CF<CVPixelBufferRef> bgra_buffer{bgra_decoder.decode(frame)};
            if (!bgra_buffer.value || CVPixelBufferGetPixelFormatType(decoded_buffer) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                throw std::runtime_error("codec fixture native NV12 output missing");
            CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            for (CVPixelBufferRef output : {decoded_buffer.value, bgra_buffer.value}) {
                uint8_t pixel[4]{};
                [context render:[CIImage imageWithCVPixelBuffer:output] toBitmap:pixel rowBytes:4
                    bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatBGRA8 colorSpace:colors];
                const bool matches = std::abs(int(pixel[0]) - 40) < 20 && std::abs(int(pixel[1]) - 100) < 20 && std::abs(int(pixel[2]) - 200) < 20;
                if (!matches) { CGColorSpaceRelease(colors); throw std::runtime_error("codec fixture color mismatch"); }
            }
            CGColorSpaceRelease(colors);
            if (reverse::decode_alpha(frame.alpha, width * 64)[0] != 127)
                throw std::runtime_error("codec fixture alpha mismatch");
        }
    }
    for (const unsigned codec : {1u, 2u}) {
        Encoder encoder(60, true);
        Decoder decoder;
        std::vector<Encoder::Ticket> tickets;
        uint64_t sequence = 0;
        for (unsigned width : {64u, 64u, 80u, 80u}) {
            CF<CVPixelBufferRef> buffer;
            auto attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            check(CVPixelBufferCreate(nullptr, width, 64, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attributes, &buffer.value), "pipeline fixture pixels");
            check(CVPixelBufferLockBaseAddress(buffer, 0), "pipeline fixture lock");
            std::memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetBytesPerRow(buffer) * 64);
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            reverse::Frame frame; frame.width = width; frame.height = 64; frame.codec = codec;
            frame.pts = ++sequence * 16'667;
            frame.alpha = reverse::encode_alpha(std::vector<uint8_t>(width * 64, 255));
            tickets.push_back(encoder.submit(buffer, std::move(frame)));
            // Release caller buffers immediately; tickets must retain GPU input.
        }
        encoder.flush();
        sequence = 0;
        for (auto& ticket : tickets) {
            auto frame = Encoder::finish(ticket);
            if (frame.pts != int64_t(++sequence * 16'667)) throw std::runtime_error("pipeline frame order");
            CF<CVPixelBufferRef> image{decoder.decode(frame)};
            if (!image.value || CVPixelBufferGetWidth(image) != frame.width) throw std::runtime_error("pipeline resize decode");
        }
        // A static desktop must produce its final frame without needing a
        // subsequent submission or an explicit completion flush.
        CF<CVPixelBufferRef> buffer;
        auto attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        check(CVPixelBufferCreate(nullptr, 80, 64, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &buffer.value), "static fixture pixels");
        check(CVPixelBufferLockBaseAddress(buffer, 0), "static fixture lock");
        std::memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetBytesPerRow(buffer) * 64);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        reverse::Frame frame; frame.width = 80; frame.height = 64; frame.codec = codec; frame.pts = 100'000;
        frame.alpha = reverse::encode_alpha(std::vector<uint8_t>(80 * 64, 255));
        auto ticket = encoder.submit(buffer, std::move(frame));
        auto result = std::async(std::launch::async, [ticket] { return Encoder::finish(ticket); });
        const bool timely = result.wait_for(std::chrono::milliseconds(100)) == std::future_status::ready;
        if (!timely) encoder.flush(); // Test cleanup, not a production deadline.
        auto last = result.get();
        if (!timely || last.pts != 100'000) throw std::runtime_error("static frame required encoder flush");
    }
    std::fprintf(stderr, "macos-window codec self-test passed: H264/HEVC, NV12/BGRA color, alpha, resize, async ownership/order; no capture/input\n");
}
}
