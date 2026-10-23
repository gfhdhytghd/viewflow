#include "fusion_policy.hpp"
#include "window_inventory.hpp"
#include <cassert>
// Hidden synthetic HWND only: no focus changes or injected input.
int main(){
    using viewflow::reverse::native_popup_style;
    assert(native_popup_style(WS_POPUP,WS_EX_TOOLWINDOW,false));
    assert(native_popup_style(WS_POPUP,0,true));
    assert(native_popup_style(WS_POPUP,0,false));
    assert(!native_popup_style(WS_OVERLAPPEDWINDOW,0,false));
    assert(!native_popup_style(WS_POPUP|WS_THICKFRAME,0,false));

    auto window=CreateWindowExW(0,L"STATIC",L"Viewflow fusion style test",WS_OVERLAPPEDWINDOW,0,0,200,100,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    assert(window);const auto original=GetWindowLongPtrW(window,GWL_STYLE);
    viewflow::reverse::FusionPolicy policy;
    policy.manage(window);assert(GetWindowLongPtrW(window,GWL_STYLE)==original);
    policy.set(true);policy.manage(window);assert(!(GetWindowLongPtrW(window,GWL_STYLE)&WS_MINIMIZEBOX));
    SetWindowLongPtrW(window,GWL_STYLE,GetWindowLongPtrW(window,GWL_STYLE)|WS_MINIMIZEBOX);
    policy.manage(window);assert(!(GetWindowLongPtrW(window,GWL_STYLE)&WS_MINIMIZEBOX));
    policy.set(false);assert(GetWindowLongPtrW(window,GWL_STYLE)==original);
    assert(!IsWindowVisible(window));DestroyWindow(window);
}
