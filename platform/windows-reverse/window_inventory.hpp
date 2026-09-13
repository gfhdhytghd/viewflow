#pragma once
#include <windows.h>
#include <cwchar>
#include <iterator>
#include <vector>

namespace viewflow::reverse {
inline bool microsoft_ime_core_window(HWND window) {
    wchar_t cls[256]{};GetClassNameW(window,cls,256);
    if(wcscmp(cls,L"Windows.UI.Core.CoreWindow")!=0)return false;
    DWORD pid{};GetWindowThreadProcessId(window,&pid);
    const auto process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!process)return false;
    wchar_t path[1024]{};DWORD size=static_cast<DWORD>(std::size(path));
    const bool queried=QueryFullProcessImageNameW(process,0,path,&size);CloseHandle(process);
    if(!queried)return false;
    const auto slash=wcsrchr(path,L'\\');const auto name=slash?slash+1:path;
    return _wcsicmp(name,L"TextInputHost.exe")==0 || _wcsicmp(name,L"InputApp.exe")==0;
}

inline bool ime_popup(HWND window) {
    wchar_t cls[256]{};GetClassNameW(window,cls,256);
    if(wcsncmp(cls,L"SoPY_",5)==0 || wcsncmp(cls,L"Sogou_",6)==0 ||
        wcscmp(cls,L"IME")==0 || wcscmp(cls,L"MSCTFIME UI")==0)return true;
    return microsoft_ime_core_window(window);
}

inline HWND ime_capture_window(HWND window) {
    // WGC accepts this CoreWindow but produces no frames for it. The owning
    // ApplicationFrameWindow carries the composited pixels, including alpha.
    if(microsoft_ime_core_window(window)) {
        const auto parent=GetParent(window);
        wchar_t cls[256]{};if(parent)GetClassNameW(parent,cls,256);
        if(wcscmp(cls,L"ApplicationFrameWindow")==0)return parent;
    }
    return window;
}

struct InventoryWindow {HWND window{};bool ime{};};
inline std::vector<InventoryWindow> capture_window_inventory() {
    std::vector<InventoryWindow> result;
    EnumWindows([](HWND window,LPARAM data)->BOOL {
        reinterpret_cast<std::vector<InventoryWindow>*>(data)->push_back({ime_capture_window(window),ime_popup(window)});
        return TRUE;
    },reinterpret_cast<LPARAM>(&result));
    // Modern Microsoft IME CoreWindows can be descendants of an immersive
    // ApplicationFrameWindow. Neither the frame nor candidate is returned by
    // EnumWindows/EnumDesktopWindows; desktop descendant enumeration finds it.
    // Keep the IME classification from the child: enumerating the isolated
    // ApplicationFrameWindow does not necessarily expose its input surface.
    EnumChildWindows(GetDesktopWindow(),[](HWND window,LPARAM data)->BOOL {
        if(IsWindowVisible(window) && ime_popup(window))
            reinterpret_cast<std::vector<InventoryWindow>*>(data)->push_back({ime_capture_window(window),true});
        return TRUE;
    },reinterpret_cast<LPARAM>(&result));
    std::vector<InventoryWindow> unique;
    for(const auto entry:result) {
        bool duplicate=false;
        for(auto& prior:unique)if(prior.window==entry.window){prior.ime|=entry.ime;duplicate=true;break;}
        if(!duplicate)unique.push_back(entry);
    }
    return unique;
}
}
