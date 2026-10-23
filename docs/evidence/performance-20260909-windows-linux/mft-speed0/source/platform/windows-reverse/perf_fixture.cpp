// Passive 6K fixture on the existing non-primary virtual display.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <mmsystem.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
using Microsoft::WRL::ComPtr;
void check(HRESULT h){if(FAILED(h))throw std::runtime_error("fixture HRESULT="+std::to_string(static_cast<unsigned long>(h)));}
long long now(){LARGE_INTEGER t{},f{};QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return t.QuadPart/f.QuadPart*10000000+(t.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
int main(){try{
 SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
 auto desktop=OpenInputDesktop(0,FALSE,GENERIC_ALL);if(!desktop || !SetThreadDesktop(desktop))return 2;
 RECT rect{-6144,-780,0,2676};MONITORINFO mi{sizeof(mi)};auto monitor=MonitorFromRect(&rect,MONITOR_DEFAULTTONULL);
 if(!monitor || !GetMonitorInfoW(monitor,&mi) || !EqualRect(&mi.rcMonitor,&rect) || (mi.dwFlags&MONITORINFOF_PRIMARY))return 3;
 auto foreground=GetForegroundWindow();WNDCLASSW cls{};cls.hInstance=GetModuleHandleW(nullptr);cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=L"VFReversePerfOwned";
 if(!RegisterClassW(&cls))return 4;
 auto window=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TRANSPARENT,cls.lpszClassName,L"Viewflow passive 6K source",WS_POPUP,rect.left,rect.top,6144,3456,nullptr,nullptr,cls.hInstance,nullptr);if(!window)return 5;
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> ctx;check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&ctx));
 ComPtr<IDXGIDevice> dxgi;check(device.As(&dxgi));ComPtr<IDXGIAdapter> adapter;check(dxgi->GetAdapter(&adapter));ComPtr<IDXGIFactory2> factory;check(adapter->GetParent(IID_PPV_ARGS(&factory)));
 DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=6144;desc.Height=3456;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;desc.AlphaMode=DXGI_ALPHA_MODE_IGNORE;
 ComPtr<IDXGISwapChain1> swap;check(factory->CreateSwapChainForHwnd(device.Get(),window,&desc,nullptr,nullptr,&swap));check(factory->MakeWindowAssociation(window,DXGI_MWA_NO_ALT_ENTER));
 ComPtr<ID3D11Texture2D> back;check(swap->GetBuffer(0,IID_PPV_ARGS(&back)));ComPtr<ID3D11RenderTargetView> target;check(device->CreateRenderTargetView(back.Get(),nullptr,&target));
 const char* shader=R"(
cbuffer Params:register(b0){uint frame;uint3 padding;};
float4 vs(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}
float4 ps(float4 p:SV_Position):SV_Target {
 uint x=uint(p.x),y=uint(p.y);
 // Repeated 24-bit counter + complementary row; wide cells survive 4:2:0.
 if(y<128){uint bit=(x/128)%24;uint v=(frame>>bit)&1;if(y>=64)v=1-v;return float4(v,v,v,1);}
 float3 c=float3(float((x/96+frame/4)%17)/16,float((y/96)%13)/12,0.3);
 if(abs(int(x)-int((frame*21)%6144))<24)c=float3(1,1,1);
 return float4(c,1);
})";
 ComPtr<ID3DBlob> code,error;check(D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));ComPtr<ID3D11VertexShader> vs;check(device->CreateVertexShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&vs));code.Reset();
 check(D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&error));ComPtr<ID3D11PixelShader> ps;check(device->CreatePixelShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&ps));
 D3D11_BUFFER_DESC bd{};bd.ByteWidth=16;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;ComPtr<ID3D11Buffer> cb;check(device->CreateBuffer(&bd,nullptr,&cb));
 auto* rt=target.Get();ctx->OMSetRenderTargets(1,&rt,nullptr);D3D11_VIEWPORT viewport{0,0,6144,3456,0,1};ctx->RSSetViewports(1,&viewport);ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);ctx->VSSetShader(vs.Get(),nullptr,0);ctx->PSSetShader(ps.Get(),nullptr,0);auto* buffer=cb.Get();ctx->PSSetConstantBuffers(0,1,&buffer);
 ShowWindow(window,SW_SHOWNOACTIVATE);timeBeginPeriod(1);
 std::fprintf(stderr,"fixture_ready pid=%lu hwnd=%p width=6144 height=3456 foreground_before=%p foreground_now=%p\n",GetCurrentProcessId(),window,foreground,GetForegroundWindow());
 const auto end=now()+400000000ll;unsigned frame=0;
 while(now()<end){MSG msg{};while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}unsigned params[4]={++frame,0,0,0};ctx->UpdateSubresource(cb.Get(),0,nullptr,params,0,0);const auto begin=now();ctx->OMSetRenderTargets(1,&rt,nullptr);ctx->Draw(3,0);check(swap->Present(1,0));std::fprintf(stderr,"fixture_frame id=%u begin=%lld presented=%lld\n",frame,begin,now());}
 std::fprintf(stderr,"fixture_end foreground=%p frames=%u\n",GetForegroundWindow(),frame);DestroyWindow(window);timeEndPeriod(1);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"fixture_error %s\n",e.what());return 1;}}
