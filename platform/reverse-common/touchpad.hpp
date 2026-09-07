#pragma once
#include "wire.hpp"
#include <array>
#include <optional>

namespace viewflow::reverse {
struct TouchpadContact {
    std::uint32_t id{},x{},y{};
};
struct TouchpadFrame {
    std::uint32_t width{},height{},count{};
    std::array<TouchpadContact,5> contacts{};
};

// Contact records and their commit share the ordered reverse-input stream.
// The target belongs to the entire frame; incomplete frames are never injected.
class TouchpadAssembler {
    TouchpadFrame pending;
    std::uint64_t target{};
public:
    void reset(){pending={};target=0;}
    std::optional<TouchpadFrame> input(const Input& event) {
        if(event.kind==InputKind::touchpad_contact) {
            if(pending.count && target!=event.id)reset();
            target=event.id;
            if(pending.count>=5 || event.a<0 || event.b<0 || event.c<0 || event.d!=0){reset();throw std::runtime_error("invalid touchpad contact");}
            for(unsigned i=0;i<pending.count;++i)if(pending.contacts[i].id==static_cast<std::uint32_t>(event.a)){reset();throw std::runtime_error("duplicate touchpad contact");}
            pending.contacts[pending.count++]={static_cast<std::uint32_t>(event.a),static_cast<std::uint32_t>(event.b),static_cast<std::uint32_t>(event.c)};
            return {};
        }
        if(event.kind!=InputKind::touchpad_frame)return {};
        auto frame=pending;const auto oldTarget=target;reset();
        if(event.a<=0 || event.b<=0 || event.a>100000 || event.b>100000 || event.c<0 || event.c>5 || event.d!=0 ||
            frame.count!=static_cast<unsigned>(event.c) || (frame.count && oldTarget!=event.id))throw std::runtime_error("invalid touchpad frame");
        frame.width=static_cast<unsigned>(event.a);frame.height=static_cast<unsigned>(event.b);
        for(unsigned i=0;i<frame.count;++i)if(frame.contacts[i].x>frame.width || frame.contacts[i].y>frame.height)throw std::runtime_error("touchpad coordinate out of bounds");
        return frame;
    }
};
}
