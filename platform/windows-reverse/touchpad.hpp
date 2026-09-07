#pragma once
#include "../reverse-common/touchpad.hpp"
#include <windows.h>
#include <algorithm>
#include <vector>

namespace viewflow::reverse {
class TouchpadInjector {
    struct Parameters { POINTER_INPUT_TYPE type; ULONG count; POINTER_FEEDBACK_MODE feedback; HMONITOR monitor; ULONG width,height,options; };
    using Create=HSYNTHETICPOINTERDEVICE(WINAPI*)(const Parameters*);
    HSYNTHETICPOINTERDEVICE device{};
    TouchpadFrame previous{};
    bool inject(const std::vector<std::pair<TouchpadContact,bool>>& points) {
        if(points.empty())return true;
        std::vector<POINTER_TYPE_INFO> native(points.size());
        for(std::size_t i=0;i<points.size();++i){
            native[i].type=static_cast<POINTER_INPUT_TYPE>(5);
            auto& p=native[i].touchInfo.pointerInfo;
            p.pointerType=native[i].type;p.pointerId=points[i].first.id;
            p.pointerFlags=POINTER_FLAG_CONFIDENCE|(points[i].second?(POINTER_FLAG_INRANGE|POINTER_FLAG_INCONTACT):0);
            p.ptHimetricLocation={static_cast<LONG>(points[i].first.x),static_cast<LONG>(points[i].first.y)};
        }
        return InjectSyntheticPointerInput(device,native.data(),static_cast<UINT32>(native.size()))!=FALSE;
    }
public:
    ~TouchpadInjector(){release();if(device)DestroySyntheticPointerDevice(device);}
    bool release(){
        if(!device)return true;
        std::vector<std::pair<TouchpadContact,bool>> points;
        for(unsigned i=0;i<previous.count;++i)points.emplace_back(previous.contacts[i],false);
        if(!inject(points))return false;
        previous.count=0;return true;
    }
    bool apply(const TouchpadFrame& frame){
        if(device && (previous.width!=frame.width || previous.height!=frame.height)){
            if(!release())return false;DestroySyntheticPointerDevice(device);device=nullptr;
        }
        if(!device){
            if(!frame.count)return true;
            auto create=reinterpret_cast<Create>(GetProcAddress(GetModuleHandleW(L"user32.dll"),"CreateSyntheticPointerDevice2"));
            if(!create){SetLastError(ERROR_NOT_SUPPORTED);return false;}
            Parameters params{static_cast<POINTER_INPUT_TYPE>(5),5,POINTER_FEEDBACK_NONE,nullptr,frame.width,frame.height,3};
            device=create(&params);if(!device)return false;
            previous={frame.width,frame.height,0,{}};
        }
        std::vector<std::pair<TouchpadContact,bool>> lifts;
        TouchpadFrame survivors{frame.width,frame.height,0,{}};
        bool removed=false;
        for(unsigned i=0;i<previous.count;++i){
            auto p=std::find_if(frame.contacts.begin(),frame.contacts.begin()+frame.count,[&](const auto& c){return c.id==previous.contacts[i].id;});
            const bool held=p!=frame.contacts.begin()+frame.count;
            lifts.emplace_back(held?*p:previous.contacts[i],held);
            if(held)survivors.contacts[survivors.count++]=*p;else removed=true;
        }
        if(removed){if(!inject(lifts))return false;previous=survivors;}
        std::vector<std::pair<TouchpadContact,bool>> points;
        for(unsigned i=0;i<frame.count;++i)points.emplace_back(frame.contacts[i],true);
        if(!inject(points))return false;
        previous=frame;return true;
    }
};
}
