#define NOMINMAX
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include "pipe.hpp"
#include "windows_keys.hpp"
namespace h=viewflow::handoff;
namespace {
constexpr ULONG_PTR marker=0x56464831;
constexpr UINT command_message=WM_APP+71;
h::Core* core{};h::Output* output{};
RECT previous_clip{};
POINT last{},anchor{},saved{};bool positioned=false;
DWORD main_thread{};
void post(h::Input e) {
    INPUT v{};
    if(h::kind(e)==4) {
        const auto key=h::windows_scan(e.a);if(!key)throw std::runtime_error("unsupported physical key");
        v.type=INPUT_KEYBOARD;v.ki.wScan=WORD(key->first);v.ki.dwExtraInfo=marker;
        v.ki.dwFlags=KEYEVENTF_SCANCODE|(key->second?KEYEVENTF_EXTENDEDKEY:0)|(e.b?0:KEYEVENTF_KEYUP);
    } else {
        v.type=INPUT_MOUSE;v.mi.dwExtraInfo=marker;
        if(h::kind(e)==1) {
            const double x=e.a/1000.0+core->local.x,y=e.b/1000.0+core->local.y;
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
            v.mi.mouseData=DWORD(e.c?std::lround(e.b*120.0/40000.0):e.b);
        } else return;
    }
    if(SendInput(1,&v,sizeof(v))!=1)throw std::runtime_error("SendInput failed (desktop or integrity level unavailable)");
}
void capture(bool active) {
    if(active) {
        GetCursorPos(&saved);anchor=saved;GetClipCursor(&previous_clip);
        RECT clip{LONG(core->local.x),LONG(core->local.y),LONG(core->local.x+core->local.w),LONG(core->local.y+core->local.h)};
        if(!ClipCursor(&clip))throw std::runtime_error("ClipCursor failed");
        // Anchor inside the display: relative hook motion remains available
        // in both directions even when the OS would clamp at an outer edge.
        anchor.x=LONG(core->local.x+core->local.w/2);anchor.y=LONG(core->local.y+core->local.h/2);
        SetCursorPos(anchor.x,anchor.y);last=anchor;positioned=true;
    } else {
        ClipCursor(&previous_clip);
        saved.x=std::clamp(saved.x,LONG(core->local.x+1),LONG(core->local.x+core->local.w-2));
        saved.y=std::clamp(saved.y,LONG(core->local.y+1),LONG(core->local.y+core->local.h-2));
        SetCursorPos(saved.x,saved.y);last=saved;
    }
}
void fail() {try{core->reset();output->send(h::message(h::fault));}catch(...){} }
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
            swallow=core->motion(e.pt.x,e.pt.y,dx,dy);
            // Swallowed events leave the system pointer at the anchor.
        } else if(w==WM_MOUSEWHEEL || w==WM_MOUSEHWHEEL) {
            swallow=core->input(h::message(3,w==WM_MOUSEHWHEEL,SHORT(HIWORD(e.mouseData))));
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
        const auto key=h::evdev_scan(e.scanCode,(e.flags&LLKHF_EXTENDED)!=0);
        if(key && core->input(h::message(4,int(key),w==WM_KEYDOWN || w==WM_SYSKEYDOWN)))return 1;
    }catch(...){fail();}
    return CallNextHookEx(nullptr,code,w,l);
}
}
int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--self-test")return h::self_test();
        const auto [local,remote]=h::geometry(argc,argv);
        SetProcessDPIAware();_setmode(0,_O_BINARY);_setmode(1,_O_BINARY);
        h::Core state(local,remote);core=&state;
        h::Output writer;output=&writer;main_thread=GetCurrentThreadId();
        MSG msg{};PeekMessageW(&msg,nullptr,0,0,PM_NOREMOVE);
        writer.failed=[] {PostThreadMessageW(main_thread,WM_QUIT,0,0);};
        state.send=[&](h::Input e){writer.send(e);};state.inject=post;state.capture=capture;
        HHOOK mh=SetWindowsHookExW(WH_MOUSE_LL,mouse,GetModuleHandleW(nullptr),0);
        HHOOK kh=SetWindowsHookExW(WH_KEYBOARD_LL,keyboard,GetModuleHandleW(nullptr),0);
        if(!mh || !kh)throw std::runtime_error("desktop hooks unavailable");
        writer.send(h::message(h::capabilities,1,1));
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
