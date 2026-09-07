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
namespace {
bool virtualAdapter(const std::wstring& selected) {
    for(DWORD index=0;;++index) {
        DISPLAY_DEVICEW device{};device.cb=sizeof(device);
        if(!EnumDisplayDevicesW(nullptr,index,&device,0))break;
        if(selected==device.DeviceName && wcsstr(device.DeviceString,L"Virtual"))return true;
    }
    return false;
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
        std::wprintf(L"%ls | %ls | flags=%lu | %ld,%ld %lux%lu\n",device.DeviceName,device.DeviceString,device.StateFlags,mode.dmPosition.x,mode.dmPosition.y,mode.dmPelsWidth,mode.dmPelsHeight);}
    return 0;
}
