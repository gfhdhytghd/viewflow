#pragma once
#include <windows.h>
#include <dwmapi.h>
#include <cwchar>
#include <iterator>
#include <vector>
#include <set>

namespace viewflow::reverse {
inline bool microsoft_shell_process(HWND window,bool start_menu=false) {
    DWORD pid{};GetWindowThreadProcessId(window,&pid);
    const auto process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!process)return false;
    wchar_t path[1024]{};DWORD size=static_cast<DWORD>(std::size(path));
    const bool queried=QueryFullProcessImageNameW(process,0,path,&size);CloseHandle(process);
    if(!queried)return false;
    const auto slash=wcsrchr(path,L'\\');const auto name=slash?slash+1:path;
    if(start_menu)return _wcsicmp(name,L"StartMenuExperienceHost.exe")==0 || _wcsicmp(name,L"SearchHost.exe")==0;
    return _wcsicmp(name,L"TextInputHost.exe")==0 || _wcsicmp(name,L"InputApp.exe")==0;
}
inline bool microsoft_ime_process(HWND window){return microsoft_shell_process(window);}

// Identify tool/transient surfaces by Win32 semantics, not their dimensions.
inline bool native_popup_style(LONG_PTR style,LONG_PTR extended,bool owned) {
    return (extended&WS_EX_TOOLWINDOW) ||
        (!(style&WS_CAPTION) && (owned || ((style&WS_POPUP) && !(style&WS_THICKFRAME))));
}
inline bool native_popup(HWND window) {
    return native_popup_style(GetWindowLongPtrW(window,GWL_STYLE),GetWindowLongPtrW(window,GWL_EXSTYLE),GetWindow(window,GW_OWNER)!=nullptr);
}
struct InventoryWindow {HWND window{};bool ime{};bool shell{};};
inline InventoryWindow inspect_inventory_window(HWND window) {
    wchar_t cls[256]{};GetClassNameW(window,cls,256);
    const bool core=wcscmp(cls,L"Windows.UI.Core.CoreWindow")==0 && microsoft_ime_process(window);
    const bool shell=wcscmp(cls,L"Windows.UI.Core.CoreWindow")==0 && microsoft_shell_process(window,true);
    const bool ime=core || wcsncmp(cls,L"SoPY_",5)==0 || wcsncmp(cls,L"Sogou_",6)==0 ||
        wcscmp(cls,L"IME")==0 || wcscmp(cls,L"MSCTFIME UI")==0;
    if(core || shell){
        // The child is cloaked when Start/Search is closed, even when its
        // owning frame remains visible. Keep that HWND so candidate() rejects
        // the cloaked surface instead of capturing a large empty frame.
        DWORD cloaked{};
        if(SUCCEEDED(DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked))) && cloaked)
            return {window,ime,shell};
        // WGC needs the owning frame, while IME classification belongs to the
        // child. Resolve both from the same class/process observation.
        const auto parent=GetParent(window);wchar_t parent_class[256]{};
        if(parent)GetClassNameW(parent,parent_class,256);
        if(wcscmp(parent_class,L"ApplicationFrameWindow")==0)window=parent;
    }
    return {window,ime,shell};
}
inline bool microsoft_ime_core_window(HWND window) {
    wchar_t cls[256]{};GetClassNameW(window,cls,256);
    return wcscmp(cls,L"Windows.UI.Core.CoreWindow")==0 && microsoft_ime_process(window);
}
inline bool ime_popup(HWND window) {return inspect_inventory_window(window).ime;}
inline HWND ime_capture_window(HWND window) {return inspect_inventory_window(window).window;}

inline std::vector<InventoryWindow> capture_window_inventory() {
    std::vector<InventoryWindow> result;
    EnumWindows([](HWND window,LPARAM data)->BOOL {
        reinterpret_cast<std::vector<InventoryWindow>*>(data)->push_back(inspect_inventory_window(window));
        return TRUE;
    },reinterpret_cast<LPARAM>(&result));
    // EnumWindows omits immersive top-level CoreWindows on Windows 11.
    // FindWindowEx walks these desktop siblings as well (Start/Search, IME).
    std::set<HWND> siblings;
    for(HWND window=nullptr;(window=FindWindowExW(nullptr,window,nullptr,nullptr)) && siblings.insert(window).second;) {
        if(IsWindowVisible(window)) {
            const auto entry=inspect_inventory_window(window);
            if(entry.ime || entry.shell)result.push_back(entry);
        }
    }
    // Modern Microsoft IME CoreWindows can be descendants of an immersive
    // ApplicationFrameWindow. Neither the frame nor candidate is returned by
    // EnumWindows/EnumDesktopWindows; desktop descendant enumeration finds it.
    // Keep the IME classification from the child: enumerating the isolated
    // ApplicationFrameWindow does not necessarily expose its input surface.
    EnumChildWindows(GetDesktopWindow(),[](HWND window,LPARAM data)->BOOL {
        if(IsWindowVisible(window)){
            const auto entry=inspect_inventory_window(window);
            if(entry.ime || entry.shell)reinterpret_cast<std::vector<InventoryWindow>*>(data)->push_back(entry);
        }
        return TRUE;
    },reinterpret_cast<LPARAM>(&result));
    std::vector<InventoryWindow> unique;
    for(const auto entry:result) {
        bool duplicate=false;
        for(auto& prior:unique)if(prior.window==entry.window){prior.ime|=entry.ime;prior.shell|=entry.shell;duplicate=true;break;}
        if(!duplicate)unique.push_back(entry);
    }
    return unique;
}
}
