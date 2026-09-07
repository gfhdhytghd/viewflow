#include "hardware_encoder.hpp"
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <codecapi.h>
#include <strmif.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstring>

namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define VF_HR(expr) do { const HRESULT vf_status = (expr); if (FAILED(vf_status)) { std::fprintf(stderr, "reverse-encoder %s hr=%08lx\n", #expr, static_cast<unsigned long>(vf_status)); return vf_status; } } while (0)
struct HardwareEncoder::Impl {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VideoDevice> video;
    ComPtr<ID3D11VideoContext> video_context;
    ComPtr<ID3D11VideoProcessorEnumerator> enumeration;
    ComPtr<ID3D11VideoProcessor> processor;
    ComPtr<IMFDXGIDeviceManager> manager;
    ComPtr<IMFTransform> encoder;
    ComPtr<IMFMediaEventGenerator> events;
    ComPtr<ICodecAPI> codec;
    unsigned width{}, height{}, fps{}, input_ready{}, output_ready{};
    DWORD input_id{}, output_id{};
    bool mf_started{};
    ~Impl() {
        if (encoder) {
            encoder->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        }
        encoder.Reset(); events.Reset(); codec.Reset(); manager.Reset();
        if (mf_started) MFShutdown();
    }
    HRESULT event_poll() {
        for (;;) {
            ComPtr<IMFMediaEvent> event;
            const HRESULT result = events->GetEvent(MF_EVENT_FLAG_NO_WAIT, &event);
            if (result == MF_E_NO_EVENTS_AVAILABLE) return S_OK;
            VF_HR(result);
            HRESULT status{}; VF_HR(event->GetStatus(&status)); VF_HR(status);
            MediaEventType type{}; VF_HR(event->GetType(&type));
            if (type == METransformNeedInput) ++input_ready;
            if (type == METransformHaveOutput) ++output_ready;
        }
    }
};
HardwareEncoder::HardwareEncoder() : impl_(std::make_unique<Impl>()) {}
HardwareEncoder::~HardwareEncoder() = default;
HRESULT HardwareEncoder::start(ID3D11Device* device, unsigned width, unsigned height, unsigned fps, unsigned codec) {
    auto& s = *impl_;
    if (!device || s.encoder || !width || !height || width % 2 || height % 2 || !fps || (codec!=1 && codec!=2)) return E_INVALIDARG;
    VF_HR(MFStartup(MF_VERSION)); s.mf_started = true;
    s.device = device; device->GetImmediateContext(&s.context);
    VF_HR(device->QueryInterface(IID_PPV_ARGS(&s.video)));
    VF_HR(s.context.As(&s.video_context));
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc{};
    desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    desc.InputWidth = desc.OutputWidth = width;
    desc.InputHeight = desc.OutputHeight = height;
    desc.InputFrameRate = desc.OutputFrameRate = {fps, 1};
    desc.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
    VF_HR(s.video->CreateVideoProcessorEnumerator(&desc, &s.enumeration));
    VF_HR(s.video->CreateVideoProcessor(s.enumeration.Get(), 0, &s.processor));
    RECT rect{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    s.video_context->VideoProcessorSetStreamSourceRect(s.processor.Get(), 0, TRUE, &rect);
    s.video_context->VideoProcessorSetStreamDestRect(s.processor.Get(), 0, TRUE, &rect);
    s.video_context->VideoProcessorSetOutputTargetRect(s.processor.Get(), TRUE, &rect);
    s.video_context->VideoProcessorSetStreamFrameFormat(s.processor.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{}; rgb.RGB_Range = 0;
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE yuv{}; yuv.YCbCr_Matrix = 1; yuv.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    s.video_context->VideoProcessorSetStreamColorSpace(s.processor.Get(), 0, &rgb);
    s.video_context->VideoProcessorSetOutputColorSpace(s.processor.Get(), &yuv);
    UINT reset{}; VF_HR(MFCreateDXGIDeviceManager(&reset, &s.manager));
    VF_HR(s.manager->ResetDevice(device, reset));
    MFT_REGISTER_TYPE_INFO in{MFMediaType_Video, MFVideoFormat_NV12};
    const GUID subtype=codec==2 ? MFVideoFormat_HEVC : MFVideoFormat_H264;
    MFT_REGISTER_TYPE_INFO out{MFMediaType_Video, subtype};
    IMFActivate** activations{}; UINT count{};
    VF_HR(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &in, &out, &activations, &count));
    HRESULT activated = MF_E_TOPO_CODEC_NOT_FOUND;
    for (UINT i = 0; i < count; ++i) {
        if (!s.encoder) activated = activations[i]->ActivateObject(IID_PPV_ARGS(&s.encoder));
        activations[i]->Release();
    }
    CoTaskMemFree(activations);
    if (!s.encoder) return activated;
    ComPtr<IMFAttributes> attrs; VF_HR(s.encoder->GetAttributes(&attrs));
    VF_HR(attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE));
    attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
    VF_HR(s.encoder.As(&s.events));
    s.encoder.As(&s.codec);
    VF_HR(s.encoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(s.manager.Get())));
    const HRESULT ids = s.encoder->GetStreamIDs(1, &s.input_id, 1, &s.output_id);
    if (ids != E_NOTIMPL) VF_HR(ids);
    ComPtr<IMFMediaType> output; VF_HR(MFCreateMediaType(&output));
    VF_HR(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    VF_HR(output->SetGUID(MF_MT_SUBTYPE, subtype));
    VF_HR(output->SetUINT32(MF_MT_AVG_BITRATE, 24000000));
    VF_HR(output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    VF_HR(output->SetUINT32(MF_MT_MPEG2_PROFILE, codec==2 ? 1 : eAVEncH264VProfile_Main));
    VF_HR(MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height));
    VF_HR(MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, fps, 1));
    VF_HR(MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    VF_HR(s.encoder->SetOutputType(s.output_id, output.Get(), 0));
    ComPtr<IMFMediaType> input; VF_HR(MFCreateMediaType(&input));
    VF_HR(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    VF_HR(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12));
    VF_HR(input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    VF_HR(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height));
    VF_HR(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps, 1));
    VF_HR(MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    VF_HR(s.encoder->SetInputType(s.input_id, input.Get(), 0));
    if (s.codec) {
        VARIANT value; VariantInit(&value); value.vt = VT_BOOL; value.boolVal = VARIANT_TRUE;
        s.codec->SetValue(&CODECAPI_AVLowLatencyMode, &value);
        value.vt = VT_UI4; value.ulVal = 0;
        s.codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &value);
        value.ulVal = fps * 2; s.codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
    }
    VF_HR(s.encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
    VF_HR(s.encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
    s.width = width; s.height = height; s.fps = fps;
    return S_OK;
}
HRESULT HardwareEncoder::submit(ID3D11Texture2D* bgra, std::int64_t timestamp, bool keyframe) {
    auto& s = *impl_;
    if (!s.encoder || !bgra || timestamp < 0) return E_INVALIDARG;
    VF_HR(s.event_poll());
    if (!s.input_ready) return S_FALSE;
    D3D11_TEXTURE2D_DESC source{}; bgra->GetDesc(&source);
    if (source.Width != s.width || source.Height != s.height || source.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return E_INVALIDARG;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width=s.width; desc.Height=s.height; desc.MipLevels=1; desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_NV12; desc.SampleDesc.Count=1;
    desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> nv12; VF_HR(s.device->CreateTexture2D(&desc, nullptr, &nv12));
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC iv{}; iv.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorInputView> input;
    VF_HR(s.video->CreateVideoProcessorInputView(bgra, s.enumeration.Get(), &iv, &input));
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov{}; ov.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorOutputView> output;
    VF_HR(s.video->CreateVideoProcessorOutputView(nv12.Get(), s.enumeration.Get(), &ov, &output));
    D3D11_VIDEO_PROCESSOR_STREAM stream{}; stream.Enable=TRUE; stream.pInputSurface=input.Get();
    VF_HR(s.video_context->VideoProcessorBlt(s.processor.Get(), output.Get(), 0, 1, &stream));
    s.context->Flush();
    ComPtr<IMFMediaBuffer> buffer;
    VF_HR(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12.Get(), 0, FALSE, &buffer));
    ComPtr<IMFSample> sample; VF_HR(MFCreateSample(&sample));
    VF_HR(sample->AddBuffer(buffer.Get()));
    VF_HR(sample->SetSampleTime(timestamp)); VF_HR(sample->SetSampleDuration(10000000 / s.fps));
    if (keyframe && s.codec) {
        VARIANT value; VariantInit(&value); value.vt=VT_UI4; value.ulVal=1;
        VF_HR(s.codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &value));
    }
    const HRESULT result=s.encoder->ProcessInput(s.input_id, sample.Get(), 0);
    if (result == MF_E_NOTACCEPTING) { s.input_ready=0; return S_FALSE; }
    VF_HR(result); --s.input_ready;
    return S_OK;
}
HRESULT HardwareEncoder::poll(std::vector<EncodedFrame>& frames) {
    auto& s=*impl_; if (!s.encoder) return E_UNEXPECTED;
    VF_HR(s.event_poll());
    while (s.output_ready) {
        MFT_OUTPUT_STREAM_INFO info{}; VF_HR(s.encoder->GetOutputStreamInfo(s.output_id, &info));
        ComPtr<IMFSample> allocated;
        if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
            VF_HR(MFCreateSample(&allocated));
            ComPtr<IMFMediaBuffer> buffer;
            VF_HR(MFCreateAlignedMemoryBuffer(info.cbSize, info.cbAlignment ? info.cbAlignment-1 : 0, &buffer));
            VF_HR(allocated->AddBuffer(buffer.Get()));
        }
        MFT_OUTPUT_DATA_BUFFER output{}; output.dwStreamID=s.output_id; output.pSample=allocated.Get();
        DWORD status{}; const HRESULT result=s.encoder->ProcessOutput(0, 1, &output, &status);
        if (output.pEvents) output.pEvents->Release();
        ComPtr<IMFSample> sample;
        if (output.pSample == allocated.Get()) sample=allocated;
        else sample.Attach(output.pSample);
        --s.output_ready;
        if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
            ComPtr<IMFMediaType> changed;
            VF_HR(s.encoder->GetOutputAvailableType(s.output_id, 0, &changed));
            VF_HR(s.encoder->SetOutputType(s.output_id, changed.Get(), 0));
            continue;
        }
        if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) continue;
        VF_HR(result); if (!sample) return E_FAIL;
        EncodedFrame frame; VF_HR(sample->GetSampleTime(&frame.timestamp));
        UINT32 clean{}; sample->GetUINT32(MFSampleExtension_CleanPoint, &clean); frame.keyframe=clean != 0;
        ComPtr<IMFMediaBuffer> buffer; VF_HR(sample->ConvertToContiguousBuffer(&buffer));
        BYTE* bytes{}; DWORD length{}; VF_HR(buffer->Lock(&bytes, nullptr, &length));
        frame.bytes.assign(bytes, bytes+length); buffer->Unlock();
        frames.push_back(std::move(frame));
    }
    return S_OK;
}
}
