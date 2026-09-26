#pragma once
#include <algorithm>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>
#include <limits>
#include <bit>
#include <set>

namespace viewflow::reverse {
inline constexpr std::uint32_t max_record=96u*1024u*1024u;
inline constexpr std::uint32_t max_pixels=32u*1024u*1024u;
inline constexpr std::uint32_t fullscreen_flag = 32u;
inline constexpr std::uint32_t resident_crop_flag = 256u;
inline constexpr std::uint32_t residency_capability = 512u;
inline constexpr std::uint32_t application_icon_flag = 1024u;
struct Tile {
    std::uint64_t id{}, owner{};
    std::int32_t x{}, y{};
    std::uint32_t width{},height{},atlas_x{},atlas_y{};
    std::string title;
    std::uint32_t flags{}; // bit 0: native move; bit 1: IME; bit 2: grab offset; bit 3: HID; bit 4: native frame geometry
    std::uint64_t geometry_ack{};
    std::int32_t grab_x{},grab_y{};
    std::uint32_t body_x{},body_y{},body_width{},body_height{},logical_width{},logical_height{},pixel_scale{};
    std::uint32_t resident_x{},resident_y{},resident_width{},resident_height{};
    std::string app_id{};
    std::vector<std::uint8_t> icon_png{};
};
struct Frame {
    std::uint32_t codec{2},width{},height{};
    std::int64_t pts{};
    bool keyframe{};
    std::vector<Tile> tiles;
    std::vector<std::uint8_t> alpha, color;
    // Present only after activity-v1 negotiation. Epoch zero is byte-identical
    // legacy framing. Membership covers both lanes, not just this atlas.
    std::uint32_t activity_lane{};
    std::uint64_t activity_epoch{}, activity_preferred{}, activity_focus{};
    std::vector<std::uint64_t> activity_members;
};
enum class InputKind : std::uint32_t { pointer=1, button=2, wheel=3, key=4, focus=5, geometry=6, close=7, release=8, proxy_drag=9, touchpad_contact=10, touchpad_frame=11, proxy_drag_anchor=12, native_touchpad_chunk=13, native_touchpad_commit=14, fullscreen=15, visibility=16 };
struct Input {
    std::uint64_t id{},sequence{};
    InputKind kind{};
    std::int32_t a{},b{},c{},d{};
};
struct Writer {
    std::vector<std::uint8_t> bytes;
    void u32(std::uint32_t value) {for(unsigned i=0;i<4;++i)bytes.push_back(static_cast<std::uint8_t>(value>>(i*8)));}
    void i32(std::int32_t value) {u32(std::bit_cast<std::uint32_t>(value));}
    void u64(std::uint64_t value) {u32(static_cast<std::uint32_t>(value));u32(static_cast<std::uint32_t>(value>>32));}
    void blob(std::span<const std::uint8_t> value) {
        if(value.size()>max_record || bytes.size()+value.size()+4>max_record) throw std::runtime_error("reverse record too large");
        u32(static_cast<std::uint32_t>(value.size()));bytes.insert(bytes.end(),value.begin(),value.end());
    }
};
struct Reader {
    std::span<const std::uint8_t> bytes;
    std::size_t offset{};
    std::uint32_t u32() {
        if(bytes.size()-offset<4) throw std::runtime_error("truncated reverse record");
        std::uint32_t value{};for(unsigned i=0;i<4;++i)value|=std::uint32_t(bytes[offset++])<<(i*8);return value;
    }
    std::int32_t i32() {return std::bit_cast<std::int32_t>(u32());}
    std::uint64_t u64() {const auto low=u32();return low|(std::uint64_t(u32())<<32);}
    std::span<const std::uint8_t> blob(std::size_t limit=max_record) {
        const auto size=u32();if(size>limit || size>bytes.size()-offset) throw std::runtime_error("invalid reverse blob extent");
        auto result=bytes.subspan(offset,size);offset+=size;return result;
    }
    void finish() {if(offset!=bytes.size()) throw std::runtime_error("trailing reverse bytes");}
};
inline void validate(const Frame& frame) {
    if((frame.codec!=1 && frame.codec!=2) || !frame.width || !frame.height || frame.width>8192 || frame.height>8192 ||
       std::uint64_t(frame.width)*frame.height>max_pixels || frame.pts<0 || frame.tiles.size()>32 || frame.color.empty())
        throw std::runtime_error("invalid reverse frame");
    std::set<std::uint64_t> ids;
    for(const auto& tile:frame.tiles) {
        if(!tile.id || !ids.insert(tile.id).second || !tile.width || !tile.height || tile.width>8192 || tile.height>8192 || tile.title.size()>4096 || tile.flags>2047 ||
           ((tile.flags&4) && (!(tile.flags&1) || tile.grab_x < -1000000 || tile.grab_x > 1000000 || tile.grab_y < -1000000 || tile.grab_y > 1000000)))
            throw std::runtime_error("invalid reverse tile");
        if(tile.flags&application_icon_flag) {
            if(tile.app_id.empty() || tile.app_id.size()>256 || tile.icon_png.size()<33 || tile.icon_png.size()>256*1024 ||
               std::string_view(reinterpret_cast<const char*>(tile.icon_png.data()),8)!=std::string_view("\x89PNG\r\n\x1a\n",8))
                throw std::runtime_error("invalid application icon");
            const auto extent=[&](unsigned p){return (unsigned(tile.icon_png[p])<<24)|(unsigned(tile.icon_png[p+1])<<16)|(unsigned(tile.icon_png[p+2])<<8)|tile.icon_png[p+3];};
            if(extent(8)!=13 || std::string_view(reinterpret_cast<const char*>(tile.icon_png.data()+12),4)!="IHDR" ||
               !extent(16) || extent(16)>256 || !extent(20) || extent(20)>256)throw std::runtime_error("invalid application icon dimensions");
        }
        const auto rw = tile.flags & resident_crop_flag ? tile.resident_width : tile.width;
        const auto rh = tile.flags & resident_crop_flag ? tile.resident_height : tile.height;
        if ((rw == 0) != (rh == 0) || rw>frame.width || rh>frame.height ||
            tile.atlas_x>frame.width-rw || tile.atlas_y>frame.height-rh ||
            ((tile.flags & resident_crop_flag) && (tile.resident_x>tile.width || tile.resident_y>tile.height ||
                rw>tile.width-tile.resident_x || rh>tile.height-tile.resident_y)))
            throw std::runtime_error("invalid reverse resident crop");
        if((tile.flags&16) && (!tile.body_width || !tile.body_height || tile.body_width>tile.width || tile.body_height>tile.height ||
           tile.body_x>tile.width-tile.body_width || tile.body_y>tile.height-tile.body_height ||
           !tile.logical_width || !tile.logical_height || tile.logical_width>16384 || tile.logical_height>16384 ||
           tile.pixel_scale<1 || tile.pixel_scale>4)) throw std::runtime_error("invalid native frame geometry");
    }
}
inline std::vector<std::uint8_t> pack_frame(const Frame& frame) {
    validate(frame);Writer w;
    if(frame.activity_epoch) {
        if(frame.activity_lane>1 || frame.activity_members.size()>32)throw std::runtime_error("invalid activity frame");
        w.u32(4);w.u32(frame.activity_lane);w.u64(frame.activity_epoch);w.u64(frame.activity_preferred);w.u64(frame.activity_focus);
        w.u32(static_cast<std::uint32_t>(frame.activity_members.size()));
        for(auto id:frame.activity_members)w.u64(id);
    } else w.u32(1);
    w.u32(frame.codec);w.u32(frame.width);w.u32(frame.height);w.u64(frame.pts);w.u32(frame.keyframe);w.u32(static_cast<std::uint32_t>(frame.tiles.size()));
    for(const auto& t:frame.tiles) {
        w.u64(t.id);w.u64(t.owner);w.i32(t.x);w.i32(t.y);w.u32(t.width);w.u32(t.height);w.u32(t.atlas_x);w.u32(t.atlas_y);
        w.blob({reinterpret_cast<const std::uint8_t*>(t.title.data()),t.title.size()});w.u32(t.flags);w.u64(t.geometry_ack);if(t.flags&4){w.i32(t.grab_x);w.i32(t.grab_y);}
        if(t.flags&16){w.u32(t.body_x);w.u32(t.body_y);w.u32(t.body_width);w.u32(t.body_height);w.u32(t.logical_width);w.u32(t.logical_height);w.u32(t.pixel_scale);}
        if(t.flags&resident_crop_flag){w.u32(t.resident_x);w.u32(t.resident_y);w.u32(t.resident_width);w.u32(t.resident_height);}
        if(t.flags&application_icon_flag){w.blob({reinterpret_cast<const std::uint8_t*>(t.app_id.data()),t.app_id.size()});w.blob(t.icon_png);}
    }
    w.blob(frame.alpha);w.blob(frame.color);return std::move(w.bytes);
}
inline Frame unpack_frame(std::span<const std::uint8_t> bytes) {
    if(bytes.size()>max_record) throw std::runtime_error("reverse frame too large");
    Reader r{bytes};const auto type=r.u32();Frame f;
    if(type==4) {
        f.activity_lane=r.u32();f.activity_epoch=r.u64();f.activity_preferred=r.u64();f.activity_focus=r.u64();
        const auto members=r.u32();
        if(f.activity_lane>1 || !f.activity_epoch || members>32)throw std::runtime_error("invalid activity frame");
        for(unsigned i=0;i<members;++i){const auto id=r.u64();if(!id || std::find(f.activity_members.begin(),f.activity_members.end(),id)!=f.activity_members.end())throw std::runtime_error("invalid activity membership");f.activity_members.push_back(id);}
    } else if(type!=1)throw std::runtime_error("unexpected reverse frame type");
    f.codec=r.u32();f.width=r.u32();f.height=r.u32();
    const auto pts=r.u64();if(pts>INT64_MAX)throw std::runtime_error("invalid reverse timestamp");f.pts=static_cast<std::int64_t>(pts);
    const auto key=r.u32();if(key>1)throw std::runtime_error("invalid key flag");f.keyframe=key!=0;
    auto count=r.u32();if(count>32)throw std::runtime_error("reverse tile count");
    for(unsigned i=0;i<count;++i) {
        Tile t;t.id=r.u64();t.owner=r.u64();t.x=r.i32();t.y=r.i32();t.width=r.u32();t.height=r.u32();t.atlas_x=r.u32();t.atlas_y=r.u32();
        auto title=r.blob(4096);t.title.assign(reinterpret_cast<const char*>(title.data()),title.size());t.flags=r.u32();t.geometry_ack=r.u64();if(t.flags&4){t.grab_x=r.i32();t.grab_y=r.i32();}
        if(t.flags&16){t.body_x=r.u32();t.body_y=r.u32();t.body_width=r.u32();t.body_height=r.u32();t.logical_width=r.u32();t.logical_height=r.u32();t.pixel_scale=r.u32();}
        if(t.flags&resident_crop_flag){t.resident_x=r.u32();t.resident_y=r.u32();t.resident_width=r.u32();t.resident_height=r.u32();}
        if(t.flags&application_icon_flag){auto app=r.blob(256);t.app_id.assign(reinterpret_cast<const char*>(app.data()),app.size());auto png=r.blob(256*1024);t.icon_png.assign(png.begin(),png.end());}
        f.tiles.push_back(std::move(t));
    }
    auto alpha=r.blob(max_pixels+1);f.alpha.assign(alpha.begin(),alpha.end());
    auto color=r.blob(32u*1024u*1024u);f.color.assign(color.begin(),color.end());r.finish();validate(f);return f;
}
inline std::vector<std::uint8_t> pack_input(const Input& input) {
    Writer w;w.u32(2);w.u64(input.id);w.u64(input.sequence);w.u32(static_cast<std::uint32_t>(input.kind));
    w.i32(input.a);w.i32(input.b);w.i32(input.c);w.i32(input.d);return std::move(w.bytes);
}
inline Input unpack_input(std::span<const std::uint8_t> bytes) {
    Reader r{bytes};if(r.u32()!=2)throw std::runtime_error("unexpected reverse input type");
    Input result;result.id=r.u64();result.sequence=r.u64();auto kind=r.u32();
    if(kind<1 || kind>16 || !result.sequence)throw std::runtime_error("invalid reverse input");
    result.kind=static_cast<InputKind>(kind);result.a=r.i32();result.b=r.i32();result.c=r.i32();result.d=r.i32();r.finish();return result;
}
// Exact 8-bit alpha: choose raw when RLE would expand. RLE stores length then
// value; the decoded extent is checked before allocation or copying any run.
inline std::vector<std::uint8_t> encode_alpha(std::span<const std::uint8_t> alpha) {
    if(alpha.empty() || alpha.size()>max_pixels)throw std::runtime_error("invalid alpha plane");
    Writer w;w.bytes.push_back(1);
    for(std::size_t start=0;start<alpha.size();) {
        auto end=start+1;while(end<alpha.size() && alpha[end]==alpha[start])++end;
        w.u32(static_cast<std::uint32_t>(end-start));w.bytes.push_back(alpha[start]);start=end;
        if(w.bytes.size()>alpha.size()) {w.bytes.assign(1,0);w.bytes.insert(w.bytes.end(),alpha.begin(),alpha.end());break;}
    }
    return std::move(w.bytes);
}
inline std::vector<std::uint8_t> decode_alpha(std::span<const std::uint8_t> encoded,std::size_t size) {
    if(!size || size>max_pixels || encoded.empty())throw std::runtime_error("invalid alpha extent");
    if(encoded[0]==0) {if(encoded.size()!=size+1)throw std::runtime_error("raw alpha extent mismatch");return {encoded.begin()+1,encoded.end()};}
    if(encoded[0]!=1)throw std::runtime_error("unknown alpha format");
    Reader r{encoded.subspan(1)};std::vector<std::uint8_t> result;result.reserve(size);
    while(r.offset<r.bytes.size()) {
        const auto count=r.u32();if(!count || count>size-result.size() || r.offset==r.bytes.size())throw std::runtime_error("invalid alpha run");
        result.insert(result.end(),count,r.bytes[r.offset++]);
    }
    if(result.size()!=size)throw std::runtime_error("incomplete alpha plane");
    return result;
}
}
