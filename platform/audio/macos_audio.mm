// Native Core Audio process taps and default-device playback. stdout/stdin use
// stereo 48 kHz signed 16-bit little-endian PCM; capture stdin is a lifetime pipe.
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <memory>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <poll.h>
#include <set>
#include <signal.h>
#include <stdexcept>
#include <unistd.h>
#include <libproc.h>
#include <vector>

static std::atomic<bool> stopped{false};
static void check(OSStatus status, const char* operation) {
    if (status != noErr) throw std::runtime_error(std::string(operation) + ": " + std::to_string(status));
}
static void stop_signal(int) { stopped = true; }
template <typename T> static T property(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    T value{}; UInt32 size = sizeof(value);
    check(AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value), "audio property");
    return value;
}
static NSArray<NSNumber*>* processes(const std::set<pid_t>& roots, bool system) {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    check(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size), "audio process list");
    std::vector<AudioObjectID> objects(size / sizeof(AudioObjectID));
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, objects.data()), "audio processes");
    NSMutableArray<NSNumber*>* result = [NSMutableArray array];
    for (AudioObjectID object : objects) {
        pid_t pid;
        try { pid = property<pid_t>(object, kAudioProcessPropertyPID); } catch (...) { continue; }
        char path[PROC_PIDPATHINFO_MAXSIZE]{};
        proc_pidpath(pid, path, sizeof(path));
        const char* name = strrchr(path, '/'); name = name ? name + 1 : path;
        // Every playback helper is excluded, including another connection's
        // process. Received audio must never be fed back into the network.
        const bool ours = std::strcmp(name, "viewflow-audio") == 0 || pid == getpid();
        if (system) { if (ours) [result addObject:@(object)]; continue; }
        if (ours) continue;
        for (unsigned depth = 0; pid > 1 && depth < 64; ++depth) {
            if (roots.contains(pid)) { [result addObject:@(object)]; break; }
            proc_bsdinfo info{};
            if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) break;
            if (pid == static_cast<pid_t>(info.pbi_ppid)) break;
            pid = static_cast<pid_t>(info.pbi_ppid);
        }
    }
    return result;
}

static int capture(bool system, const std::set<pid_t>& roots) {
    AudioObjectID tap = kAudioObjectUnknown, aggregate = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    dispatch_queue_t queue = dispatch_queue_create("org.viewflow.audio.convert", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t ioQueue = dispatch_queue_create("org.viewflow.audio.tap", DISPATCH_QUEUE_SERIAL);
    bool failed = false;
    auto pending = std::make_shared<std::atomic<unsigned>>(0);
    try {
        CATapDescription* description = system ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:processes(roots, true)]
            : [[CATapDescription alloc] initStereoMixdownOfProcesses:processes(roots, false)];
        description.name = @"Viewflow audio";
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;
        check(AudioHardwareCreateProcessTap(description, &tap), "create process tap");
        const auto format = property<AudioStreamBasicDescription>(tap, kAudioTapPropertyFormat);
        AVAudioFormat* inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&format];
        AVAudioFormat* outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
            sampleRate:48000 channels:2 interleaved:YES];
        AVAudioConverter* converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
        if (!converter || !format.mBytesPerFrame) throw std::runtime_error("unsupported tap PCM format");
        const auto outputDevice = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        NSString* outputUID = CFBridgingRelease(property<CFStringRef>(outputDevice, kAudioDevicePropertyDeviceUID));
        NSDictionary* specification = @{
            @kAudioAggregateDeviceNameKey: @"Viewflow audio",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapAutoStartKey: @YES,
            @kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: outputUID}],
            @kAudioAggregateDeviceTapListKey: @[@{
                @kAudioSubTapUIDKey: description.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey: @YES
            }]
        };
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)specification, &aggregate), "create tap device");
        check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, ioQueue,
            ^(const AudioTimeStamp*, const AudioBufferList* data, const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*) {
                if (stopped || !data || !data->mNumberBuffers || pending->load() >= 8) return;
                const auto frames = data->mBuffers[0].mDataByteSize / format.mBytesPerFrame;
                if (!frames) return;
                AVAudioPCMBuffer* input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:frames];
                input.frameLength = frames;
                AudioBufferList* copy = input.mutableAudioBufferList;
                if (copy->mNumberBuffers != data->mNumberBuffers) return;
                for (UInt32 i = 0; i < data->mNumberBuffers; ++i) {
                    if (data->mBuffers[i].mDataByteSize > copy->mBuffers[i].mDataByteSize) return;
                    memcpy(copy->mBuffers[i].mData, data->mBuffers[i].mData, data->mBuffers[i].mDataByteSize);
                }
                ++*pending;
                dispatch_async(queue, ^{
                    @autoreleasepool {
                        AVAudioPCMBuffer* output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat
                            frameCapacity:static_cast<AVAudioFrameCount>(frames * 48000.0 / format.mSampleRate + 64)];
                        __block bool supplied = false;
                        NSError* error = nil;
                        [converter convertToBuffer:output error:&error withInputFromBlock:
                            ^AVAudioBuffer*(AVAudioPacketCount, AVAudioConverterInputStatus* status) {
                                if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
                                supplied = true; *status = AVAudioConverterInputStatus_HaveData; return input;
                            }];
                        if (error) { fprintf(stderr, "audio conversion: %s\n", error.localizedDescription.UTF8String); stopped = true; }
                        else {
                            const auto& bytes = output.audioBufferList->mBuffers[0];
                            size_t offset = 0;
                            while (offset < bytes.mDataByteSize && !stopped) {
                                ssize_t count = write(STDOUT_FILENO, static_cast<const char*>(bytes.mData) + offset, bytes.mDataByteSize - offset);
                                if (count < 0 && errno == EINTR) continue;
                                if (count <= 0) { stopped = true; break; }
                                offset += count;
                            }
                        }
                    }
                    --*pending;
                });
            }), "tap callback");
        check(AudioDeviceStart(aggregate, io), "start tap");
        while (!stopped) {
            pollfd lifetime{STDIN_FILENO, POLLIN | POLLHUP, 0};
            if (poll(&lifetime, 1, 250) > 0) {
                char byte;
                if (read(STDIN_FILENO, &byte, 1) <= 0) break;
            }
            // Refresh exclusions and child audio processes while preserving the
            // tap and converter. No restart on focus or transient silence.
            NSArray<NSNumber*>* updated = processes(roots, system);
            if (![updated isEqualToArray:description.processes]) {
                NSArray<NSNumber*>* previous = description.processes;
                description.processes = updated;
                AudioObjectPropertyAddress address{kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                CFTypeRef value = (__bridge CFTypeRef)description;
                const auto status = AudioObjectSetPropertyData(tap, &address, 0, nullptr, sizeof(value), &value);
                if (status != noErr) {
                    description.processes = previous;
                    fprintf(stderr, "audio process refresh pending: %d\n", static_cast<int>(status));
                }
            }
        }
    } catch (const std::exception& error) {
        fprintf(stderr, "audio capture: %s\n", error.what()); stopped = true; failed = true;
    }
    stopped = true;
    if (io) { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io); }
    dispatch_sync(queue, ^{});
    if (aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(aggregate);
    if (tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap);
    return failed ? 1 : 0;
}

static int playback() {
    AVAudioEngine* engine = [AVAudioEngine new];
    AVAudioPlayerNode* player = [AVAudioPlayerNode new];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    [engine attachNode:player]; [engine connect:player to:engine.mainMixerNode format:format];
    NSError* error = nil;
    if (![engine startAndReturnError:&error]) {
        fprintf(stderr, "audio output: %s\n", error.localizedDescription.UTF8String); return 1;
    }
    [player play];
    dispatch_semaphore_t slots = dispatch_semaphore_create(4);
    int16_t samples[480];
    while (!stopped) {
        size_t offset = 0;
        while (offset < sizeof(samples)) {
            ssize_t count = read(STDIN_FILENO, reinterpret_cast<char*>(samples) + offset, sizeof(samples) - offset);
            if (count < 0 && errno == EINTR && !stopped) continue;
            if (count <= 0) { stopped = true; break; }
            offset += count;
        }
        if (stopped) break;
        if (dispatch_semaphore_wait(slots, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) break;
        AVAudioPCMBuffer* buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:240];
        buffer.frameLength = 240;
        for (unsigned frame = 0; frame < 240; ++frame)
            for (unsigned channel = 0; channel < 2; ++channel)
                buffer.floatChannelData[channel][frame] = samples[frame * 2 + channel] / 32768.0f;
        [player scheduleBuffer:buffer completionHandler:^{ dispatch_semaphore_signal(slots); }];
    }
    [player stop]; [engine stop];
    return 0;
}
int main(int argc, char** argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stop_signal); signal(SIGINT, stop_signal);
        if (argc == 2 && !strcmp(argv[1], "playback")) return playback();
        if (argc >= 4 && !strcmp(argv[1], "capture") && !strcmp(argv[2], "--scope")) {
            bool system = !strcmp(argv[3], "system");
            if (!system && strcmp(argv[3], "application")) return 2;
            std::set<pid_t> pids;
            for (int i = 4; i + 1 < argc; i += 2) {
                if (strcmp(argv[i], "--pid")) return 2;
                int pid = atoi(argv[i + 1]); if (pid <= 0) return 2; pids.insert(pid);
            }
            if (!system && pids.empty()) return 2;
            return capture(system, pids);
        }
        fprintf(stderr, "usage: viewflow-audio playback | capture --scope system|application [--pid PID ...]\n");
        return 2;
    }
}
