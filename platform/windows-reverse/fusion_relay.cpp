#include <windows.h>
#include <objbase.h>
#include <io.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
// An authenticated SSH stdio bridge. No desktop input is generated here;
// the interactive agent processes the same atomic inbox requests as before.
int wmain(int argc,wchar_t** argv) {
    if(argc!=2)return 2;
    _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
    const std::filesystem::path directory(argv[1]);
    for(std::string line;std::getline(std::cin,line);) {
        if(line.size()>2*1024*1024)return 3;
        try {
            GUID id{};if(FAILED(CoCreateGuid(&id)))throw std::runtime_error("request id");
            wchar_t token[40]{};StringFromGUID2(id,token,40);
            const auto name=std::wstring(token)+L".json";
            const auto request=directory/L"requests"/name,reply=directory/L"responses"/name;
            auto temporary=request;temporary+=L".next";
            {std::ofstream output(temporary,std::ios::binary);output.exceptions(std::ios::badbit|std::ios::failbit);output<<line;}
            std::filesystem::rename(temporary,request);
            const auto begin=GetTickCount64();bool recovered=false;
            while(!std::filesystem::exists(reply)) {
                if(!recovered && GetTickCount64()-begin>500) {
                    recovered=true;wchar_t system[MAX_PATH]{};GetSystemDirectoryW(system,MAX_PATH);
                    const auto exe=std::wstring(system)+L"\\schtasks.exe";
                    std::wstring command=L"\""+exe+L"\" /Run /TN Viewflow-Fusion-Agent";
                    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
                    if(CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process)) {CloseHandle(process.hThread);CloseHandle(process.hProcess);}
                }
                if(GetTickCount64()-begin>20000)throw std::runtime_error("agent timeout");
                Sleep(5);
            }
            std::ifstream input(reply,std::ios::binary);std::string value((std::istreambuf_iterator<char>(input)),{});input.close();
            if(value.starts_with("\xef\xbb\xbf"))value.erase(0,3);
            while(!value.empty() && (value.back()=='\r' || value.back()=='\n'))value.pop_back();
            std::cout<<value<<'\n'<<std::flush;
            std::filesystem::remove(reply);
        } catch(...) {std::cout<<"{\"ok\":false,\"error\":\"Windows agent relay failed; action may still be pending\"}\n"<<std::flush;}
    }
    return 0;
}
