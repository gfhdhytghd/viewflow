#pragma once
namespace viewflow::reverse {
enum class SourceDragAction { none, begin, follow, finish };
// A source-confirmed native move may arrive without a proxy mouseDown. Own
// geometry until the physical release, even after our ordered source release
// clears the source's move hint. Never synthesize a new button press.
struct SourceDrag {
    bool active{}, consumed{};
    SourceDragAction observe(bool hint,bool left,bool available) {
        if(active) {
            if(left)return SourceDragAction::follow;
            active=false;consumed=hint;return SourceDragAction::finish;
        }
        if(!hint){consumed=false;return SourceDragAction::none;}
        if(consumed || !left || !available)return SourceDragAction::none;
        active=consumed=true;return SourceDragAction::begin;
    }
    void cancel(){active=false;consumed=true;}
};
}
