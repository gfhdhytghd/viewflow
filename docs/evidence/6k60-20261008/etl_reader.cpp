#define UNICODE
#define _UNICODE
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>
#include <cstdio>
#include <vector>
#include <map>
static const GUID dwm={0x9e9bba3c,0x2e38,0x40cb,{0x99,0xf4,0x9e,0x82,0x81,0x42,0x51,0x64}};
static const GUID dxg={0x802ec45a,0x1e99,0x4b83,{0x99,0x20,0x87,0xc9,0x82,0x77,0xba,0x9d}};
static bool select_dxg=false;
static unsigned long long total=0,selected=0;
static std::map<unsigned,unsigned long long> counts;
void WINAPI event(PEVENT_RECORD r){
 ++total;if(!IsEqualGUID(r->EventHeader.ProviderId,select_dxg?dxg:dwm))return;
 const auto id=r->EventHeader.EventDescriptor.Id;++counts[id];
 if(!select_dxg && !(id<=21 || id==253 || id==254 || id==255 || id==303 || id==304 || id==385 || id==386 || id==49 || id==50 || id==51 || id==157 || id==158 || id==183 || id==194 || id==195 || id==196))return;
 ++selected;
 std::printf("event id=%u opcode=%u version=%u pid=%lu tid=%lu timestamp=%lld bytes=%u payload=",id,r->EventHeader.EventDescriptor.Opcode,r->EventHeader.EventDescriptor.Version,r->EventHeader.ProcessId,r->EventHeader.ThreadId,r->EventHeader.TimeStamp.QuadPart,r->UserDataLength);
 for(unsigned i=0;i<r->UserDataLength;++i)std::printf("%02x",static_cast<unsigned char*>(r->UserData)[i]);
 std::printf("\n");
 static std::map<unsigned,bool> described;
 const unsigned key=id*65536+r->EventHeader.EventDescriptor.Version*256+r->EventHeader.EventDescriptor.Opcode;
 if(described[key])return;described[key]=true;
 ULONG size=0;auto status=TdhGetEventInformation(r,0,nullptr,nullptr,&size);
 if(status!=ERROR_INSUFFICIENT_BUFFER){std::fprintf(stderr,"schema id=%u status=%lu\n",id,status);return;}
 std::vector<unsigned char> bytes(size);auto* info=reinterpret_cast<PTRACE_EVENT_INFO>(bytes.data());status=TdhGetEventInformation(r,0,nullptr,info,&size);
 std::fprintf(stderr,"schema id=%u status=%lu properties=%lu top=%lu\n",id,status,status?0:info->PropertyCount,status?0:info->TopLevelPropertyCount);
 if(status)return;
 for(ULONG i=0;i<info->PropertyCount;++i){const auto& p=info->EventPropertyInfoArray[i];std::fprintf(stderr,"property id=%u index=%lu name=%ls flags=%lu in=%u out=%u count=%u length=%u\n",id,i,reinterpret_cast<wchar_t*>(bytes.data()+p.NameOffset),ULONG(p.Flags),p.nonStructType.InType,p.nonStructType.OutType,p.count,p.length);}
}
int wmain(int argc,wchar_t** argv){
 if(argc!=2 && !(argc==3 && wcscmp(argv[2],L"--dxg")==0))return 2;
 select_dxg=argc==3;
 EVENT_TRACE_LOGFILEW log{};log.LogFileName=argv[1];log.ProcessTraceMode=PROCESS_TRACE_MODE_EVENT_RECORD|PROCESS_TRACE_MODE_RAW_TIMESTAMP;log.EventRecordCallback=event;
 const auto h=OpenTraceW(&log);if(h==INVALID_PROCESSTRACE_HANDLE){std::fprintf(stderr,"open error=%lu\n",GetLastError());return 3;}
 std::fprintf(stderr,"header frequency=%lld clock=%lu start=%lld lost=%lu\n",log.LogfileHeader.PerfFreq.QuadPart,log.LogfileHeader.ReservedFlags,log.LogfileHeader.StartTime.QuadPart,log.LogfileHeader.EventsLost);
 auto handle=h;const auto status=ProcessTrace(&handle,1,nullptr,nullptr);CloseTrace(h);
 for(auto [id,count]:counts)std::fprintf(stderr,"count id=%u events=%llu\n",id,count);
 std::fprintf(stderr,"summary status=%lu total=%llu selected=%llu\n",status,total,selected);return status?4:0;
}
