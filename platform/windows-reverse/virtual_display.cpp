#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <devguid.h>
#include <cstdio>
#include <string>
#include <vector>
#include <cstring>
#include <cwchar>
// Installs one PnP instance using an independently signed driver package. It
// never adds certificates or alters Windows driver-signature policy.
int wmain(int argc,wchar_t** argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
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
