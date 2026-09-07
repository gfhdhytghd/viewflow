#include "keyboard_clock_bounds.h"
#include <cassert>
#include <limits>

using viewflow::windows_preview::KeyboardClockBounds;

int main() {
  constexpr uint64_t frequency = 1'000'000'000;
  KeyboardClockBounds bounds;
  assert(!bounds.deadline(16, 16, 10, frequency));
  bounds.observe(100, 0, 102, frequency);
  bounds.observe(200, 0, 202, frequency); // Retain the tighter old-tick witness.
  bounds.observe(300, 16, 302, frequency);
  assert(bounds.deadline(16, 32, 400, frequency) == 199 + bounds.budget_ns);
  assert(!bounds.deadline(0, 16, 400, frequency)); // Same/later tick cannot grant.
  assert(!bounds.deadline(48, 32, 400, frequency)); // Future timestamp.
  assert(!bounds.deadline(16, 32, 299, frequency)); // Backwards QPC.
  assert(!bounds.deadline(16, 32, 400, frequency + 1));
  assert(!bounds.deadline(16, 32, 199 + bounds.budget_ns, frequency));
  bounds.observe(500, 0xfffffff0u, 502, frequency); // Backwards tick resets.
  assert(!bounds.deadline(0xfffffff0u, 0xfffffff0u, 503, frequency));
  bounds.observe(600, 0, 602, frequency); // Ordinary 32-bit wrap is supported.
  assert(bounds.deadline(0, 0, 603, frequency) == 499 + bounds.budget_ns);
  bounds.observe(0, 1, 2, frequency);
  assert(!bounds.deadline(16, 16, 700, frequency));

  // Exhaustively vary message phase, queue age and sampler phase. Every
  // returned absolute deadline must be no later than the real original event
  // plus the unchanged budget, including messages that precede later samples.
  for (uint64_t event_ms = 1; event_ms < 100; ++event_ms) {
    for (uint64_t queued_ms = 0; queued_ms < 50; ++queued_ms) {
      for (uint64_t phase = 0; phase < 5; ++phase) {
        KeyboardClockBounds clock;
        const uint64_t now_ms = event_ms + queued_ms;
        for (uint64_t sample_ms = phase; sample_ms <= now_ms; sample_ms += 5)
          clock.observe(1'000'000 + sample_ms * 1'000'000,
              uint32_t(sample_ms / 16 * 16), 1'000'001 + sample_ms * 1'000'000, frequency);
        auto result = clock.deadline(uint32_t(event_ms / 16 * 16),
            uint32_t(now_ms / 16 * 16), 1'000'002 + now_ms * 1'000'000, frequency);
        if (result) {
          assert(*result <= 1'000'001 + event_ms * 1'000'000 + clock.budget_ns);
          assert(*result > 1'000'002 + now_ms * 1'000'000);
        }
      }
    }
  }
  // Ring eviction cannot turn a later/same-tick sample into an earlier one.
  bounds.reset();
  for (uint32_t i = 0; i < 100; ++i) bounds.observe(1000 + i * 10, i, 1001 + i * 10, frequency);
  assert(!bounds.deadline(2, 99, 2000, frequency));
  assert(bounds.deadline(99, 99, 2000, frequency) == 1979 + bounds.budget_ns);
}
