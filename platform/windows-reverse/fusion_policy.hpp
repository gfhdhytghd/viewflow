#pragma once
#include <windows.h>
#include <cstdio>

namespace viewflow::reverse {
// Properties belong to HWND lifetime, so a replacement process can restore
// styles after an unclean exit without confusing recycled window handles.
class FusionPolicy {
    static constexpr auto property=L"Viewflow.Fusion.OriginalMinimize.v1";
    bool enabled_{};
    bool configured_{};
    static void restore(HWND window) {
        const auto saved=reinterpret_cast<ULONG_PTR>(GetPropW(window,property));
        if(!saved)return;
        auto style=GetWindowLongPtrW(window,GWL_STYLE);
        if(saved&2)style|=WS_MINIMIZEBOX;
        SetWindowLongPtrW(window,GWL_STYLE,style);
        if(auto menu=GetSystemMenu(window,FALSE))EnableMenuItem(menu,SC_MINIMIZE,MF_BYCOMMAND|((saved&4)?MF_GRAYED:MF_ENABLED));
        RemovePropW(window,property);
        SetWindowPos(window,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);
    }
public:
    ~FusionPolicy(){if(configured_)set(false);}
    bool enabled() const{return enabled_;}
    void set(bool value) {
        if(configured_ && enabled_==value)return;
        configured_=true;
        enabled_=value;
        if(!value)EnumWindows([](HWND window,LPARAM)->BOOL{restore(window);return TRUE;},0);
        std::fprintf(stderr,"reverse-fusion enabled=%u window_owner=hyprland\n",unsigned(value));
    }
    void manage(HWND window) {
        if(!enabled_)return;
        auto style=GetWindowLongPtrW(window,GWL_STYLE);
        auto saved=reinterpret_cast<ULONG_PTR>(GetPropW(window,property));
        if(!saved) {
            saved=1|((style&WS_MINIMIZEBOX)?2:0);
            const auto menu=GetSystemMenu(window,FALSE);
            if(menu && (GetMenuState(menu,SC_MINIMIZE,MF_BYCOMMAND)&(MF_DISABLED|MF_GRAYED)))saved|=4;
            if(!SetPropW(window,property,reinterpret_cast<HANDLE>(saved)))return;
        }
        if(style&WS_MINIMIZEBOX) {
            SetWindowLongPtrW(window,GWL_STYLE,style&~WS_MINIMIZEBOX);
            SetWindowPos(window,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);
        }
        if(auto menu=GetSystemMenu(window,FALSE))EnableMenuItem(menu,SC_MINIMIZE,MF_BYCOMMAND|MF_GRAYED);
        // Custom chrome or an application calling ShowWindow can bypass the
        // system menu. Recover locally, without activating the guest window.
        if(IsIconic(window)) {
            WINDOWPLACEMENT placement{sizeof(placement)};
            if(GetWindowPlacement(window,&placement)) {
                placement.showCmd=SW_SHOWNOACTIVATE;
                SetWindowPlacement(window,&placement);
            }
        }
    }
};
}
