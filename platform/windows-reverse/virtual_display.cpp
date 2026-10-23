#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <devguid.h>
#include <cstdio>
#include <string>
#include <vector>
#include <cstring>
#include <cwchar>
#include <algorithm>
#include <cstdint>
#include "virtual_display_transient.hpp"
namespace {
bool virtualAdapter(const std::wstring& selected) {
    for(DWORD index=0;;++index) {
        DISPLAY_DEVICEW device{};device.cb=sizeof(device);
        if(!EnumDisplayDevicesW(nullptr,index,&device,0))break;
        if(selected==device.DeviceName && wcsstr(device.DeviceString,L"Virtual"))return true;
    }
    return false;
}
// Translate the entire active layout so the selected virtual display is primary.
// Preserve modes and relative adjacency; roll back staged changes on failure.
int primary(const std::wstring& selected) {
    if(!virtualAdapter(selected))return 6;
    struct Display { std::wstring name; DEVMODEW before,after; bool primary; };
    std::vector<Display> displays;
    POINTL origin{}; bool found=false;
    for(DWORD i=0;;++i) {
        DISPLAY_DEVICEW d{};d.cb=sizeof(d);
        if(!EnumDisplayDevicesW(nullptr,i,&d,0))break;
        if(!(d.StateFlags&DISPLAY_DEVICE_ATTACHED_TO_DESKTOP))continue;
        DEVMODEW m{};m.dmSize=sizeof(m);
        if(!EnumDisplaySettingsW(d.DeviceName,ENUM_CURRENT_SETTINGS,&m))return 9;
        displays.push_back({d.DeviceName,m,m,bool(d.StateFlags&DISPLAY_DEVICE_PRIMARY_DEVICE)});
        std::wprintf(L"before %ls primary=%d position=%ld,%ld size=%lux%lu hz=%lu\n",
            d.DeviceName,displays.back().primary,m.dmPosition.x,m.dmPosition.y,m.dmPelsWidth,m.dmPelsHeight,m.dmDisplayFrequency);
        if(selected==d.DeviceName){origin=m.dmPosition;found=true;}
    }
    if(!found)return 10;
    for(auto& d:displays) {
        d.after.dmPosition.x-=origin.x;d.after.dmPosition.y-=origin.y;
        d.before.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFREQUENCY;
        d.after.dmFields=d.before.dmFields;

    }
    auto apply=[&](bool restore) {
        bool ok=true;
        // Stage the primary first, then every other display, and apply once.
        for(int pass=0;pass<2;++pass)for(auto& d:displays) {
            const bool isPrimary=restore?d.primary:d.name==selected;
            if(isPrimary!=(pass==0))continue;
            auto& m=restore?d.before:d.after;
            const auto result=ChangeDisplaySettingsExW(d.name.c_str(),&m,nullptr,
                CDS_UPDATEREGISTRY|CDS_NORESET|(isPrimary?CDS_SET_PRIMARY:0),nullptr);
            if(result!=DISP_CHANGE_SUCCESSFUL)ok=false;
        }
        return ChangeDisplaySettingsExW(nullptr,nullptr,nullptr,0,nullptr)==DISP_CHANGE_SUCCESSFUL && ok;
    };
    bool ok=apply(false);
    for(const auto& d:displays) {
        DEVMODEW actual{};actual.dmSize=sizeof(actual);
        const bool read=EnumDisplaySettingsW(d.name.c_str(),ENUM_CURRENT_SETTINGS,&actual);
        ok=ok && read && actual.dmPosition.x==d.after.dmPosition.x && actual.dmPosition.y==d.after.dmPosition.y &&
            actual.dmPelsWidth==d.before.dmPelsWidth && actual.dmPelsHeight==d.before.dmPelsHeight && actual.dmDisplayFrequency==d.before.dmDisplayFrequency;
    }
    DISPLAY_DEVICEW check{};check.cb=sizeof(check);bool primaryVerified=false;
    for(DWORD i=0;EnumDisplayDevicesW(nullptr,i,&check,0);++i) {
        if(selected==check.DeviceName && (check.StateFlags&DISPLAY_DEVICE_PRIMARY_DEVICE))primaryVerified=true;
        check={};check.cb=sizeof(check);
    }
    if(!ok || !primaryVerified){std::fprintf(stderr,"primary verification failed rollback=%d\n",apply(true));return 8;}
    std::wprintf(L"primary_verified=%ls origin=0,0 modes_preserved=1\n",selected.c_str());return 0;
}
// Windows Settings uses these source DPI packet types. Validate their layout
// and the driver's returned range before writing only the selected VDD source.
struct DpiGet { DISPLAYCONFIG_DEVICE_INFO_HEADER header; std::int32_t minimum,current,maximum; };
struct DpiSet { DISPLAYCONFIG_DEVICE_INFO_HEADER header; std::int32_t scale; };
static_assert(sizeof(DpiGet)==32 && sizeof(DpiSet)==24);
int dpi(const std::wstring& selected,int percent) {
    if(!virtualAdapter(selected))return 6;
    UINT32 pathCount{},modeCount{};
    auto result=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&pathCount,&modeCount);
    if(result!=ERROR_SUCCESS)return 9;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
    result=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&pathCount,paths.data(),&modeCount,modes.data(),nullptr);
    if(result!=ERROR_SUCCESS)return 10;
    constexpr int scales[]{100,125,150,175,200,225,250,300,350,400,450,500};
    for(UINT32 index=0;index<pathCount;++index) {
        const auto& source=paths[index].sourceInfo;
        DISPLAYCONFIG_SOURCE_DEVICE_NAME name{};
        name.header={DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,sizeof(name),source.adapterId,source.id};
        if(DisplayConfigGetDeviceInfo(&name.header)!=ERROR_SUCCESS || selected!=name.viewGdiDeviceName)continue;
        DpiGet get{};get.header={static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(-3),sizeof(get),source.adapterId,source.id};
        if(DisplayConfigGetDeviceInfo(&get.header)!=ERROR_SUCCESS)return 11;
        const auto current=std::int64_t(get.current)-get.minimum;
        if(current<0 || current>=std::size(scales) || get.minimum>0 || get.maximum<0)return 12;
        std::wprintf(L"%ls dpi_before=%d recommended_step=%d\n",selected.c_str(),scales[current],-get.minimum);
        if(percent==0)return 0;
        const auto desired=std::find(std::begin(scales),std::end(scales),percent);
        if(desired==std::end(scales))return 13;
        const auto step=static_cast<int>(desired-std::begin(scales))+get.minimum;
        if(step<get.minimum || step>get.maximum)return 14;
        DpiSet set{};set.header={static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(-4),sizeof(set),source.adapterId,source.id};set.scale=step;
        result=DisplayConfigSetDeviceInfo(&set.header);
        if(result!=ERROR_SUCCESS){std::fprintf(stderr,"virtual DPI set=%ld\n",result);return 15;}
        if(DisplayConfigGetDeviceInfo(&get.header)!=ERROR_SUCCESS || get.current!=step)return 16;
        std::wprintf(L"%ls dpi_verified=%d\n",selected.c_str(),percent);return 0;
    }
    return 17;
}
}
// Installs one PnP instance using an independently signed driver package. It
// never adds certificates or alters Windows driver-signature policy.
int wmain(int argc,wchar_t** argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if(argc>=2 && std::wcsncmp(argv[1],L"transient-",10)==0){
        namespace transient=viewflow::display_transient;
        try{
            if(argc==4 && !std::wcscmp(argv[1],L"transient-backup")){
                if(!virtualAdapter(argv[2]))return 6;transient::save(argv[2],argv[3]);return 0;
            }
            if(argc==3 && !std::wcscmp(argv[1],L"transient-restore")){const auto backup=transient::load(argv[2]);if(!virtualAdapter(backup.displays[backup.selected].name))return 6;return transient::restore(backup)?0:9;}
            if(argc==8 && (!std::wcscmp(argv[1],L"transient-test")||!std::wcscmp(argv[1],L"transient-apply"))){
                const auto backup=transient::load(argv[2]);
                if(!virtualAdapter(backup.displays[backup.selected].name))return 6;
                return transient::change(backup,static_cast<LONG>(transient::integer(argv[3],LONG_MIN,LONG_MAX)),
                    static_cast<LONG>(transient::integer(argv[4],LONG_MIN,LONG_MAX)),
                    static_cast<DWORD>(transient::integer(argv[5],1,16384)),static_cast<DWORD>(transient::integer(argv[6],1,16384)),
                    static_cast<DWORD>(transient::integer(argv[7],1,1000)),!std::wcscmp(argv[1],L"transient-apply"));
            }
            std::fprintf(stderr,"usage: transient-backup DISPLAY FILE | transient-test/apply FILE X Y WIDTH HEIGHT HZ | transient-restore FILE\n");return 2;
        }catch(const std::exception& error){std::fprintf(stderr,"transient display: %s\n",error.what());return 9;}
    }

    if(argc==3 && wcscmp(argv[1],L"primary")==0)return primary(argv[2]);
    if(argc==4 && (wcscmp(argv[1],L"test-refresh")==0 || wcscmp(argv[1],L"refresh")==0)) {
        const std::wstring selected=argv[2];if(!virtualAdapter(selected))return 6;
        DEVMODEW mode{};mode.dmSize=sizeof(mode);
        if(!EnumDisplaySettingsW(selected.c_str(),ENUM_CURRENT_SETTINGS,&mode))return 9;
        const auto hz=std::stoul(argv[3]);if(!hz || hz>1000)return 10;
        const auto previous=mode.dmDisplayFrequency;
        mode.dmFields=DM_DISPLAYFREQUENCY;mode.dmDisplayFrequency=hz;
        const auto result=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,CDS_TEST,nullptr);
        std::wprintf(L"%ls refresh_test=%lu previous=%lu result=%ld applied=0\n",selected.c_str(),hz,previous,result);
        if(result!=DISP_CHANGE_SUCCESSFUL)return 7;
        if(wcscmp(argv[1],L"test-refresh")==0)return 0;
        const auto applied=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,0,nullptr);
        if(applied!=DISP_CHANGE_SUCCESSFUL)return 8;
        DEVMODEW actual{};actual.dmSize=sizeof(actual);
        if(!EnumDisplaySettingsW(selected.c_str(),ENUM_CURRENT_SETTINGS,&actual) || actual.dmDisplayFrequency!=hz)return 9;
        std::wprintf(L"%ls refresh_verified=%lu transient=1\n",selected.c_str(),actual.dmDisplayFrequency);
        return 0;
    }
    if(argc==3 && wcscmp(argv[1],L"modes")==0) {
        // Read-only capability inventory; never apply a mode from this path.
        for(DWORD index=0;;++index) {
            DEVMODEW mode{};mode.dmSize=sizeof(mode);
            if(!EnumDisplaySettingsW(argv[2],index,&mode))break;
            std::wprintf(L"%ls mode=%lu %lux%lu refresh_hz=%lu bpp=%lu\n",argv[2],index,mode.dmPelsWidth,mode.dmPelsHeight,mode.dmDisplayFrequency,mode.dmBitsPerPel);
        }
        return 0;
    }
    if((argc==3 || argc==4) && wcscmp(argv[1],L"dpi")==0)return dpi(argv[2],argc==4?std::stoi(argv[3]):0);
    if(argc==3 && wcscmp(argv[1],L"install")==0) {
        HDEVINFO set=SetupDiCreateDeviceInfoList(&GUID_DEVCLASS_DISPLAY,nullptr);
        if(set==INVALID_HANDLE_VALUE)return 2;
        SP_DEVINFO_DATA device{};device.cbSize=sizeof(device);
        wchar_t klass[128]{};SetupDiClassNameFromGuidW(&GUID_DEVCLASS_DISPLAY,klass,128,nullptr);
        if(!SetupDiCreateDeviceInfoW(set,klass,&GUID_DEVCLASS_DISPLAY,L"Viewflow virtual display",nullptr,DICD_GENERATE_ID,&device)){std::fprintf(stderr,"create device=%lu\n",GetLastError());SetupDiDestroyDeviceInfoList(set);return 3;}
        const wchar_t hardware[]=L"Root\\MttVDD\0";
        bool registered=false;
        if(SetupDiSetDeviceRegistryPropertyW(set,&device,SPDRP_HARDWAREID,reinterpret_cast<const BYTE*>(hardware),sizeof(hardware)) &&
           SetupDiCallClassInstaller(DIF_REGISTERDEVICE,set,&device))registered=true;
        if(!registered){std::fprintf(stderr,"register device=%lu\n",GetLastError());SetupDiDestroyDeviceInfoList(set);return 4;}
        BOOL reboot=FALSE;
        if(!UpdateDriverForPlugAndPlayDevicesW(nullptr,L"Root\\MttVDD",argv[2],0,&reboot)) {
            const auto error=GetLastError();SetupDiCallClassInstaller(DIF_REMOVE,set,&device);SetupDiDestroyDeviceInfoList(set);
            std::fprintf(stderr,"signed driver install rejected=%lu\n",error);return 5;
        }
        wchar_t instance[512]{};SetupDiGetDeviceInstanceIdW(set,&device,instance,512,nullptr);
        std::wprintf(L"installed_instance=%ls reboot=%u\n",instance,reboot);SetupDiDestroyDeviceInfoList(set);return 0;
    }
    if(argc==7 && wcscmp(argv[1],L"configure")==0) {
        const std::wstring selected=argv[2];
        bool found=false;
        for(DWORD index=0;;++index){DISPLAY_DEVICEW device{};device.cb=sizeof(device);if(!EnumDisplayDevicesW(nullptr,index,&device,0))break;
            if(selected==device.DeviceName && wcsstr(device.DeviceString,L"Virtual")){found=true;break;}}
        if(!found){std::fprintf(stderr,"selected display is not a virtual adapter\n");return 6;}
        DEVMODEW mode{};mode.dmSize=sizeof(mode);EnumDisplaySettingsW(selected.c_str(),ENUM_CURRENT_SETTINGS,&mode);
        mode.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFREQUENCY;
        mode.dmPosition.x=std::stoi(argv[3]);mode.dmPosition.y=std::stoi(argv[4]);mode.dmPelsWidth=std::stoul(argv[5]);mode.dmPelsHeight=std::stoul(argv[6]);mode.dmBitsPerPel=32;mode.dmDisplayFrequency=60;
        auto result=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,CDS_TEST,nullptr);
        if(result!=DISP_CHANGE_SUCCESSFUL){std::fprintf(stderr,"virtual mode test=%ld\n",result);return 7;}
        result=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,CDS_UPDATEREGISTRY|CDS_NORESET,nullptr);
        if(result==DISP_CHANGE_SUCCESSFUL)result=ChangeDisplaySettingsExW(nullptr,nullptr,nullptr,0,nullptr);
        std::fprintf(stderr,"virtual display layout result=%ld\n",result);return result==DISP_CHANGE_SUCCESSFUL?0:8;
    }
    for(DWORD index=0;;++index){DISPLAY_DEVICEW device{};device.cb=sizeof(device);if(!EnumDisplayDevicesW(nullptr,index,&device,0))break;
        DEVMODEW mode{};mode.dmSize=sizeof(mode);EnumDisplaySettingsW(device.DeviceName,ENUM_CURRENT_SETTINGS,&mode);
        std::wprintf(L"%ls | %ls | flags=%lu | %ld,%ld %lux%lu refresh_hz=%lu\n",device.DeviceName,device.DeviceString,device.StateFlags,mode.dmPosition.x,mode.dmPosition.y,mode.dmPelsWidth,mode.dmPelsHeight,mode.dmDisplayFrequency);}
    return 0;
}
