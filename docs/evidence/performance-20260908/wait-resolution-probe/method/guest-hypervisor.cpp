#include <intrin.h>
#include <windows.h>
#include <cstdio>
#include <cstring>
int main(){int r[4]{};__cpuid(r,0x40000000);char vendor[13]{};memcpy(vendor,&r[1],4);memcpy(vendor+4,&r[2],4);memcpy(vendor+8,&r[3],4);LARGE_INTEGER f{};QueryPerformanceFrequency(&f);printf("{\"vendor\":\"%s\",\"max_hypervisor_leaf\":%u,\"qpc_frequency\":%lld}\n",vendor,unsigned(r[0]),f.QuadPart);return 0;}
