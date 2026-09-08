// Bounded synthetic UDP receiver, no rendering/input or persistent settings.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <mswsock.h>
#include <mmsystem.h>
#pragma pack(push,1)
struct Header { uint32_t magic,batch,sequence,count; uint64_t nonce; };
#pragma pack(pop)
struct Receipt { uint32_t batch,sequence; long long qpc; };
static long long clockNow(){LARGE_INTEGER q{};QueryPerformanceCounter(&q);return q.QuadPart;}
int main(int argc,char** argv) {
  if(argc!=4)return 2;
  const uint64_t nonce=std::strtoull(argv[1],nullptr,16);
  const int port=std::atoi(argv[2]), batches=std::atoi(argv[3]);
  if(!nonce||(port!=49073&&port!=49101)||batches<1||batches>64)return 2;
  char mode[32]{};GetEnvironmentVariableA("VIEWFLOW_PROBE_IO",mode,sizeof(mode));
  const bool nonblocking=std::strcmp(mode,"nonblocking")==0;
  const auto timerStatus=timeBeginPeriod(1);
  struct Timer {MMRESULT status;~Timer(){if(status==TIMERR_NOERROR)timeEndPeriod(1);}} timer{timerStatus};
  WSADATA ws{};if(WSAStartup(MAKEWORD(2,2),&ws))return 3;
  SOCKET sock=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);if(sock==INVALID_SOCKET)return 3;
  BOOL exclusive=TRUE;setsockopt(sock,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<const char*>(&exclusive),sizeof(exclusive));
  int receiveBytes=4*1024*1024;setsockopt(sock,SOL_SOCKET,SO_RCVBUF,reinterpret_cast<const char*>(&receiveBytes),sizeof(receiveBytes));
  DWORD timeout=500;setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
  sockaddr_in local{};local.sin_family=AF_INET;local.sin_port=htons(static_cast<u_short>(port));InetPtonA(AF_INET,"172.16.105.70",&local.sin_addr);
  if(bind(sock,reinterpret_cast<sockaddr*>(&local),sizeof(local))){closesocket(sock);WSACleanup();return 4;}
  LPFN_WSARECVMSG receiveMessage=nullptr;
  if(nonblocking){u_long enabled=1;if(ioctlsocket(sock,FIONBIO,&enabled))return 8;GUID guid=WSAID_WSARECVMSG;DWORD bytes=0;if(WSAIoctl(sock,SIO_GET_EXTENSION_FUNCTION_POINTER,&guid,sizeof(guid),&receiveMessage,sizeof(receiveMessage),&bytes,nullptr,nullptr))return 9;}
  unsigned wouldBlock=0;
  std::printf("probe-io mode=%s timer_status=%u\n",nonblocking?"nonblocking":"blocking",unsigned(timerStatus));
  IN_ADDR source{};InetPtonA(AF_INET,"172.16.105.62",&source);
  LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);const auto start=clockNow();
  int valueLen=sizeof(receiveBytes);getsockopt(sock,SOL_SOCKET,SO_RCVBUF,reinterpret_cast<char*>(&receiveBytes),&valueLen);
  std::printf("probe-ready port=%d frequency=%lld start_qpc=%lld receive_buffer=%d\n",port,frequency.QuadPart,start,receiveBytes);std::fflush(stdout);
  std::vector<Receipt> records;records.reserve(size_t(batches)*256);
  unsigned completed=0,count=0,received=0;bool seen[256]{};int result=5;
  while(clockNow()-start < frequency.QuadPart*30) {
    char buffer[1500];sockaddr_in peer{};int peerLen=sizeof(peer);
    int n=0;
    if(nonblocking){WSABUF data{sizeof(buffer),buffer};alignas(WSACMSGHDR) char control[128]{};WSAMSG message{};message.name=reinterpret_cast<sockaddr*>(&peer);message.namelen=sizeof(peer);message.lpBuffers=&data;message.dwBufferCount=1;message.Control={sizeof(control),control};DWORD receivedBytes=0;int rc=receiveMessage(sock,&message,&receivedBytes,nullptr,nullptr);n=rc==0?int(receivedBytes):SOCKET_ERROR;peerLen=message.namelen;
      if(n==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK){++wouldBlock;fd_set ready;FD_ZERO(&ready);FD_SET(sock,&ready);timeval wait{0,500000};if(select(0,&ready,nullptr,nullptr,&wait)==SOCKET_ERROR){result=10;break;}continue;}
    }else n=recvfrom(sock,buffer,sizeof(buffer),0,reinterpret_cast<sockaddr*>(&peer),&peerLen);
    const auto now=clockNow();
    if(n==SOCKET_ERROR){if(WSAGetLastError()==WSAETIMEDOUT)continue;result=6;break;}
    if(n!=1400||peer.sin_addr.s_addr!=source.s_addr)continue;
    Header h{};std::memcpy(&h,buffer,sizeof(h));
    if(h.magic!=0x56465542||h.nonce!=nonce||h.batch!=completed||!h.count||h.count>256||h.sequence>=h.count)continue;
    if(!count)count=h.count;if(count!=h.count||seen[h.sequence])continue;
    seen[h.sequence]=true;++received;records.push_back({h.batch,h.sequence,now});
    if(received==count){
      Header ack{0x5646414B,h.batch,received,count,nonce};
      if(sendto(sock,reinterpret_cast<const char*>(&ack),sizeof(ack),0,reinterpret_cast<sockaddr*>(&peer),peerLen)!=sizeof(ack)){result=7;break;}
      ++completed;received=0;count=0;std::memset(seen,0,sizeof(seen));
      if(completed==static_cast<unsigned>(batches)){result=0;break;}
    }
  }
  closesocket(sock);WSACleanup();
  for(const auto& record:records)std::printf("probe-packet batch=%u sequence=%u qpc=%lld\n",record.batch,record.sequence,record.qpc);
  std::printf("probe-finished completed=%u expected=%d packets=%zu result=%d\n",completed,batches,records.size(),result);
  std::printf("probe-would-block count=%u\n",wouldBlock);
  return result;
}
