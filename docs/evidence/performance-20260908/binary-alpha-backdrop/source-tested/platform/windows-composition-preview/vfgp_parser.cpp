#include "vfgp_parser.h"
#include <algorithm>
#include <array>
#include <limits>

namespace viewflow::vfgp {
namespace {
uint32_t be32(const uint8_t *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | p[3];
}
uint64_t be64(const uint8_t *p) {
  return (uint64_t(be32(p)) << 32) | be32(p + 4);
}

bool DecodeVfar(std::span<const uint8_t> encoded, uint32_t width,
                uint32_t height, size_t decoded_limit,
                std::vector<uint8_t> *alpha, const char **error) {
  constexpr size_t header = 24;
  if (encoded.size() < header ||
      std::array<uint8_t, 4>{'V', 'F', 'A', 'R'} !=
          std::array<uint8_t, 4>{encoded[0], encoded[1], encoded[2],
                                 encoded[3]} ||
      encoded[4] != 1) {
    *error = "V2 VFAR header";
    return false;
  }
  const uint8_t mode = encoded[5];
  if (mode > 1 || encoded[6] || encoded[7] ||
      be32(encoded.data() + 8) != width ||
      be32(encoded.data() + 12) != height) {
    *error = "V2 VFAR layout";
    return false;
  }
  const uint64_t area = uint64_t(width) * height;
  if (!width || !height || area > decoded_limit ||
      area > (std::numeric_limits<size_t>::max)() ||
      be64(encoded.data() + 16) != area) {
    *error = "V2 VFAR decoded limit";
    return false;
  }
  const auto payload = encoded.subspan(header);
  if (!mode) {
    if (payload.size() != area) {
      *error = "V2 VFAR raw length";
      return false;
    }
    alpha->assign(payload.begin(), payload.end());
    return true;
  }
  alpha->clear();
  alpha->reserve(size_t(area));
  size_t at = 0;
  while (at < payload.size() && alpha->size() < area) {
    const uint8_t control = payload[at++];
    const size_t run = size_t(control & 0x7f) + 1;
    if (run > size_t(area) - alpha->size()) {
      *error = "V2 VFAR run overflow";
      return false;
    }
    if (control & 0x80) {
      if (at == payload.size()) {
        *error = "V2 VFAR truncated run";
        return false;
      }
      alpha->insert(alpha->end(), run, payload[at++]);
    } else {
      if (payload.size() - at < run) {
        *error = "V2 VFAR truncated run";
        return false;
      }
      alpha->insert(alpha->end(), payload.begin() + at,
                    payload.begin() + at + run);
      at += run;
    }
  }
  if (alpha->size() != area || at != payload.size()) {
    *error = "V2 VFAR trailing bytes";
    return false;
  }
  return true;
}
} // namespace

bool Parser::Push(std::span<const uint8_t> in, std::vector<Frame> *out) {
  if (!out || error_)
    return false;
  if (max_ < 40) {
    error_ = "buffer limit";
    return false;
  }
  // Bound the incomplete record, not the OS read: one read can contain several
  // individually valid records. Never accumulate the entire input chunk.
  while (!in.empty()) {
    const size_t take = (std::min)(wanted_ - bytes_.size(), in.size());
    bytes_.insert(bytes_.end(), in.begin(), in.begin() + take);
    in = in.subspan(take);
    if (bytes_.size() < wanted_)
      break;
    if (wanted_ == 40) {
      const auto *p = bytes_.data();
      if (p[0] == 'V' && p[1] == 'F' && p[2] == 'G' && p[3] == 'P' &&
          (p[4] == 6 || p[4] == 9)) {
        const bool rejected = p[4] == 9;
        const auto size = rejected ? rejected_input_bytes : input_recovery_bytes;
        if (!allow_input_recovery_v6_ || !allow_atlas_v5_ || max_ < size ||
            (rejected ? ((p[5] != 1 && p[5] != 2) || p[6] != 1) : (p[5] || p[6])) || p[7] ||
            be32(p + 8) != size || be32(p + 12) || be64(p + 24) || be64(p + 32)) {
          error_ = "V6/V9 disabled or invalid header";
          return false;
        }
        version_ = p[4];
        wanted_ = size;
        continue;
      }
      if (std::array<uint8_t, 4>{'V', 'F', 'G', 'P'} !=
              std::array<uint8_t, 4>{p[0], p[1], p[2], p[3]} ||
          ((p[4] < 1 || p[4] > 5) && p[4] != 7 && p[4] != 8) ||
          ((p[4] == 3 && p[5] != 1) || (p[4] != 3 && p[5])) || p[6] || p[7] ||
          (p[4] != 5 && p[4] != 7 && p[4] != 8 && be32(p + 8) != (p[4] == 4 ? 56 : 40))) {
        error_ = "header";
        return false;
      }
      version_ = p[4];
      if (version_ == 5 || version_ == 7 || version_ == 8) {
        const auto header = be32(p + 8);
        const bool sparse=version_==8;
        if (!allow_atlas_v5_ || (version_==7 && !allow_desktop_v7_) || header>max_ ||
            (sparse ? (header<120 || header>120u+4096u*120u+48u+32768u*28u) :
                (header<(version_==7 ? 160u:112u) ||
                 header>(version_==7 ? 160u+4096u*120u:112u+4096u*64u) ||
                 (version_==7 ? (header-160u)%120u:(header-112u)%64u)))) {
          error_="atlas header or disabled"; return false;
        }
        wanted_ = 112;
        continue;
      }
      if (version_ == 4) {
        if (!allow_deadline_v4_) {
          error_ = "V4 disabled";
          return false;
        }
        if (max_ < 56) {
          error_ = "V4 buffer limit";
          return false;
        }
        wanted_ = 56;
        continue;
      }
      const uint32_t payload = be32(p + 12), c = be32(p + 32), a = be32(p + 36),
                     w = be32(p + 24), h = be32(p + 28);
      const uint64_t area = uint64_t(w) * h, total = uint64_t(payload) + 40;
      if (!w || !h || !c || !a || (version_ == 1 && a != area) ||
          payload != uint64_t(c) + a || total > max_ || area > max_ ||
          total > (std::numeric_limits<size_t>::max)()) {
        error_ = "layout";
        return false;
      }
      const uint64_t id = be64(p + 16);
      if (!id || id <= previous_) {
        error_ = "identity";
        return false;
      }
      wanted_ = size_t(total);
      continue;
    }
    if (version_ == 6 || version_ == 9) {
      auto recovery = version_ == 9 ? DecodeRejectedInput(bytes_) : DecodeInputRecovery(bytes_);
      if (!recovery || recovery->sequence <= previous_recovery_) {
        error_ = "V6/V9 control identity";
        return false;
      }
      Frame record{}; // Explicit control kind; no decoded/encoded picture data.
      record.input_recovery = recovery;
      out->push_back(std::move(record));
      previous_recovery_ = recovery->sequence;
      bytes_.clear();
      wanted_ = header_bytes_ = 40;
      version_ = 0;
      continue;
    }
    if ((version_ == 4 && wanted_ == 56) ||
        ((version_ == 5 || version_ == 7 || version_ == 8) && wanted_ == 112)) {
      const auto *p = bytes_.data();
      const uint32_t payload = be32(p + 12), c = be32(p + 32), a = be32(p + 36),
                     w = be32(p + 24), h = be32(p + 28);
      const auto header = be32(p + 8);
      if ((version_ == 5 || version_ == 7 || version_ == 8) &&
          (be32(p+104)>4096 || (version_==8 ?
             (header < 120u + be32(p+104)*64u + ((be32(p+108)&4) ? 48u+be32(p+104)*56u:0u)
                || ((be32(p+108)&4) && !allow_desktop_v7_)) :
             header != (version_==7 ? 160u+be32(p+104)*120u:112u+be32(p+104)*64u)))) {
        error_="atlas tile count or desktop disabled"; return false;
      }
      const uint64_t area = uint64_t(w) * h, total = uint64_t(payload) + header;
      if (!be64(p + 40) || !be64(p + 48) || !w || !h || !c || !a ||
          payload != uint64_t(c) + a || total > max_ || area > max_ ||
          total > (std::numeric_limits<size_t>::max)()) {
        error_ = "V4 layout";
        return false;
      }
      const uint64_t id = be64(p + 16);
      if (!id || id <= ((version_ == 5 || version_ == 7 || version_ == 8) ? previous_atlas_
                                                         : previous_)) {
        error_ = "identity";
        return false;
      }
      header_bytes_ = header;
      wanted_ = size_t(total);
      continue;
    }
    const auto *p = bytes_.data();
    const uint64_t id = be64(p + 16);
    const uint32_t w = be32(p + 24), h = be32(p + 28), c = be32(p + 32);
    std::optional<AtlasLayout> atlas;
    if (version_ == 5 || version_ == 7 || version_ == 8) {
      const size_t atlas_bytes = 112 + size_t(be32(p + 104)) * 64;
      atlas = DecodeAtlasLayout({p, atlas_bytes}, w, h, version_==8);
      if (!atlas) {
        error_ = version_ == 7 ? "V7 atlas layout" : "V5 atlas layout";
        return false;
      }
      size_t next_at=atlas_bytes;
      if (version_==7 || (version_==8 && (be32(p+108)&4))) {
        const size_t desktop_bytes=48+atlas->tiles.size()*56;
        if(next_at+desktop_bytes>header_bytes_) { error_="desktop extension length"; return false; }
        auto desktop=DecodeDesktopLayout({p+next_at,desktop_bytes},*atlas);
        if(!desktop) { error_="desktop layout"; return false; }
        atlas->desktop=std::move(desktop);
        next_at+=desktop_bytes;
      }
      if(version_==8 && !DecodeSparsePatches({p+next_at,header_bytes_-next_at},w,h,*atlas)) {
        error_="V8 sparse patches"; return false;
      }
    }
    Frame frame{id,
                w,
                h,
                version_ == 3,
                {p + header_bytes_, p + header_bytes_ + c},
                std::move(alpha_scratch_)};
    frame.atlas = std::move(atlas);
    const std::span<const uint8_t> encoded_alpha{
        p + header_bytes_ + c, wanted_ - header_bytes_ - c};
    if (reuse_alpha_ && decoded_alpha_ && alpha_width_ == w &&
        alpha_height_ == h && alpha_version_ == version_ &&
        std::ranges::equal(encoded_alpha_, encoded_alpha)) {
      frame.shared_alpha = decoded_alpha_;
      frame.alpha_reused = true;
    } else if (version_ == 1) {
      frame.alpha.assign(p + header_bytes_ + c, p + wanted_);
    } else if (!DecodeVfar(encoded_alpha, w, h, max_, &frame.alpha, &error_)) {
      return false;
    }
    if (reuse_alpha_ && !frame.shared_alpha) {
      // Publish a complete validated snapshot. Later misses never mutate an
      // older frame's allocation, even when the decoder has not consumed it.
      auto decoded = std::make_shared<const std::vector<uint8_t>>(std::move(frame.alpha));
      encoded_alpha_.assign(encoded_alpha.begin(), encoded_alpha.end());
      decoded_alpha_ = std::move(decoded);
      alpha_width_ = w;
      alpha_height_ = h;
      alpha_version_ = version_;
      frame.shared_alpha = decoded_alpha_;
    }
    if (version_ == 4 || version_ == 5 || version_ == 7 || version_ == 8)
      frame.deadline_qpc = DeadlineQpc{be64(p + 40), be64(p + 48)};
    out->push_back(std::move(frame));
    if (version_ == 5 || version_ == 7 || version_ == 8)
      previous_atlas_ = id;
    else
      previous_ = id;
    bytes_.clear();
    wanted_ = 40;
    header_bytes_ = 40;
    version_ = 0;
  }
  return true;
}
} // namespace viewflow::vfgp
