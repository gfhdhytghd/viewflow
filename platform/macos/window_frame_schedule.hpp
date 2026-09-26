#pragma once

#include "../reverse-common/wire.hpp"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <map>
#include <span>
#include <tuple>
#include <vector>

namespace viewflow::macos {

// A short scheduling preference after actual key presses, never a stream
// validity deadline. Ordinary video keeps one in-flight slot; changed popup
// pixels can use the second slot without waiting for the next ordinary tick.
class InputPriority {
    double last_key_{-1.};
    double last_popup_submit_{-1.};
public:
    void key(double now) { last_key_=now; }
    bool active(double now) const { return last_key_>=0. && now-last_key_<.350; }
    double key_age(double now) const { return last_key_<0.?-1.:now-last_key_; }
    double discovery_period(double now) const { return active(now)?1./120.:1./60.; }
    unsigned queue_limit(double now,bool changed_popup) const { return active(now)&&!changed_popup?1u:2u; }
    bool urgent(double now,bool changed_popup,unsigned fps) const {
        return active(now) && changed_popup && (last_popup_submit_<0. || now-last_popup_submit_>=1./std::max(1u,fps));
    }
    void submitted_popup(double now) { last_popup_submit_=now; }
};

class FrameCadence {
    double next_{};
public:
    bool due(double now) const { return now >= next_; }
    void restart(double now,unsigned fps) { next_=now+1./std::max(1u,fps); }
    double wait(double now) const { return std::clamp(next_ - now, 0., .005); }
    void advance(double now, unsigned fps) {
        const double period = 1. / fps;
        if (next_ == 0) next_ = now;
        next_ += (std::floor(std::max(0., now - next_) / period) + 1.) * period;
    }
};

// Capture callbacks and metadata changes are intentionally independent.  A
// candidate only becomes the comparison baseline after its complete encoded
// record has entered the bounded output queue; a failed/backpressured attempt
// must remain eligible for the next tick.
class FrameSchedule {
public:
    using Versions = std::map<std::uint64_t, std::uint64_t>;

    bool refresh_due(double now) const { return submitted_ && now - submitted_at_ >= 1.; }

    bool needs_frame(const std::vector<reverse::Tile>& tiles, const Versions& versions,
        unsigned width, unsigned height, double now) const {
        if (!submitted_ || width != width_ || height != height_ || versions != versions_ || tiles.size() != tiles_.size()) return true;
        if (refresh_due(now)) return true; // Keep a static decoder chain refreshed without a frame-age cutoff.
        return !std::equal(tiles.begin(), tiles.end(), tiles_.begin(), [](const auto& a, const auto& b) {
            return std::tie(a.id, a.owner, a.x, a.y, a.width, a.height, a.atlas_x, a.atlas_y,
                a.title, a.flags, a.geometry_ack, a.grab_x, a.grab_y, a.body_x, a.body_y, a.body_width, a.body_height, a.logical_width, a.logical_height, a.pixel_scale, a.resident_x, a.resident_y, a.resident_width, a.resident_height) ==
                std::tie(b.id, b.owner, b.x, b.y, b.width, b.height, b.atlas_x, b.atlas_y,
                b.title, b.flags, b.geometry_ack, b.grab_x, b.grab_y, b.body_x, b.body_y, b.body_width, b.body_height, b.logical_width, b.logical_height, b.pixel_scale, b.resident_x, b.resident_y, b.resident_width, b.resident_height);
        });
    }

    void submitted(std::vector<reverse::Tile> tiles, Versions versions, unsigned width, unsigned height, double now) {
        tiles_ = std::move(tiles); versions_ = std::move(versions); width_ = width; height_ = height;
        submitted_at_ = now; submitted_ = true;
    }

private:
    std::vector<reverse::Tile> tiles_;
    Versions versions_;
    unsigned width_{}, height_{};
    double submitted_at_{};
    bool submitted_{};
};

// The alpha plane remains exact and independently decodable.  This merely
// avoids rebuilding its RLE representation when new color pixels carry the
// same alpha bytes; dimensions remain part of the identity.
class ExactAlphaCache {
public:
    const std::vector<std::uint8_t>& encode(std::span<const std::uint8_t> alpha, unsigned width, unsigned height) {
        if (encoded_.empty() || width != width_ || height != height_ || !std::equal(alpha.begin(), alpha.end(), raw_.begin(), raw_.end())) {
            raw_.assign(alpha.begin(), alpha.end());
            encoded_ = reverse::encode_alpha(raw_);
            width_ = width; height_ = height;
        }
        return encoded_;
    }

private:
    std::vector<std::uint8_t> raw_, encoded_;
    unsigned width_{}, height_{};
};

}
