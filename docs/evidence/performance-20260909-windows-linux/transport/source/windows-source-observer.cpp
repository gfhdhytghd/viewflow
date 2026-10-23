// Read only the owned fixture's markers from the composed virtual desktop.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <array>
#include <string>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
void check(HRESULT h){if(FAILED(h))throw std::runtime_error("desktop observer HRESULT="+std::to_string(static_cast<unsigned long>(h)));}
long long qpc(){LARGE_INTEGER t{};QueryPerformanceCounter(&t);return t.QuadPart;}
struct Search{DWORD pid;HWND hwnd{};unsigned count{};};
BOOL CALLBACK find(HWND w,LPARAM p){auto& s=*reinterpret_cast<Search*>(p);DWORD pid{};GetWindowThreadProcessId(w,&pid);wchar_t name[128]{};GetClassNameW(w,name,128);if(pid==s.pid && IsWindowVisible(w) && !wcscmp(name,L"VFReversePerfOwned")){s.hwnd=w;++s.count;}return TRUE;}
struct Slot{ComPtr<ID3D11Texture2D> pixels;DXGI_OUTDUPL_FRAME_INFO info{};long long acquired{};};
int main(int argc,char** argv){try{
 if(argc!=3)return 2;SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);auto desk=OpenInputDesktop(0,FALSE,GENERIC_ALL);if(!desk || !SetThreadDesktop(desk))return 3;Search search{static_cast<DWORD>(std::stoul(argv[1]))};EnumWindows(find,reinterpret_cast<LPARAM>(&search));RECT rect{};
 if(search.count!=1 || !GetWindowRect(search.hwnd,&rect) || rect.left!=-6144 || rect.top!=-780 || rect.right!=0 || rect.bottom!=2676)return 4;
 auto monitor=MonitorFromWindow(search.hwnd,MONITOR_DEFAULTTONULL);ComPtr<IDXGIFactory1> factory;check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;ComPtr<IDXGIOutputDuplication> dup;
 for(UINT a=0;!dup;++a){ComPtr<IDXGIAdapter1> adapter;if(factory->EnumAdapters1(a,&adapter)==DXGI_ERROR_NOT_FOUND)break;for(UINT i=0;;++i){ComPtr<IDXGIOutput> output;if(adapter->EnumOutputs(i,&output)==DXGI_ERROR_NOT_FOUND)break;DXGI_OUTPUT_DESC d{};check(output->GetDesc(&d));if(d.Monitor!=monitor)continue;if(d.Rotation!=DXGI_MODE_ROTATION_IDENTITY || !EqualRect(&d.DesktopCoordinates,&rect))return 5;check(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));ComPtr<IDXGIOutput1> out;check(output.As(&out));check(out->DuplicateOutput(device.Get(),&dup));break;}}
 if(!dup)return 6;LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);const auto start=qpc();const auto duration=std::stoul(argv[2]);std::fprintf(stdout,"source_observer frequency=%lld width=6144 height=3456 pid=%lu\n",frequency.QuadPart,search.pid);
 std::array<Slot,3> slots;unsigned head=0,pending=0,valid=0,invalid=0,previous=0,changes=0;bool held=false;
 auto consume=[&](){while(pending){auto& slot=slots[head];D3D11_MAPPED_SUBRESOURCE map{};auto hr=context->Map(slot.pixels.Get(),0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&map);if(hr==DXGI_ERROR_WAS_STILL_DRAWING)break;check(hr);unsigned marker=0;bool okay=true;for(unsigned bit=0;bit<24;++bit){auto* pixels=static_cast<unsigned char*>(map.pData);auto x=(bit*128+64)*4;auto top=pixels[x],bottom=pixels[map.RowPitch+x];if(!((top<70 && bottom>180)||(top>180 && bottom<70))){okay=false;break;}if(top>180)marker|=1u<<bit;}context->Unmap(slot.pixels.Get(),0);auto observed=qpc();if(okay && marker && slot.info.LastPresentTime.QuadPart){++valid;if(marker!=previous){if(marker<previous)throw std::runtime_error("source desktop marker regressed");std::fprintf(stdout,"source_desktop marker=%u present_qpc=%lld observed_qpc=%lld acquired_qpc=%lld accumulated=%u\n",marker,slot.info.LastPresentTime.QuadPart,observed,slot.acquired,slot.info.AccumulatedFrames);previous=marker;++changes;}}else ++invalid;head=(head+1)%slots.size();--pending;}};
 while((qpc()-start)*1000/frequency.QuadPart<duration){consume();if(pending==slots.size()){Sleep(1);continue;}if(held){check(dup->ReleaseFrame());held=false;}DXGI_OUTDUPL_FRAME_INFO info{};ComPtr<IDXGIResource> resource;auto hr=dup->AcquireNextFrame(pending?1:10,&info,&resource);if(hr==DXGI_ERROR_WAIT_TIMEOUT)continue;check(hr);held=true;ComPtr<ID3D11Texture2D> desktop;check(resource.As(&desktop));D3D11_TEXTURE2D_DESC d{};desktop->GetDesc(&d);if(d.Width!=6144 || d.Height!=3456 || d.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)return 7;auto& slot=slots[(head+pending)%slots.size()];if(!slot.pixels){d.Width=3072;d.Height=2;d.MipLevels=1;d.ArraySize=1;d.Usage=D3D11_USAGE_STAGING;d.BindFlags=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.MiscFlags=0;check(device->CreateTexture2D(&d,nullptr,&slot.pixels));}D3D11_BOX top{0,32,0,3072,33,1},bottom{0,96,0,3072,97,1};context->CopySubresourceRegion(slot.pixels.Get(),0,0,0,0,desktop.Get(),0,&top);context->CopySubresourceRegion(slot.pixels.Get(),0,0,1,0,desktop.Get(),0,&bottom);context->Flush();slot.info=info;slot.acquired=qpc();++pending;
 }
 auto end=qpc()+frequency.QuadPart;while(pending && qpc()<end){consume();if(pending)Sleep(1);}if(held)check(dup->ReleaseFrame());std::fprintf(stdout,"source_observer_complete valid=%u invalid=%u distinct=%u pending=%u\n",valid,invalid,changes,pending);return valid && !pending?0:8;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
