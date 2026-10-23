#pragma once
#include "policy.hpp"
#include <set>
namespace viewflow::recall {
inline unsigned evdev_modifier(std::uint32_t code) {
    switch(code) {case 29:case 97:return control;case 56:case 100:return alt;case 42:case 54:return shift;case 125:case 126:return super;default:return 0;}
}
inline std::uint32_t evdev_letter(char letter) {
    constexpr std::uint32_t codes[]={30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44};
    return codes[letter-'A'];
}
class EvdevShortcut {
    std::set<std::uint32_t> modifiers_;
    std::optional<std::uint32_t> consumed_;
public:
    KeyDecision key(std::uint32_t code,bool down,Shortcut shortcut) {
        if(evdev_modifier(code)) {if(down)modifiers_.insert(code);else modifiers_.erase(code);return {};}
        if(consumed_==code) {if(!down)consumed_.reset();return {true,false};}
        if(!down || code!=evdev_letter(shortcut.letter))return {};
        unsigned modifiers=0;for(auto key:modifiers_)modifiers|=evdev_modifier(key);
        if(modifiers!=shortcut.modifiers)return {};
        consumed_=code;return {true,true};
    }
    void reset() {modifiers_.clear();consumed_.reset();}
};
}
