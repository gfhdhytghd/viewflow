#pragma once
#include "activity_input.hpp"
namespace viewflow::activity {
struct Hint {std::uint64_t window{};unsigned kind{1};bool active{};};
inline std::vector<std::uint8_t> pack_hint(Hint hint){
    if(!hint.window || hint.kind<1 || hint.kind>2)throw std::runtime_error("activity hint identity");
    reverse::Writer writer;writer.u32(6);writer.u32(hint.kind);writer.u64(hint.window);writer.u32(hint.active);writer.u32(0);return std::move(writer.bytes);
}
inline Hint unpack_hint(std::span<const std::uint8_t> bytes){
    if(bytes.size()!=24)throw std::runtime_error("activity hint size");
    reverse::Reader reader{bytes};if(reader.u32()!=6)throw std::runtime_error("activity hint tag");
    Hint hint;hint.kind=reader.u32();hint.window=reader.u64();const auto active=reader.u32();
    if(!hint.window || hint.kind<1 || hint.kind>2 || active>1 || reader.u32())throw std::runtime_error("activity hint fields");
    hint.active=active;return hint;
}
inline void observe(Priority<std::uint64_t>& state,Hint hint,std::uint64_t now){state.hold(hint.window,3+hint.kind,0,hint.active,now);}
}
