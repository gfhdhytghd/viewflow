#define NOMINMAX
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include "pipe.hpp"
#include "windows_keys.hpp"
#include "scroll.hpp"
#include "../reverse-common/scroll_units.hpp"
namespace h=viewflow::handoff;
namespace {
constexpr ULONG_PTR marker=0x56464831;
constexpr UINT command_message=WM_APP+71;
h::Core* core{};h::Output* output{};
RECT previous_clip{};
POINT last{},anchor{},saved{};bool positioned=false;
DWORD main_thread{};
double scale_x=1,scale_y=1;
h::ScrollAccumulator scroll;
void post(h::Input e) {
    INPUT v{};
    if(h::kind(e)==4) {
        const auto key=h::windows_scan(e.a);if(!key)throw std::runtime_error("unsupported physical key");
        v.type=INPUT_KEYBOARD;v.ki.wScan=WORD(key->scan);v.ki.dwExtraInfo=marker;
        v.ki.wVk=key->virtual_key;
        v.ki.dwFlags=(key->virtual_key?0:KEYEVENTF_SCANCODE)|(key->extended?KEYEVENTF_EXTENDEDKEY:0)|(e.b?0:KEYEVENTF_KEYUP);
    } else {
        v.type=INPUT_MOUSE;v.mi.dwExtraInfo=marker;
        if(h::kind(e)==1) {
            const double x=(e.a/1000.0+core->local.x)*scale_x,y=(e.b/1000.0+core->local.y)*scale_y;
            const int vx=GetSystemMetrics(SM_XVIRTUALSCREEN),vy=GetSystemMetrics(SM_YVIRTUALSCREEN);
            const int w=GetSystemMetrics(SM_CXVIRTUALSCREEN),height=GetSystemMetrics(SM_CYVIRTUALSCREEN);
            v.mi.dx=LONG(std::lround((x-vx)*65535.0/std::max(1,w-1)));
            v.mi.dy=LONG(std::lround((y-vy)*65535.0/std::max(1,height-1)));
            v.mi.dwFlags=MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK;
        } else if(h::kind(e)==2) {
            switch(e.a) {
            case 272:v.mi.dwFlags=e.b?MOUSEEVENTF_LEFTDOWN:MOUSEEVENTF_LEFTUP;break;
            case 273:v.mi.dwFlags=e.b?MOUSEEVENTF_RIGHTDOWN:MOUSEEVENTF_RIGHTUP;break;
            case 274:v.mi.dwFlags=e.b?MOUSEEVENTF_MIDDLEDOWN:MOUSEEVENTF_MIDDLEUP;break;
            case 275:case 276:v.mi.dwFlags=e.b?MOUSEEVENTF_XDOWN:MOUSEEVENTF_XUP;v.mi.mouseData=e.a==275?XBUTTON1:XBUTTON2;break;
            default:throw std::runtime_error("invalid button");
            }
        } else if(h::kind(e)==3) {
            // Precise milli-points -> wheel units (40 points per detent).
            v.mi.dwFlags=e.a?MOUSEEVENTF_HWHEEL:MOUSEEVENTF_WHEEL;
            v.mi.mouseData=DWORD(viewflow::reverse::scroll_from_windows(e.a!=0,scroll.convert(e.a,e.b,e.c!=0,true)));
        } else return;
    }
    if(SendInput(1,&v,sizeof(v))!=1)throw std::runtime_error("SendInput failed (desktop or integrity level unavailable)");
}
void capture(bool active) {
    if(active) {
        GetCursorPos(&saved);anchor=saved;GetClipCursor(&previous_clip);
        RECT clip{LONG(core->local.x*scale_x),LONG(core->local.y*scale_y),LONG((core->local.x+core->local.w)*scale_x),LONG((core->local.y+core->local.h)*scale_y)};
        if(!ClipCursor(&clip))throw std::runtime_error("ClipCursor failed");
        // Anchor inside the display: relative hook motion remains available
        // in both directions even when the OS would clamp at an outer edge.
        anchor.x=LONG((core->local.x+core->local.w/2)*scale_x);anchor.y=LONG((core->local.y+core->local.h/2)*scale_y);
        last=anchor;positioned=true;
        post(h::message(1,int((anchor.x/scale_x-core->local.x)*1000),int((anchor.y/scale_y-core->local.y)*1000)));
    } else {
        ClipCursor(&previous_clip);
        const double x=std::clamp(core->remote.x+core->x,core->local.x+1,core->local.x+core->local.w-2);
        const double y=std::clamp(core->remote.y+core->y,core->local.y+1,core->local.y+core->local.h-2);
        saved={LONG(x*scale_x),LONG(y*scale_y)};last=saved;
        post(h::message(1,int((x-core->local.x)*1000),int((y-core->local.y)*1000)));
    }
}
void fail() {try{core->reset();}catch(...){} try{output->send(h::message(h::fault));}catch(...){} }
LRESULT CALLBACK mouse(int code,WPARAM w,LPARAM l) {
    if(code<0)return CallNextHookEx(nullptr,code,w,l);
    const auto& e=*reinterpret_cast<MSLLHOOKSTRUCT*>(l);
    if((e.flags&LLMHF_INJECTED) || e.dwExtraInfo==marker)return CallNextHookEx(nullptr,code,w,l);
    try {
        bool swallow=false;
        if(w==WM_MOUSEMOVE) {
            const auto base=core->outgoing?anchor:last;
            const double dx=positioned?e.pt.x-base.x:0,dy=positioned?e.pt.y-base.y:0;
            last=e.pt;positioned=true;
            swallow=core->motion(e.pt.x/scale_x,e.pt.y/scale_y,dx/scale_x,dy/scale_y);
            // Swallowed events leave the system pointer at the anchor.
        } else if(w==WM_MOUSEWHEEL || w==WM_MOUSEHWHEEL) {
            swallow=core->input(h::message(3,w==WM_MOUSEHWHEEL,viewflow::reverse::scroll_from_windows(w==WM_MOUSEHWHEEL,SHORT(HIWORD(e.mouseData)))));
        } else {
            int button=0;bool down=false;
            switch(w) {
            case WM_LBUTTONDOWN:down=true;[[fallthrough]];case WM_LBUTTONUP:button=272;break;
            case WM_RBUTTONDOWN:down=true;[[fallthrough]];case WM_RBUTTONUP:button=273;break;
            case WM_MBUTTONDOWN:down=true;[[fallthrough]];case WM_MBUTTONUP:button=274;break;
            case WM_XBUTTONDOWN:down=true;[[fallthrough]];case WM_XBUTTONUP:button=HIWORD(e.mouseData)==XBUTTON1?275:276;break;
            }
            if(button)swallow=core->input(h::message(2,button,down));
        }
        if(swallow)return 1;
    }catch(...){fail();}
    return CallNextHookEx(nullptr,code,w,l);
}
LRESULT CALLBACK keyboard(int code,WPARAM w,LPARAM l) {
    if(code<0)return CallNextHookEx(nullptr,code,w,l);
    const auto& e=*reinterpret_cast<KBDLLHOOKSTRUCT*>(l);
    if((e.flags&LLKHF_INJECTED) || e.dwExtraInfo==marker)return CallNextHookEx(nullptr,code,w,l);
    try {
        const auto key=h::evdev_key(e.vkCode,e.scanCode,(e.flags&LLKHF_EXTENDED)!=0);
        if(key && core->input(h::message(4,int(key),w==WM_KEYDOWN || w==WM_SYSKEYDOWN)))return 1;
        if(core->outgoing)return 1;
    }catch(...){fail();}
    return CallNextHookEx(nullptr,code,w,l);
}
}
int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--self-test")return h::self_test();
        const auto [local,remote]=h::geometry(argc,argv);
        SetConsoleCtrlHandler([](DWORD event)->BOOL {
            if(event==CTRL_C_EVENT || event==CTRL_BREAK_EVENT)return TRUE; // parent closes stdin
            PostThreadMessageW(main_thread,WM_QUIT,0,0);return TRUE;
        },TRUE);
        SetProcessDPIAware();_setmode(0,_O_BINARY);_setmode(1,_O_BINARY);
        h::Core state(local,remote);core=&state;
        scale_x=GetSystemMetrics(SM_CXSCREEN)/local.w;scale_y=GetSystemMetrics(SM_CYSCREEN)/local.h;
        for(unsigned code=1;code<256;++code)if(const auto scan=h::windows_scan(code)) {
            const auto vk=scan->virtual_key?scan->virtual_key:MapVirtualKeyW(scan->scan|(scan->extended?0xe000:0),MAPVK_VSC_TO_VK_EX);
            if(vk && (GetAsyncKeyState(int(vk))&0x8000))state.physicalKeys.insert(int(code));
        }
        for(auto [vk,button]:{std::pair{VK_LBUTTON,272},std::pair{VK_RBUTTON,273},std::pair{VK_MBUTTON,274},std::pair{VK_XBUTTON1,275},std::pair{VK_XBUTTON2,276}})
            if(GetAsyncKeyState(vk)&0x8000)state.physicalButtons.insert(button);
        h::Output writer;output=&writer;main_thread=GetCurrentThreadId();
        MSG msg{};PeekMessageW(&msg,nullptr,0,0,PM_NOREMOVE);
        writer.failed=[] {PostThreadMessageW(main_thread,WM_QUIT,0,0);};
        state.send=[&](h::Input e){writer.send(e);};state.inject=post;state.capture=capture;
        HHOOK mh=SetWindowsHookExW(WH_MOUSE_LL,mouse,GetModuleHandleW(nullptr),0);
        HHOOK kh=SetWindowsHookExW(WH_KEYBOARD_LL,keyboard,GetModuleHandleW(nullptr),0);
        if(!mh || !kh)std::fprintf(stderr,"handoff sender unavailable: desktop hooks; receiver remains available\n");
        writer.send(h::message(h::capabilities,mh && kh,1));
        std::thread reader([] {
            try {
                std::vector<uint8_t> bytes;
                while(viewflow::reverse::read_record(0,bytes)) {
                    auto e=new h::Input(h::decode(bytes));
                    if(!PostThreadMessageW(main_thread,command_message,0,reinterpret_cast<LPARAM>(e))){delete e;break;}
                }
            }catch(...){}
            PostThreadMessageW(main_thread,WM_QUIT,0,0);
        });
        while(GetMessageW(&msg,nullptr,0,0)>0) {
            if(msg.message==command_message) {
                std::unique_ptr<h::Input> e(reinterpret_cast<h::Input*>(msg.lParam));
                try{state.command(*e);}catch(...){fail();}
            }
        }
        state.reset();UnhookWindowsHookEx(mh);UnhookWindowsHookEx(kh);
        CancelSynchronousIo(reader.native_handle());reader.join();return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"handoff unavailable: %s\n",e.what());return 1;}
}
