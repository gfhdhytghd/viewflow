#pragma once
#include <windows.h>
#include <wincodec.h>
#include <shellapi.h>
#include <wrl/client.h>
#include <vector>
#include <string>
namespace viewflow::reverse {
struct SourceIcon {std::string app_id;std::vector<unsigned char> png;};
inline SourceIcon source_icon(HWND window) {
    using Microsoft::WRL::ComPtr;
    SourceIcon result;DWORD pid{};GetWindowThreadProcessId(window,&pid);
    wchar_t path[32768]{};DWORD length=32768;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    const bool named=process && QueryFullProcessImageNameW(process,0,path,&length);
    if(process)CloseHandle(process);
    if(!named)return result;
    const auto slash=wcsrchr(path,L'\\');const wchar_t* name=slash?slash+1:path;
    const int bytes=WideCharToMultiByte(CP_UTF8,0,name,-1,nullptr,0,nullptr,nullptr);
    if(bytes<2 || bytes>248)return result;
    std::string utf8(bytes,'\0');WideCharToMultiByte(CP_UTF8,0,name,-1,utf8.data(),bytes,nullptr,nullptr);utf8.pop_back();result.app_id="windows:"+utf8;
    DWORD_PTR value{};
    SendMessageTimeoutW(window,WM_GETICON,ICON_BIG,0,SMTO_ABORTIFHUNG|SMTO_BLOCK,40,&value);
    HICON icon=reinterpret_cast<HICON>(value);bool owned=false;
    if(!icon)icon=reinterpret_cast<HICON>(GetClassLongPtrW(window,GCLP_HICON));
    if(!icon){ExtractIconExW(path,0,&icon,nullptr,1);owned=icon!=nullptr;}
    if(!icon)return result;
    ComPtr<IWICImagingFactory> factory;ComPtr<IWICBitmap> bitmap;ComPtr<IStream> stream;ComPtr<IWICBitmapEncoder> encoder;ComPtr<IWICBitmapFrameEncode> frame;
    const auto cleanup=[&]{if(owned)DestroyIcon(icon);};
    if(FAILED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory))) ||
       FAILED(factory->CreateBitmapFromHICON(icon,&bitmap)) || FAILED(CreateStreamOnHGlobal(nullptr,TRUE,&stream)) ||
       FAILED(factory->CreateEncoder(GUID_ContainerFormatPng,nullptr,&encoder)) || FAILED(encoder->Initialize(stream.Get(),WICBitmapEncoderNoCache)) ||
       FAILED(encoder->CreateNewFrame(&frame,nullptr)) || FAILED(frame->Initialize(nullptr))) {cleanup();return result;}
    UINT w{},h{};bitmap->GetSize(&w,&h);
    if(!w || !h || w>256 || h>256 || FAILED(frame->SetSize(w,h))){cleanup();return result;}
    WICPixelFormatGUID format=GUID_WICPixelFormat32bppBGRA;
    if(FAILED(frame->SetPixelFormat(&format)) || FAILED(frame->WriteSource(bitmap.Get(),nullptr)) || FAILED(frame->Commit()) || FAILED(encoder->Commit())){cleanup();return result;}
    STATSTG stat{};HGLOBAL memory{};
    if(SUCCEEDED(stream->Stat(&stat,STATFLAG_NONAME)) && stat.cbSize.QuadPart<=256*1024 && SUCCEEDED(GetHGlobalFromStream(stream.Get(),&memory))){
        const auto data=static_cast<const unsigned char*>(GlobalLock(memory));
        if(data){result.png.assign(data,data+size_t(stat.cbSize.QuadPart));GlobalUnlock(memory);}
    }
    cleanup();return result;
}
}
