#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include "policy.hpp"
#include <cstdio>
#include <cwctype>
#include <map>
#include <string>
#include <vector>

namespace vr=viewflow::recall;
namespace {
struct Screen { HMONITOR handle{}; RECT bounds{},work{}; bool primary{}; };
vr::Rect rect(RECT r) { return {double(r.left),double(r.top),double(r.right-r.left),double(r.bottom-r.top)}; }
std::vector<Screen> physical_screens() {
    std::vector<Screen> screens;
    EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT,LPARAM data)->BOOL {
        MONITORINFOEXW info{};info.cbSize=sizeof(info);
        if(!GetMonitorInfoW(monitor,&info)) return TRUE;
        DISPLAY_DEVICEW device{};device.cb=sizeof(device);
        bool physical=false;
        for(DWORD i=0;EnumDisplayDevicesW(nullptr,i,&device,0);++i) {
            if(wcscmp(device.DeviceName,info.szDevice)!=0) continue;
            std::wstring name=device.DeviceString;
            for(auto& c:name)c=wchar_t(towlower(c));
            physical=!(device.StateFlags&DISPLAY_DEVICE_MIRRORING_DRIVER) &&
                name.find(L"virtual")==std::wstring::npos && name.find(L"remote")==std::wstring::npos &&
                name.find(L"indirect")==std::wstring::npos;
            break;
        }
        if(physical) reinterpret_cast<std::vector<Screen>*>(data)->push_back({monitor,info.rcMonitor,info.rcWork,bool(info.dwFlags&MONITORINFOF_PRIMARY)});
        return TRUE;
    },reinterpret_cast<LPARAM>(&screens));
    return screens;
}
HMONITOR recent_physical{};
void observe_focus(const std::vector<Screen>& screens) {
    auto focus=GetForegroundWindow();
    if(!focus) return;
    auto monitor=MonitorFromWindow(focus,MONITOR_DEFAULTTONULL);
    for(auto& s:screens) if(s.handle==monitor) recent_physical=monitor;
}
bool proxy(HWND window) {
    wchar_t name[256]{};GetClassNameW(window,name,256);
    const std::wstring_view cls(name);
    return cls.starts_with(L"ViewflowAtlas") || cls.starts_with(L"ViewflowPortable") || cls==L"VFCompositionPreview";
}
struct Window { HWND handle{},owner{}; RECT bounds{}; bool root{}; };
std::vector<Window> inventory() {
    std::vector<Window> result;
    EnumWindows([](HWND window,LPARAM data)->BOOL {
        if(!IsWindowVisible(window) || IsIconic(window) || IsZoomed(window) || proxy(window))return TRUE;
        DWORD cloaked=0;DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));
        if(cloaked)return TRUE;
        auto style=GetWindowLongPtrW(window,GWL_STYLE), ex=GetWindowLongPtrW(window,GWL_EXSTYLE);
        HWND owner=GetWindow(window,GW_OWNER);
        const bool root=(style&WS_CAPTION) || (ex&WS_EX_APPWINDOW);
        if(!root && !owner)return TRUE;
        wchar_t cls[128]{};GetClassNameW(window,cls,128);
        if(wcscmp(cls,L"Shell_TrayWnd")==0 || wcscmp(cls,L"Progman")==0 || wcscmp(cls,L"WorkerW")==0)return TRUE;
        RECT bounds{};if(!GetWindowRect(window,&bounds)||!rect(bounds).valid())return TRUE;
        reinterpret_cast<std::vector<Window>*>(data)->push_back({window,owner,bounds,root});return TRUE;
    },reinterpret_cast<LPARAM>(&result));
    return result;
}
unsigned recall(bool check) {
    auto screens=physical_screens();observe_focus(screens);
    if(screens.empty()) { std::fprintf(stderr,"recall unavailable: no physical screen\n");return 1; }
    const Screen* target=&screens.front();
    for(auto& s:screens) if(s.primary)target=&s;
    for(auto& s:screens) if(s.handle==recent_physical)target=&s;
    std::vector<vr::Rect> physical;for(auto& s:screens)physical.push_back(rect(s.bounds));
    const auto windows=inventory();
    std::map<HWND,vr::Rect> destinations;
    std::size_t index=0;
    // EnumWindows is front to back; preserve the existing z order with NOZORDER.
    for(const auto& window:windows) {
        if(!window.root || !vr::needs_recall(rect(window.bounds),physical))continue;
        // Owned dialogs follow an eligible top-level owner, below.
        bool follows=false;
        for(auto owner=window.owner;owner;owner=GetWindow(owner,GW_OWNER)) {
            auto i=std::find_if(windows.begin(),windows.end(),[&](const Window& w){return w.handle==owner;});
            if(i!=windows.end() && i->root && vr::needs_recall(rect(i->bounds),physical)) { follows=true;break; }
        }
        if(!follows)destinations.emplace(window.handle,vr::placement(rect(window.bounds),rect(target->work),index++));
    }
    // Resolve owned popup chains without relying on enumeration order.
    for(std::size_t pass=0;pass<windows.size();++pass) {
        bool changed=false;
        for(const auto& window:windows) {
            if(!window.owner || destinations.contains(window.handle))continue;
            auto owner=destinations.find(window.owner);if(owner==destinations.end())continue;
            auto original=std::find_if(windows.begin(),windows.end(),[&](const Window& w){return w.handle==window.owner;});
            if(original==windows.end())continue;
            auto r=rect(window.bounds),work=rect(target->work);
            r.x+=owner->second.x-original->bounds.left;r.y+=owner->second.y-original->bounds.top;
            r.width=std::min(r.width,work.width);r.height=std::min(r.height,work.height);
            r.x=std::clamp(r.x,work.x,work.x+work.width-r.width);r.y=std::clamp(r.y,work.y,work.y+work.height-r.height);
            destinations.emplace(window.handle,r);changed=true;
        }
        if(!changed)break;
    }
    unsigned moved=0,failed=0;
    for(const auto& [window,r]:destinations) {
        if(check)continue;
        if(SetWindowPos(window,nullptr,int(std::lround(r.x)),int(std::lround(r.y)),int(std::lround(r.width)),int(std::lround(r.height)),
            SWP_NOACTIVATE|SWP_NOZORDER|SWP_NOOWNERZORDER|SWP_ASYNCWINDOWPOS))++moved;else ++failed;
    }
    std::printf("recall physical=%zu eligible=%zu moved=%u failed=%u dry_run=%u\n",screens.size(),destinations.size(),moved,failed,unsigned(check));std::fflush(stdout);
    return failed;
}
unsigned native_modifiers(vr::Shortcut s) {
    return ((s.modifiers&vr::control)?MOD_CONTROL:0)|((s.modifiers&vr::alt)?MOD_ALT:0)|
        ((s.modifiers&vr::shift)?MOD_SHIFT:0)|((s.modifiers&vr::super)?MOD_WIN:0)|MOD_NOREPEAT;
}
}
int main(int argc,char** argv) {
    try {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        std::string mode="--watch";vr::Shortcut shortcut;DWORD parent=0;
        for(int i=1;i<argc;++i) {
            std::string_view arg=argv[i];
            if(arg=="--shortcut" && i+1<argc)shortcut=vr::parse_shortcut(argv[++i]);
            else if(arg=="--parent" && i+1<argc)parent=DWORD(std::stoul(argv[++i]));
            else if(arg=="--once" || arg=="--check" || arg=="--watch" || arg=="--validate-shortcut" || arg=="--help")mode=arg;
            else throw std::invalid_argument("Unknown recall argument");
        }
        if(mode=="--help") {std::puts("viewflow-window-recall [--watch|--once|--check|--validate-shortcut] [--shortcut Ctrl+Alt+Shift+H] [--parent PID]");return 0;}
        if(mode=="--validate-shortcut") {std::puts(vr::format_shortcut(shortcut).c_str());return 0;}
        if(mode=="--once") {
            if(HANDLE request=OpenEventW(EVENT_MODIFY_STATE,FALSE,L"Local\\ViewflowRecallRequest")) {
                const bool sent=SetEvent(request)!=FALSE;CloseHandle(request);
                std::puts(sent?"recall queued":"recall queue failed");return sent?0:1;
            }
        }
        if(mode=="--check" || mode=="--once")return int(recall(mode=="--check"));
        HANDLE singleton=CreateMutexW(nullptr,FALSE,L"Local\\ViewflowWindowRecall");
        if(!singleton || GetLastError()==ERROR_ALREADY_EXISTS) {if(singleton)CloseHandle(singleton);std::fputs("recall watcher already running\n",stderr);return 2;}
        if(!RegisterHotKey(nullptr,1,native_modifiers(shortcut),UINT(shortcut.letter))) {
            std::fprintf(stderr,"recall shortcut unavailable: %lu\n",GetLastError());CloseHandle(singleton);return 3;
        }
        HANDLE owner=parent?OpenProcess(SYNCHRONIZE,FALSE,parent):nullptr;
        if(parent&&!owner) {UnregisterHotKey(nullptr,1);CloseHandle(singleton);return 4;}
        HANDLE request=CreateEventW(nullptr,FALSE,FALSE,L"Local\\ViewflowRecallRequest");
        const auto timer=SetTimer(nullptr,0,250,nullptr);
        std::printf("recall ready shortcut=%s\n",vr::format_shortcut(shortcut).c_str());std::fflush(stdout);
        MSG message{};
        while(GetMessageW(&message,nullptr,0,0)>0) {
            if(owner&&WaitForSingleObject(owner,0)!=WAIT_TIMEOUT)break;
            if(message.message==WM_HOTKEY)recall(false);
            else if(message.message==WM_TIMER) {
                observe_focus(physical_screens());
                if(request&&WaitForSingleObject(request,0)==WAIT_OBJECT_0)recall(false);
            }
        }
        if(request)CloseHandle(request);
        if(owner)CloseHandle(owner);KillTimer(nullptr,timer);UnregisterHotKey(nullptr,1);CloseHandle(singleton);return 0;
    } catch(const std::exception& e) {std::fprintf(stderr,"recall: %s\n",e.what());return 1;}
}
