// Read-only interactive display topology. No window, input or display mutation.
#include <windows.h>
#include <shellapi.h>
#include <cstdio>
#include <vector>
#include <cstdint>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(!argv || argc!=2)return 2;
  FILE* log=nullptr;_wfopen_s(&log,argv[1],L"w");LocalFree(argv);if(!log)return 2;
  setvbuf(log,nullptr,_IOLBF,4096);
  auto before=GetForegroundWindow();
  std::fprintf(log,"display-probe pid=%lu foreground=%p input_injected=0 mutation=0\n",GetCurrentProcessId(),before);
  EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR h,HDC,LPRECT r,LPARAM opaque)->BOOL {
    auto f=reinterpret_cast<FILE*>(opaque);MONITORINFOEXW m{sizeof(m)};GetMonitorInfoW(h,&m);
    DEVMODEW d{ };d.dmSize=sizeof(d);EnumDisplaySettingsW(m.szDevice,ENUM_CURRENT_SETTINGS,&d);
    std::fprintf(f,"monitor device=%ls rect=%ld,%ld,%ld,%ld primary=%u mode=%lux%lu hz=%lu orientation=%lu\n",m.szDevice,r->left,r->top,r->right,r->bottom,unsigned((m.dwFlags&MONITORINFOF_PRIMARY)!=0),d.dmPelsWidth,d.dmPelsHeight,d.dmDisplayFrequency,d.dmDisplayOrientation);
    return TRUE;
  },reinterpret_cast<LPARAM>(log));
  for(DWORD i=0;;++i){DISPLAY_DEVICEW d{sizeof(d)};if(!EnumDisplayDevicesW(nullptr,i,&d,0))break;
    std::fprintf(log,"adapter device=%ls name=%ls flags=%lu id=%ls\n",d.DeviceName,d.DeviceString,d.StateFlags,d.DeviceID);
    for(DWORD j=0;;++j){DISPLAY_DEVICEW m{sizeof(m)};if(!EnumDisplayDevicesW(d.DeviceName,j,&m,EDD_GET_DEVICE_INTERFACE_NAME))break;
      std::fprintf(log,"display device=%ls name=%ls flags=%lu id=%ls\n",m.DeviceName,m.DeviceString,m.StateFlags,m.DeviceID);
    }
    for(DWORD j=0;;++j){DEVMODEW m{};m.dmSize=sizeof(m);if(!EnumDisplaySettingsW(d.DeviceName,j,&m))break;
      if(m.dmPelsWidth==3840 && (m.dmPelsHeight==2160 || m.dmPelsHeight==2400))std::fprintf(log,"mode device=%ls pixels=%lux%lu hz=%lu orientation=%lu\n",d.DeviceName,m.dmPelsWidth,m.dmPelsHeight,m.dmDisplayFrequency,m.dmDisplayOrientation);
    }
  }
  UINT32 pc=0,mc=0;LONG result=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&pc,&mc);
  if(result!=ERROR_SUCCESS){std::fprintf(log,"config_error=%ld\n",result);fclose(log);return 3;}
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(pc);std::vector<DISPLAYCONFIG_MODE_INFO> modes(mc);
  result=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&pc,paths.data(),&mc,modes.data(),nullptr);
  if(result!=ERROR_SUCCESS){std::fprintf(log,"query_error=%ld\n",result);fclose(log);return 4;}
  std::fprintf(log,"active_paths=%u modes=%u\n",pc,mc);
  for(UINT32 i=0;i<pc;++i){auto const&p=paths[i];
    DISPLAYCONFIG_SOURCE_DEVICE_NAME s{};s.header={DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,sizeof(s),p.sourceInfo.adapterId,p.sourceInfo.id};DisplayConfigGetDeviceInfo(&s.header);
    DISPLAYCONFIG_TARGET_DEVICE_NAME t{};t.header={DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,sizeof(t),p.targetInfo.adapterId,p.targetInfo.id};DisplayConfigGetDeviceInfo(&t.header);
    std::fprintf(log,"path index=%u source=%ls source_id=%u target_id=%u target=%ls technology=%u target_available=%u rotation=%u scaling=%u refresh=%u/%u flags=%u\n",i,s.viewGdiDeviceName,p.sourceInfo.id,p.targetInfo.id,t.monitorFriendlyDeviceName,unsigned(p.targetInfo.outputTechnology),unsigned(p.targetInfo.targetAvailable),unsigned(p.targetInfo.rotation),unsigned(p.targetInfo.scaling),p.targetInfo.refreshRate.Numerator,p.targetInfo.refreshRate.Denominator,p.flags);
    if(p.sourceInfo.modeInfoIdx<mc){auto const&m=modes[p.sourceInfo.modeInfoIdx];if(m.infoType==DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE)std::fprintf(log,"source index=%u rect=%ld,%ld,%u,%u format=%u\n",i,m.sourceMode.position.x,m.sourceMode.position.y,m.sourceMode.width,m.sourceMode.height,unsigned(m.sourceMode.pixelFormat));}
    if(p.targetInfo.modeInfoIdx<mc){auto const&m=modes[p.targetInfo.modeInfoIdx];if(m.infoType==DISPLAYCONFIG_MODE_INFO_TYPE_TARGET){auto const&v=m.targetMode.targetVideoSignalInfo;std::fprintf(log,"signal index=%u active=%ux%u total=%ux%u vfreq=%u/%u pixclock=%llu\n",i,v.activeSize.cx,v.activeSize.cy,v.totalSize.cx,v.totalSize.cy,v.vSyncFreq.Numerator,v.vSyncFreq.Denominator,v.pixelRate);}}
  }
  std::fprintf(log,"foreground_unchanged=%u exit=0\n",unsigned(before==GetForegroundWindow()));fclose(log);return 0;
}
