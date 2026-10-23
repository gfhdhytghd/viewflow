#include "compressed_pipe_reader.h"
#include "vfgp_parser.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using viewflow::windows_preview::CompressedPipeReader;

static bool pipe(HANDLE *read, HANDLE *write) {
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
  return CreatePipe(read, write, &attributes, 0) != FALSE;
}
static bool wait_ready(CompressedPipeReader const &reader) {
  return WaitForSingleObject(reader.ready_event(), 1000) == WAIT_OBJECT_0;
}
static bool wait_read_started(CompressedPipeReader const &reader) {
  return WaitForSingleObject(reader.read_started_event(), 1000) == WAIT_OBJECT_0;
}
static bool wait_pending_io(CompressedPipeReader const &reader) {
  for (int i = 0; i != 1000; ++i) {
    BOOL pending{};
    if (GetThreadIOPendingFlag(reader.worker_thread_for_test(), &pending) && pending)
      return true;
    Sleep(1);
  }
  return false;
}

int main() {
  // Destructor must cancel a reader blocked in synchronous ReadFile.
  HANDLE read{}, write{};
  if (!pipe(&read, &write)) return 1;
  {
    CompressedPipeReader reader(read);
    if (!wait_read_started(reader) || !wait_pending_io(reader)) return 11;
  }
  CloseHandle(read); CloseHandle(write);

  // A full one-slot handoff must also stop without requiring a consumer.
  if (!pipe(&read, &write)) return 2;
  uint8_t byte = 0x42; DWORD written{};
  if (!WriteFile(write, &byte, 1, &written, nullptr) || written != 1) return 3;
  { CompressedPipeReader reader(read); if (!wait_ready(reader)) return 4; }
  CloseHandle(read); CloseHandle(write);

  // EOF follows the final exact chunk; a partial VFGP is rejected only by the
  // UI-thread parser at EOF, not silently discarded by the reader.
  if (!pipe(&read, &write)) return 5;
  std::array<uint8_t, 7> partial{'V','F','G','P',1,0,0};
  if (!WriteFile(write, partial.data(), DWORD(partial.size()), &written, nullptr) ||
      written != partial.size()) return 6;
  CloseHandle(write);
  {
    CompressedPipeReader reader(read);
    std::array<uint8_t, CompressedPipeReader::chunk_bytes> bytes{}; DWORD count{};
    uint64_t read_completed{};
    if (!wait_ready(reader) || !reader.take(&bytes, &count, &read_completed) || count != partial.size())
      return 7;
    LARGE_INTEGER taken{};
    if (!QueryPerformanceCounter(&taken) || !read_completed ||
        read_completed > static_cast<uint64_t>(taken.QuadPart)) return 13;
    viewflow::vfgp::Parser parser; std::vector<viewflow::vfgp::Frame> frames;
    if (!parser.Push({bytes.data(), count}, &frames) || parser.Finish()) return 8;
    DWORD error{};
    if (!wait_ready(reader) || !reader.terminal(&error) || error != ERROR_SUCCESS) return 9;
  }
  CloseHandle(read);

  // Force cancellation exactly before ReadFile, then allow it to enter the
  // blocked call after the first cancellation has necessarily missed it.
  if (!pipe(&read, &write)) return 12;
  {
    auto reader = std::make_unique<CompressedPipeReader>(read, true);
    CompressedPipeReader *raw = reader.get();
    if (WaitForSingleObject(raw->before_read_event_for_test(), 1000) != WAIT_OBJECT_0)
      return 13;
    HANDLE stop = raw->stop_event_for_test();
    HANDLE permit = raw->permit_read_event_for_test();
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::thread destroyer([&] { reader.reset(); SetEvent(done); });
    bool stopped = WaitForSingleObject(stop, 1000) == WAIT_OBJECT_0;
    SetEvent(permit); // barrier keeps this handle open until the worker leaves it
    bool joined = WaitForSingleObject(done, 2000) == WAIT_OBJECT_0;
    destroyer.join();
    CloseHandle(done);
    if (!stopped) return 14;
    if (!joined) return 15;
  }
  CloseHandle(read); CloseHandle(write);

  // Repeated immediate destruction exercises the pre-ReadFile cancellation
  // window which formerly could leave an infinite join.
  for (int i = 0; i != 128; ++i) {
    if (!pipe(&read, &write)) return 16;
    { CompressedPipeReader reader(read); }
    CloseHandle(read); CloseHandle(write);
  }
  std::cout << "PASS compressed pipe blocked/full/EOF-partial/early-stop" << std::endl;
  return 0;
}
