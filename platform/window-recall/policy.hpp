#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace viewflow::recall {
inline constexpr std::string_view default_shortcut = "Ctrl+Alt+Shift+H";
enum Modifier : unsigned { control=1, alt=2, shift=4, super=8 };
struct Shortcut {
    unsigned modifiers = control | alt | shift;
    char letter = 'H';
    bool operator==(const Shortcut&) const = default;
};
inline Shortcut parse_shortcut(std::string_view text) {
    Shortcut result{0, 0};
    while (!text.empty()) {
        const auto split = text.find('+');
        auto part = text.substr(0, split);
        while (!part.empty() && part.front() == ' ') part.remove_prefix(1);
        while (!part.empty() && part.back() == ' ') part.remove_suffix(1);
        std::string token(part);
        for (auto& c : token) if (c >= 'a' && c <= 'z') c = char(c - 'a' + 'A');
        unsigned modifier = 0;
        if (token == "CTRL" || token == "CONTROL") modifier = control;
        else if (token == "ALT" || token == "OPTION") modifier = alt;
        else if (token == "SHIFT") modifier = shift;
        else if (token == "SUPER" || token == "WIN" || token == "CMD" || token == "COMMAND") modifier = super;
        else if (token.size() == 1 && token[0] >= 'A' && token[0] <= 'Z' && !result.letter) result.letter = token[0];
        else throw std::invalid_argument("Shortcut must contain modifiers and one A-Z key");
        if (modifier && (result.modifiers & modifier)) throw std::invalid_argument("Duplicate shortcut modifier");
        result.modifiers |= modifier;
        if (split == std::string_view::npos) break;
        text.remove_prefix(split + 1);
        if (text.empty()) throw std::invalid_argument("Incomplete shortcut");
    }
    if (!result.modifiers || !result.letter) throw std::invalid_argument("Shortcut must contain modifiers and one A-Z key");
    return result;
}
inline std::string format_shortcut(Shortcut value) {
    std::string result;
    for (const auto& [bit, name] : std::array<std::pair<unsigned, const char*>, 4>{{{control,"Ctrl+"},{alt,"Alt+"},{shift,"Shift+"},{super,"Super+"}}})
        if (value.modifiers & bit) result += name;
    result += value.letter;
    return result;
}
struct KeyDecision { bool consume=false; bool trigger=false; };
// Each physical input route keeps its own latch. Modifier key transitions are
// left untouched: already forwarded modifiers still receive their real releases.
class KeyLatch {
    bool held_ = false;
public:
    KeyDecision key(bool matches, bool down, unsigned modifiers, Shortcut shortcut) {
        if (!matches) return {};
        if (!down) { const bool consumed=held_; held_=false; return {consumed,false}; }
        if (held_) return {true,false};
        if (modifiers != shortcut.modifiers) return {};
        held_=true; return {true,true};
    }
    void reset() { held_=false; }
};
struct Rect {
    double x{},y{},width{},height{};
    bool valid() const { return std::isfinite(x)&&std::isfinite(y)&&std::isfinite(width)&&std::isfinite(height)&&width>0&&height>0; }
    bool contains(double px,double py) const { return px>=x&&py>=y&&px<x+width&&py<y+height; }
};
inline bool needs_recall(Rect window, const std::vector<Rect>& physical) {
    if (!window.valid() || physical.empty()) return false;
    const auto cx=window.x+window.width/2, cy=window.y+window.height/2;
    return std::none_of(physical.begin(), physical.end(), [&](Rect screen) { return screen.contains(cx,cy); });
}
inline Rect placement(Rect window, Rect work, std::size_t index, double step=28) {
    if (!window.valid() || !work.valid() || !std::isfinite(step) || step<=0) throw std::invalid_argument("Invalid recall geometry");
    const auto width=std::min(window.width,work.width),height=std::min(window.height,work.height);
    const auto slots=std::max<std::size_t>(1, std::size_t(std::floor(std::min(work.width-width, work.height-height)/step))+1);
    const double offset=double(index%slots)*step;
    return {work.x+offset,work.y+offset,width,height};
}
}
