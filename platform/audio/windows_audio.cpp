#define NOMINMAX
#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <tlhelp32.h>
#include <wrl.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <io.h>
#include <fcntl.h>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <cmath>
using Microsoft::WRL::ComPtr;
static std::atomic<bool> stopped{false};
static void check(HRESULT hr, const char* what) {
    if (FAILED(hr)) throw std::runtime_error(std::string(what) + ": " + std::to_string(static_cast<unsigned long>(hr)));
}
static BOOL WINAPI control(DWORD) { stopped = true; return TRUE; }
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
static WAVEFORMATEX pcm_format() {
    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 2;
    format.nSamplesPerSec = 48000; format.wBitsPerSample = 16;
    format.nBlockAlign = 4; format.nAvgBytesPerSec = 192000;
    return format;
}
static bool parent_alive() {
    DWORD available = 0;
    return PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), nullptr, 0, nullptr, &available, nullptr) != FALSE;
}
class Activation final : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IActivateAudioInterfaceCompletionHandler, Microsoft::WRL::FtmBase> {
public:
    Handle event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    HRESULT result = E_PENDING;
    ComPtr<IAudioClient> client;
    HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation* operation) override {
        ComPtr<IUnknown> object;
        HRESULT activated = E_FAIL;
        result = operation->GetActivateResult(&activated, &object);
        if (SUCCEEDED(result)) result = activated;
        if (SUCCEEDED(result)) result = object.As(&client);
        SetEvent(event.value);
        return S_OK;
    }
};
static ComPtr<IAudioClient> process_capture(DWORD pid, bool exclude) {
    auto completion = Microsoft::WRL::Make<Activation>();
    AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
    parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    parameters.ProcessLoopbackParams.TargetProcessId = pid;
    parameters.ProcessLoopbackParams.ProcessLoopbackMode = exclude
        ? PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE : PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT property{};
    property.vt = VT_BLOB; property.blob.cbSize = sizeof(parameters);
    property.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    check(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
        &property, completion.Get(), &operation), "activate process loopback");
    if (WaitForSingleObject(completion->event.value, 5000) != WAIT_OBJECT_0)
        throw std::runtime_error("audio activation timeout");
    check(completion->result, "process loopback activation");
    return completion->client;
}
static ComPtr<IMMDevice> default_output() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)), "audio devices");
    ComPtr<IMMDevice> device;
    check(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device), "default audio output");
    return device;
}
static int playback() {
    auto device = default_output();
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client), "playback client");
    auto format = pcm_format();
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 200000, 0, &format, nullptr), "playback format");
    ComPtr<IAudioRenderClient> render;
    check(client->GetService(IID_PPV_ARGS(&render)), "audio renderer");
    UINT32 capacity = 0; check(client->GetBufferSize(&capacity), "playback capacity");
    check(client->Start(), "start playback");
    unsigned char block[960];
    while (!stopped) {
        size_t offset = 0;
        while (offset < sizeof(block)) {
            const int count = _read(_fileno(stdin), block + offset, static_cast<unsigned>(sizeof(block) - offset));
            if (count <= 0) { stopped = true; break; }
            offset += count;
        }
        if (stopped) break;
        unsigned frame = 0;
        while (frame < 240 && !stopped) {
            UINT32 padding = 0; check(client->GetCurrentPadding(&padding), "playback padding");
            const UINT32 count = std::min<UINT32>(capacity - padding, 240 - frame);
            if (!count) { Sleep(2); continue; }
            BYTE* data = nullptr; check(render->GetBuffer(count, &data), "playback buffer");
            memcpy(data, block + frame * 4, count * 4);
            check(render->ReleaseBuffer(count, 0), "playback submit");
            frame += count;
        }
    }
    client->Stop(); return 0;
}

// Suppression is explicitly optional until the VM acceptance probe confirms
// whether its audio engine's process-loopback tap is before session muting.
// The shipping mode controller must not select an unverified suppression path.
static int capture(DWORD pid, bool system) {
    auto client = process_capture(pid, system);
    auto format = pcm_format();
    Handle ready{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK |
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
        0, 0, &format, nullptr), "capture PCM format");
    check(client->SetEventHandle(ready.value), "capture event");
    ComPtr<IAudioCaptureClient> capture;
    check(client->GetService(IID_PPV_ARGS(&capture)), "capture client");
    check(client->Start(), "start audio capture");
    while (!stopped && parent_alive()) {
        if (WaitForSingleObject(ready.value, 100) != WAIT_OBJECT_0) continue;
        UINT32 size = 0;
        check(capture->GetNextPacketSize(&size), "capture packet size");
        while (size && !stopped) {
            BYTE* data = nullptr; UINT32 frames = 0; DWORD flags = 0;
            check(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr), "capture packet");
            std::vector<BYTE> bytes(frames * 4, 0);
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) memcpy(bytes.data(), data, bytes.size());
            check(capture->ReleaseBuffer(frames), "capture release");
            size_t offset = 0;
            while (offset < bytes.size()) {
                const int count = _write(_fileno(stdout), bytes.data() + offset, static_cast<unsigned>(bytes.size() - offset));
                if (count <= 0) { stopped = true; break; }
                offset += count;
            }
            check(capture->GetNextPacketSize(&size), "next capture packet");
        }
    }
    client->Stop(); return 0;
}
// A low-level diagnostic uses only its own newly created render session. It
// never mutes another application or changes the endpoint's master volume.
static int probe_session_mute(bool cable = false) {
    auto device = default_output();
    ComPtr<IAudioClient> output;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &output), "probe output");
    auto format = pcm_format();
    GUID session{}; check(CoCreateGuid(&session), "probe session");
    check(output->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
        200000, 0, &format, &session), "probe output format");
    ComPtr<IAudioRenderClient> render;
    check(output->GetService(IID_PPV_ARGS(&render)), "probe render");
    ComPtr<ISimpleAudioVolume> volume;
    check(output->GetService(IID_PPV_ARGS(&volume)), "probe session volume");
    ComPtr<IAudioClient> input;
    if (cable) {
        ComPtr<IMMDeviceEnumerator> enumerator;
        check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            IID_PPV_ARGS(&enumerator)), "probe capture devices");
        ComPtr<IMMDevice> recordingDevice;
        check(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &recordingDevice), "probe cable recording endpoint");
        check(recordingDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &input), "probe cable input");
    } else input = process_capture(GetCurrentProcessId(), false);
    check(input->Initialize(AUDCLNT_SHAREMODE_SHARED, (cable ? 0 : AUDCLNT_STREAMFLAGS_LOOPBACK) |
        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, 0, 0, &format, nullptr), "probe capture format");
    ComPtr<IAudioCaptureClient> reader;
    check(input->GetService(IID_PPV_ARGS(&reader)), "probe reader");
    UINT32 capacity = 0; check(output->GetBufferSize(&capacity), "probe buffer size");
    check(input->Start(), "probe input start"); check(output->Start(), "probe output start");
    unsigned peak[2]{}; unsigned long long frame = 0;
    for (unsigned phase = 0; phase < 2; ++phase) {
        check(volume->SetMute(phase == 1, nullptr), "probe mute own session");
        ULONGLONG start = GetTickCount64();
        while (GetTickCount64() - start < 600) {
            UINT32 padding = 0; check(output->GetCurrentPadding(&padding), "probe padding");
            UINT32 frames = capacity - padding;
            if (frames) {
                BYTE* bytes = nullptr; check(render->GetBuffer(frames, &bytes), "probe output buffer");
                auto* samples = reinterpret_cast<short*>(bytes);
                for (UINT32 n = 0; n < frames; ++n, ++frame) {
                    short value = static_cast<short>(32 * sin(frame * 6.283185307179586 * 440 / 48000));
                    samples[n * 2] = value; samples[n * 2 + 1] = value;
                }
                check(render->ReleaseBuffer(frames, 0), "probe render submit");
            }
            UINT32 packet = 0; check(reader->GetNextPacketSize(&packet), "probe packet size");
            while (packet) {
                BYTE* bytes = nullptr; UINT32 framesRead = 0; DWORD flags = 0;
                check(reader->GetBuffer(&bytes, &framesRead, &flags, nullptr, nullptr), "probe capture read");
                if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && GetTickCount64() - start > 250) {
                    auto* samples = reinterpret_cast<short*>(bytes);
                    for (UINT32 n = 0; n < framesRead * 2; ++n)
                        peak[phase] = std::max(peak[phase], static_cast<unsigned>(abs(samples[n])));
                }
                check(reader->ReleaseBuffer(framesRead), "probe capture release");
                check(reader->GetNextPacketSize(&packet), "probe next packet");
            }
            Sleep(2);
        }
    }
    volume->SetMute(FALSE, nullptr); output->Stop(); input->Stop();
    printf("{\"unmuted_peak\":%u,\"muted_peak\":%u}\n", peak[0], peak[1]);
    // One LSB of dither after muting is not retained audio. Require a
    // meaningful fraction of the known tone for a suppression-path success.
    return peak[0] >= 16 && (cable || peak[1] * 2 >= peak[0]) ? 0 : 3;
}
int main(int argc, char** argv) {
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    SetConsoleCtrlHandler(control, TRUE);
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        fprintf(stderr, "viewflow-audio playback | capture --scope application --pid PID | capture --scope system --exclude-pid VIEWFLOW_PID\n"); return 0;
    }
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    int result = 1;
    try {
        check(initialized, "COM");
        if (argc == 2 && !strcmp(argv[1], "--probe-cable")) result = probe_session_mute(true);
        else if (argc == 2 && !strcmp(argv[1], "--probe-session-mute")) result = probe_session_mute();
        else if (argc == 2 && !strcmp(argv[1], "playback")) result = playback();
        else if (argc == 6 && !strcmp(argv[1], "capture") && !strcmp(argv[2], "--scope")) {
            bool system = !strcmp(argv[3], "system");
            if ((!system && strcmp(argv[3], "application")) || strcmp(argv[4], system ? "--exclude-pid" : "--pid"))
                throw std::runtime_error("invalid capture arguments");
            DWORD pid = static_cast<DWORD>(strtoul(argv[5], nullptr, 10));
            if (!pid && system) pid = GetCurrentProcessId();
            if (!pid) throw std::runtime_error("invalid capture process");
            result = capture(pid, system);
        } else throw std::runtime_error("invalid arguments; use --help");
    } catch (const std::exception& error) { fprintf(stderr, "audio: %s\n", error.what()); }
    if (SUCCEEDED(initialized)) CoUninitialize();
    return result;
}
