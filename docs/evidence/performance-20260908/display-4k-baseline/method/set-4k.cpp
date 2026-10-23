// Apply the user-requested 4K baseline to the sole active virtual display.
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <cstdio>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
 SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
 int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv||argc!=2)return 2;
 FILE*f=nullptr;_wfopen_s(&f,argv[1],L"w");LocalFree(argv);if(!f)return 2;setvbuf(f,nullptr,_IOLBF,4096);
 std::wstring selected;unsigned active=0;
 for(DWORD i=0;;++i){DISPLAY_DEVICEW d{sizeof(d)};if(!EnumDisplayDevicesW(nullptr,i,&d,0))break;
  if(d.StateFlags&DISPLAY_DEVICE_ATTACHED_TO_DESKTOP){++active;if(wcsstr(d.DeviceString,L"Virtual Display"))selected=d.DeviceName;}}
 if(active!=1||selected.empty()){std::fprintf(f,"active=%u selected=%ls unexpected topology; no display mutation\n",active,selected.c_str());fclose(f);return 3;}
 DEVMODEW before{};before.dmSize=sizeof(before);if(!EnumDisplaySettingsW(selected.c_str(),ENUM_CURRENT_SETTINGS,&before)){fclose(f);return 4;}
 std::fprintf(f,"before device=%ls pixels=%lux%lu hz=%lu position=%ld,%ld\n",selected.c_str(),before.dmPelsWidth,before.dmPelsHeight,before.dmDisplayFrequency,before.dmPosition.x,before.dmPosition.y);
 DEVMODEW mode=before;mode.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFREQUENCY;mode.dmPelsWidth=3840;mode.dmPelsHeight=2400;mode.dmDisplayFrequency=60;mode.dmBitsPerPel=32;
 LONG result=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,CDS_TEST,nullptr);std::fprintf(f,"test_result=%ld\n",result);if(result!=DISP_CHANGE_SUCCESSFUL){fclose(f);return 5;}
 result=ChangeDisplaySettingsExW(selected.c_str(),&mode,nullptr,CDS_UPDATEREGISTRY,nullptr);std::fprintf(f,"apply_result=%ld\n",result);if(result!=DISP_CHANGE_SUCCESSFUL){fclose(f);return 6;}
 DEVMODEW after{};after.dmSize=sizeof(after);bool ok=EnumDisplaySettingsW(selected.c_str(),ENUM_CURRENT_SETTINGS,&after)&&after.dmPelsWidth==3840&&after.dmPelsHeight==2400&&after.dmDisplayFrequency==60;
 std::fprintf(f,"after device=%ls pixels=%lux%lu hz=%lu input_injected=0\n",selected.c_str(),after.dmPelsWidth,after.dmPelsHeight,after.dmDisplayFrequency);
 if(!ok)std::fprintf(f,"rollback_result=%ld\n",ChangeDisplaySettingsExW(selected.c_str(),&before,nullptr,CDS_UPDATEREGISTRY,nullptr));
 std::fprintf(f,"exit=%d\n",ok?0:7);fclose(f);return ok?0:7;
}
