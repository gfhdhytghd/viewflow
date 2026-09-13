#pragma once
#include <memory>
namespace viewflow::hyprland {
class PopupBackdrops {
    struct Impl;
    std::unique_ptr<Impl> impl_;
public:
    explicit PopupBackdrops(void* handle);
    ~PopupBackdrops();
};
}
