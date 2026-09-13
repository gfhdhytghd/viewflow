#include "window_frame_schedule.hpp"

#include <cassert>

using namespace viewflow;

int main() {
    macos::FrameSchedule schedule;
    reverse::Tile tile{1, 0, 10, 20, 64, 32, 0, 0, "first", 0, 0};
    std::vector<reverse::Tile> tiles{tile};
    macos::FrameSchedule::Versions versions{{1, 1}};
    assert(schedule.needs_frame(tiles, versions, 64, 32, 0.));
    // A record that could not enter the output queue never advances state.
    assert(schedule.needs_frame(tiles, versions, 64, 32, .1));
    schedule.submitted(tiles, versions, 64, 32, .1);
    assert(!schedule.needs_frame(tiles, versions, 64, 32, .9));
    assert(!schedule.refresh_due(.9));
    assert(schedule.refresh_due(1.1));
    assert(schedule.needs_frame(tiles, versions, 64, 32, 1.1));
    auto sampled = versions; ++sampled[1];
    assert(schedule.needs_frame(tiles, sampled, 64, 32, .2));
    auto retitled = tiles; retitled[0].title = "second";
    assert(schedule.needs_frame(retitled, versions, 64, 32, .2));
    auto acknowledged = tiles; acknowledged[0].geometry_ack = 5;
    assert(schedule.needs_frame(acknowledged, versions, 64, 32, .2));

    macos::ExactAlphaCache alpha;
    const std::vector<std::uint8_t> first{255, 128, 0, 255};
    const auto& initial = alpha.encode(first, 2, 2);
    const auto same = alpha.encode(first, 2, 2);
    assert(initial == same && reverse::decode_alpha(same, first.size()) == first);
    const auto resized = alpha.encode(first, 1, 4);
    assert(reverse::decode_alpha(resized, first.size()) == first);
    const std::vector<std::uint8_t> changed{255, 127, 0, 255};
    assert(reverse::decode_alpha(alpha.encode(changed, 1, 4), changed.size()) == changed);
    macos::FrameCadence cadence;
    cadence.advance(100., 60);
    for (unsigned tick = 1; tick <= 600; ++tick) {
        const double deadline = 100. + tick / 60.;
        assert(cadence.due(deadline + .001));
        cadence.advance(deadline + .001, 60);
        assert(!cadence.due(deadline + .002));
    }
    // A long pause skips elapsed slots and retains the next cadence deadline.
    cadence.advance(200.001, 60);
    assert(!cadence.due(200.002));
    assert(cadence.due(200.018));
}
