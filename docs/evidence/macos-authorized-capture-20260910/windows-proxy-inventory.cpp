#include <windows.h>
#include <cstdio>
#include <cwchar>
FILE* output;bool first=true;
BOOL CALLBACK inspect(HWND window,LPARAM){wchar_t name[128]{};GetClassNameW(window,name,128);if(wcscmp(name,L"ViewflowPortableWindow"))return TRUE;DWORD pid{};GetWindowThreadProcessId(window,&pid);RECT r{};GetWindowRect(window,&r);fprintf(output,"%s{\"pid\":%lu,\"visible\":%s,\"left\":%ld,\"top\":%ld,\"width\":%ld,\"height\":%ld}",first?"":",",pid,IsWindowVisible(window)?"true":"false",r.left,r.top,r.right-r.left,r.bottom-r.top);first=false;return TRUE;}
int wmain(int argc,wchar_t**argv){if(argc!=2)return 2;SetProcessDPIAware();if(_wfopen_s(&output,argv[1],L"wb"))return 3;fputs("[",output);EnumWindows(inspect,0);fputs("]\n",output);fclose(output);return 0;}
