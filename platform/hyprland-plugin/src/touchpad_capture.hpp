// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <filesystem>
#include <memory>
#include <linux/input.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cerrno>
#include <string>

namespace viewflow::hyprland {

struct TouchpadSnapshot {
  struct Contact { std::uint32_t id{}, x{}, y{}; int pressure{5}, major{80}, minor{80}, orientation{}; };
  std::uint32_t width{}, height{}, count{};
  std::array<Contact, 5> contacts{};
};

// evdev type-B slot tracking; independent of libinput's recognized gestures.
// An empty snapshot releases every remote contact after SYN_DROPPED or overflow.
class TouchpadSlots {
public:
  struct Slot { int id = -1, x{}, y{}, tool{}, pressure{5}, major{80}, minor{80}, orientation{}; };
  std::array<Slot, 32> slots{};
  int selected{};
  bool dropped{};
  input_absinfo x{}, y{};

  void event(unsigned type, unsigned code, int value) {
    if (type == EV_SYN && code == SYN_DROPPED) { dropped = true; return; }
    if (dropped || type != EV_ABS) return;
    if (code == ABS_MT_SLOT) { selected = value; return; }
    if (selected < 0 || selected >= static_cast<int>(slots.size())) return;
    auto& slot = slots[static_cast<std::size_t>(selected)];
    if (code == ABS_MT_TRACKING_ID) slot.id = value;
    else if (code == ABS_MT_POSITION_X) slot.x = value;
    else if (code == ABS_MT_POSITION_Y) slot.y = value;
    else if (code == ABS_MT_TOOL_TYPE) slot.tool = value;
    else if (code == ABS_MT_PRESSURE) slot.pressure = value;
    else if (code == ABS_MT_TOUCH_MAJOR) slot.major = value;
    else if (code == ABS_MT_TOUCH_MINOR) slot.minor = value;
    else if (code == ABS_MT_ORIENTATION) slot.orientation = value;
  }

  TouchpadSnapshot snapshot() const {
    TouchpadSnapshot out;
    out.width = physical(x.maximum, x);
    out.height = physical(y.maximum, y);
    if (dropped) return out;
    for (const auto& slot : slots) {
      if (slot.id < 0 || slot.tool == MT_TOOL_PALM) continue;
      if (out.count == out.contacts.size()) { out.count = 0; return out; }
      out.contacts[out.count++] = {static_cast<std::uint32_t>(slot.id), physical(slot.x, x), physical(slot.y, y), slot.pressure, slot.major, slot.minor, slot.orientation};
    }
    return out;
  }

private:
  static std::uint32_t physical(int value, const input_absinfo& axis) {
    if (axis.resolution <= 0) return 0;
    return static_cast<std::uint32_t>((static_cast<std::int64_t>(std::clamp(value, axis.minimum, axis.maximum)) - axis.minimum) * 100 / axis.resolution);
  }
};

class TouchpadCapture {
public:
  TouchpadCapture() = default;
  ~TouchpadCapture() { if (m_fd >= 0) ::close(m_fd); }
  TouchpadCapture(const TouchpadCapture&) = delete;
  TouchpadCapture& operator=(const TouchpadCapture&) = delete;

  bool open(const std::string& path) {
    m_fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (m_fd < 0) return false;
    input_absinfo slots{};
    if (::ioctl(m_fd, EVIOCGABS(ABS_MT_POSITION_X), &m_slots.x) < 0 ||
        ::ioctl(m_fd, EVIOCGABS(ABS_MT_POSITION_Y), &m_slots.y) < 0 ||
        ::ioctl(m_fd, EVIOCGABS(ABS_MT_SLOT), &slots) < 0 ||
        slots.minimum != 0 || slots.maximum >= 32 || slots.maximum < 1 ||
        m_slots.x.resolution <= 0 || m_slots.y.resolution <= 0 ||
        m_slots.x.maximum <= m_slots.x.minimum || m_slots.y.maximum <= m_slots.y.minimum) {
      ::close(m_fd); m_fd = -1; return false;
    }
    m_slotCount = slots.maximum + 1;
    m_slots.selected = slots.value;
    const auto dimensions = m_slots.snapshot();
    if (dimensions.width == 0 || dimensions.height == 0 || dimensions.width > 100000 || dimensions.height > 100000) {
      ::close(m_fd); m_fd = -1; return false;
    }
    resync();
    return true;
  }

  bool available() const { return m_fd >= 0; }
  int fd() const { return m_fd; }
  TouchpadSnapshot current() const { return m_slots.snapshot(); }
  static std::unique_ptr<TouchpadCapture> discover() {
    std::error_code error;
    for (const auto& entry : std::filesystem::directory_iterator("/dev/input", error)) {
      if (!entry.path().filename().string().starts_with("event")) continue;
      auto capture = std::make_unique<TouchpadCapture>();
      if (!capture->open(entry.path().string())) continue;
      unsigned long properties{};
      // EVIOCGPROP returns the number of bytes copied (8 here), not just zero.
      if (::ioctl(capture->fd(), EVIOCGPROP(sizeof(properties)), &properties) >= 0 && (properties & (1UL << INPUT_PROP_POINTER))) return capture;
    }
    return {};
  }

  // Read-only: never EVIOCGRAB. The existing capture lease decides whether
  // libinput's local output is suppressed and whether snapshots are forwarded.
  void drain(bool captured, const std::function<void(const TouchpadSnapshot&)>& emit) {
    if (m_fd < 0) return;
    if (captured != m_captured) {
      // Drain old local records before admitting the new remote lease.
      m_captured = captured;
      m_start = captured;
    }
    input_event events[64];
    for (unsigned batch = 0; batch < 64; ++batch) {
      const auto bytes = ::read(m_fd, events, sizeof(events));
      if (bytes < 0 && errno == EINTR) continue;
      if (bytes < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        if (m_start) { m_start = false; emit(m_slots.snapshot()); }
        break;
      }
      if (bytes <= 0) {
        if (captured) { auto empty = m_slots.snapshot(); empty.count = 0; emit(empty); }
        ::close(m_fd); m_fd = -1; break;
      }
      const auto count = static_cast<std::size_t>(bytes) / sizeof(input_event);
      for (std::size_t i = 0; i < count; ++i) {
        const auto& event = events[i];
        m_slots.event(event.type, event.code, event.value);
        if (event.type == EV_SYN && event.code == SYN_REPORT) {
          if (m_slots.dropped) {
            if (captured && !m_start) emit(m_slots.snapshot());
            resync();
          }
          if (captured && !m_start) emit(m_slots.snapshot());
        }
      }
    }
  }

private:
  void resync() {
    for (auto& slot : m_slots.slots) slot = {};
    bool complete = true;
    for (const auto code : {ABS_MT_TRACKING_ID, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TOOL_TYPE, ABS_MT_PRESSURE, ABS_MT_TOUCH_MAJOR, ABS_MT_TOUCH_MINOR, ABS_MT_ORIENTATION}) {
      std::array<int, 33> values{}; values[0] = code;
      if (::ioctl(m_fd, EVIOCGMTSLOTS(static_cast<unsigned>(static_cast<std::size_t>(m_slotCount + 1) * sizeof(int))), values.data()) < 0) {
        if (code == ABS_MT_TRACKING_ID || code == ABS_MT_POSITION_X || code == ABS_MT_POSITION_Y) complete = false;
        continue;
      }
      for (int i = 0; i < m_slotCount; ++i) {
        m_slots.selected = i;
        m_slots.dropped = false;
        m_slots.event(EV_ABS, static_cast<unsigned>(code), values[static_cast<std::size_t>(i + 1)]);
      }
    }
    input_absinfo selected{};
    if (::ioctl(m_fd, EVIOCGABS(ABS_MT_SLOT), &selected) == 0) m_slots.selected = selected.value;
    else complete = false;
    m_slots.dropped = !complete;
  }

  int m_fd = -1, m_slotCount{};
  TouchpadSlots m_slots;
  bool m_captured{}, m_start{};
};

} // namespace viewflow::hyprland
