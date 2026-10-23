#pragma once
#include <windows.h>
#include "virtual_display_transient_checks.hpp"
#include <vector>
#include <set>
#include <string>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <stdexcept>
#include <limits>
#include <cstdint>
#include <climits>

namespace viewflow::display_transient {
// Local, versioned Windows backup; not a network wire format. Save the complete
// public DEVMODE returned by EnumDisplaySettings, including dmFields. Private
// driver bytes are not silently truncated if a driver reports any.
struct Record {
    wchar_t name[CCHDEVICENAME]{};
    LUID source_adapter{},target_adapter{};
    UINT32 source_id{},target_id{};
    wchar_t monitor_path[128]{};
    DWORD primary{};
    DEVMODEW mode{};
};
struct Backup {std::vector<Record> displays;std::uint32_t selected{};};
struct Header {char magic[8];std::uint32_t version,record_size,count,selected;};
inline bool luid(LUID a,LUID b){return a.HighPart==b.HighPart&&a.LowPart==b.LowPart;}
inline bool identity(const Record& a,const Record& b){
    return !std::wcscmp(a.name,b.name)&&luid(a.source_adapter,b.source_adapter)&&luid(a.target_adapter,b.target_adapter)&&
        a.source_id==b.source_id&&a.target_id==b.target_id&&!std::wcscmp(a.monitor_path,b.monitor_path)&&a.primary==b.primary;
}
inline bool mode_equal(const DEVMODEW& a,const DEVMODEW& b){
    return a.dmPosition.x==b.dmPosition.x&&a.dmPosition.y==b.dmPosition.y&&a.dmPelsWidth==b.dmPelsWidth&&a.dmPelsHeight==b.dmPelsHeight&&
        a.dmBitsPerPel==b.dmBitsPerPel&&a.dmDisplayFrequency==b.dmDisplayFrequency&&a.dmDisplayFlags==b.dmDisplayFlags&&
        a.dmDisplayOrientation==b.dmDisplayOrientation&&a.dmDisplayFixedOutput==b.dmDisplayFixedOutput;
}
inline void require(bool okay,const char* message){if(!okay)throw std::runtime_error(message);}
struct File {
    HANDLE handle=INVALID_HANDLE_VALUE;
    ~File(){if(handle!=INVALID_HANDLE_VALUE)CloseHandle(handle);}
};
inline std::vector<Record> inventory(){
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    for(unsigned attempt=0;;++attempt){
        UINT32 np{},nm{};require(GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&np,&nm)==ERROR_SUCCESS,"display path sizing failed");
        paths.resize(np);std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
        const auto result=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&np,paths.data(),&nm,modes.data(),nullptr);
        if(result==ERROR_INSUFFICIENT_BUFFER&&attempt<3)continue;
        require(result==ERROR_SUCCESS,"display inventory changed or unavailable");paths.resize(np);break;
    }
    std::vector<Record> result;
    for(DWORD index=0;;++index){
        DISPLAY_DEVICEW device{};device.cb=sizeof(device);if(!EnumDisplayDevicesW(nullptr,index,&device,0))break;
        if(!(device.StateFlags&DISPLAY_DEVICE_ATTACHED_TO_DESKTOP))continue;
        Record record{};std::wmemcpy(record.name,device.DeviceName,CCHDEVICENAME);
        require(record.name[CCHDEVICENAME-1]==0,"display name too long");
        record.primary=!!(device.StateFlags&DISPLAY_DEVICE_PRIMARY_DEVICE);
        record.mode.dmSize=sizeof(DEVMODEW);
        require(EnumDisplaySettingsExW(record.name,ENUM_CURRENT_SETTINGS,&record.mode,0)!=FALSE,"current mode unavailable");
        require(record.mode.dmSize==sizeof(DEVMODEW)&&record.mode.dmDriverExtra==0,"private DEVMODE bytes cannot be backed up exactly");
        unsigned matches=0;
        for(const auto& path:paths){
            DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};source.header={DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,sizeof(source),path.sourceInfo.adapterId,path.sourceInfo.id};
            require(DisplayConfigGetDeviceInfo(&source.header)==ERROR_SUCCESS,"source identity unavailable");
            if(std::wcscmp(record.name,source.viewGdiDeviceName))continue;
            require(++matches==1,"clone source has multiple targets; transient tool requires one target");
            DISPLAYCONFIG_TARGET_DEVICE_NAME target{};target.header={DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,sizeof(target),path.targetInfo.adapterId,path.targetInfo.id};
            require(DisplayConfigGetDeviceInfo(&target.header)==ERROR_SUCCESS&&path.targetInfo.targetAvailable&&target.monitorDevicePath[0],"target identity unavailable");
            record.source_adapter=path.sourceInfo.adapterId;record.source_id=path.sourceInfo.id;
            record.target_adapter=path.targetInfo.adapterId;record.target_id=path.targetInfo.id;
            static_assert(sizeof(record.monitor_path)==sizeof(target.monitorDevicePath));
            std::memcpy(record.monitor_path,target.monitorDevicePath,sizeof(record.monitor_path));
            require(record.monitor_path[127]==0,"target path too long");
        }
        require(matches==1,"active output missing exact target identity");result.push_back(record);
    }
    require(!result.empty(),"no active outputs");return result;
}
inline const Record* find(const std::vector<Record>& records,const Record& selected){
    for(const auto& r:records)if(!std::wcscmp(r.name,selected.name))return &r;return nullptr;
}
inline bool matches(const Backup& backup,const std::vector<Record>& actual,const DEVMODEW* replacement=nullptr){
    if(actual.size()!=backup.displays.size())return false;
    for(std::size_t i=0;i<backup.displays.size();++i){
        const auto& expected=backup.displays[i];const auto* current=find(actual,expected);
        if(!current||!identity(expected,*current)||!mode_equal(replacement&&i==backup.selected?*replacement:expected.mode,current->mode))return false;
    }
    return true;
}
inline void save(const wchar_t* selected,const wchar_t* path){
    Backup backup;backup.displays=inventory();bool found=false;
    for(std::size_t i=0;i<backup.displays.size();++i)if(!std::wcscmp(backup.displays[i].name,selected)){
        require(!backup.displays[i].primary,"selected output is primary; transient tool never changes primary");backup.selected=static_cast<std::uint32_t>(i);found=true;
    }
    require(found,"selected output is not active");
    require(backup.displays.size()<=MAXDWORD/sizeof(Record),"backup too large");
    Header header{{'V','F','D','M','O','D','E','1'},1,sizeof(Record),static_cast<std::uint32_t>(backup.displays.size()),backup.selected};
    File file;file.handle=CreateFileW(path,GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    require(file.handle!=INVALID_HANDLE_VALUE,"backup file must be new and writable");
    DWORD written{};require(WriteFile(file.handle,&header,sizeof(header),&written,nullptr)&&written==sizeof(header),"backup header write failed");
    const auto bytes=backup.displays.size()*sizeof(Record);require(bytes<=MAXDWORD,"backup too large");
    require(WriteFile(file.handle,backup.displays.data(),static_cast<DWORD>(bytes),&written,nullptr)&&written==bytes&&FlushFileBuffers(file.handle),"backup write/flush failed");
    std::wprintf(L"transient_backup=%ls selected=%ls outputs=%zu exact_public_devmode=1 applied=0\n",path,selected,backup.displays.size());
}
inline Backup load(const wchar_t* path){
    File file;file.handle=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    require(file.handle!=INVALID_HANDLE_VALUE,"backup open failed");
    Header header{};DWORD read{};LARGE_INTEGER size{};
    require(ReadFile(file.handle,&header,sizeof(header),&read,nullptr)&&read==sizeof(header)&&GetFileSizeEx(file.handle,&size),"backup header read failed");
    require(!std::memcmp(header.magic,"VFDMODE1",8)&&header.version==1&&header.record_size==sizeof(Record)&&header.count&&header.selected<header.count,"backup format mismatch");
    require(size.QuadPart>=0,"backup length invalid");
    const auto bytes=checks::payload_bytes(header.count,header.selected,sizeof(Record),sizeof(header),static_cast<std::uint64_t>(size.QuadPart));
    Backup backup;backup.selected=header.selected;backup.displays.resize(header.count);
    require(ReadFile(file.handle,backup.displays.data(),static_cast<DWORD>(bytes),&read,nullptr)&&read==bytes,"backup data read failed");
    std::set<std::wstring> names;
    for(const auto& r:backup.displays){
        require(r.name[CCHDEVICENAME-1]==0&&r.monitor_path[127]==0&&r.name[0]&&r.monitor_path[0]&&r.primary<=1,"backup identity malformed");
        require(names.insert(r.name).second,"backup contains duplicate output name");
        require(r.mode.dmSize==sizeof(DEVMODEW)&&r.mode.dmDriverExtra==0&&r.mode.dmPelsWidth&&r.mode.dmPelsHeight,"backup mode malformed");
    }
    require(!backup.displays[backup.selected].primary,"backup selected primary is not supported");return backup;
}
inline bool restore(const Backup& backup){
    auto actual=inventory();
    // Resolve every saved identity before changing anything; a reused DISPLAYn
    // is not the original monitor. Primary state is never silently changed.
    require(actual.size()==backup.displays.size(),"restore topology differs from backup");
    for(const auto& r:backup.displays){const auto* current=find(actual,r);require(current&&identity(r,*current),"restore output identity changed");}
    bool applied=true;
    // Restore the selected output first. If the OS adjusted another non-primary
    // output as a side effect, restore that saved mode too, never SET_PRIMARY.
    std::vector<std::size_t> order{backup.selected};for(std::size_t i=0;i<backup.displays.size();++i)if(i!=backup.selected)order.push_back(i);
    for(const auto i:order){
        const auto& r=backup.displays[i];actual=inventory();const auto* current=find(actual,r);
        checks::before_mutation(r,current,identity);
        if(mode_equal(r.mode,current->mode))continue;
        if(r.primary){applied=false;continue;}
        auto mode=r.mode;
        // EnumDisplaySettings returns these public display values; ensure they
        // are consumed on restore even if the returned field mask omitted one.
        // Preserve optional driver-reported orientation/fixed-output mask bits.
        mode.dmFields=checks::restored_fields(mode.dmFields,DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFLAGS|DM_DISPLAYFREQUENCY);
        const auto result=ChangeDisplaySettingsExW(r.name,&mode,nullptr,0,nullptr);
        std::wprintf(L"transient_restore output=%ls result=%ld\n",r.name,result);applied=applied&&result==DISP_CHANGE_SUCCESSFUL;
    }
    const bool verified=matches(backup,inventory());
    std::printf("transient_restore applied=%u verified=%u registry_write=0 primary_requested=0\n",unsigned(applied),unsigned(verified));
    return applied&&verified;
}
inline int change(const Backup& backup,LONG x,LONG y,DWORD width,DWORD height,DWORD hz,bool apply){
    require(width&&height&&width<=16384&&height<=16384&&hz&&hz<=1000,"invalid transient dimensions/refresh");
    require(matches(backup,inventory()),"current layout no longer matches saved baseline");
    auto desired=backup.displays[backup.selected].mode;
    desired.dmFields|=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_DISPLAYFREQUENCY;
    desired.dmPosition={x,y};desired.dmPelsWidth=width;desired.dmPelsHeight=height;desired.dmDisplayFrequency=hz;
    const auto& selected=backup.displays[backup.selected];
    auto test=desired;const LONG tested=ChangeDisplaySettingsExW(selected.name,&test,nullptr,CDS_TEST,nullptr);
    std::wprintf(L"transient_test output=%ls position=%ld,%ld size=%lux%lu hz=%lu result=%ld applied=0\n",selected.name,x,y,width,height,hz,tested);
    bool test_unchanged=false;
    try{test_unchanged=matches(backup,inventory());}catch(const std::exception& error){std::fprintf(stderr,"transient test verification error=%s\n",error.what());}
    if(!test_unchanged){
        bool recovered=false;try{recovered=restore(backup);}catch(const std::exception& error){std::fprintf(stderr,"transient test rollback error=%s\n",error.what());}
        std::fprintf(stderr,"transient_test unexpectedly_changed=1 rollback_verified=%u\n",unsigned(recovered));return recovered?8:9;
    }
    if(tested!=DISP_CHANGE_SUCCESSFUL)return 7;if(!apply)return 0;
    bool verified=false,attempted=false;LONG result=DISP_CHANGE_FAILED;
    try{
        require(matches(backup,inventory()),"layout changed between test and apply");
        // Flags 0: immediate session-only application, no registry persistence.
        auto requested=desired;attempted=true;result=ChangeDisplaySettingsExW(selected.name,&requested,nullptr,0,nullptr);
        verified=result==DISP_CHANGE_SUCCESSFUL&&matches(backup,inventory(),&desired);
    }catch(const std::exception& error){std::fprintf(stderr,"transient verification error=%s\n",error.what());}
    if(!attempted){std::fprintf(stderr,"transient_apply attempted=0 baseline_changed=1 rollback_unnecessary=1\n");return 8;}
    if(verified){std::printf("transient_apply verified=1 other_outputs_unchanged=1 registry_write=0 primary_changed=0\n");return 0;}
    bool recovered=false;try{recovered=restore(backup);}catch(const std::exception& error){std::fprintf(stderr,"transient rollback error=%s\n",error.what());}
    std::fprintf(stderr,"transient_apply result=%ld verified=0 rollback_verified=%u\n",result,unsigned(recovered));return recovered?8:9;
}
inline long long integer(const wchar_t* text,long long low,long long high){
    std::size_t used{};const auto value=std::stoll(text,&used);require(used==std::wcslen(text)&&value>=low&&value<=high,"invalid integer argument");return value;
}
}
