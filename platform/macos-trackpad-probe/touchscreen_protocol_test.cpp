#include "touchscreen_protocol.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
int main() {
 uint8_t wire[vf_native::wire_size],native[vf_native::max_hid_size],digitizer[60];
 vf_native::empty_wire(wire,12340);wire[0]=5;wire[1]=1;
 for(unsigned i=0;i<5;++i){auto c=wire+12+12*i;c[0]=i+4;c[1]=1;vf_native::put16(c+2,i*8191);vf_native::put16(c+4,32767-i*8191);c[6]=20+i;c[7]=30;c[8]=20;c[10]=4;c[11]=2;}
 size_t n=vf_native::encode(wire,0,native);
 assert(vf_touchscreen::from_native(native,n,digitizer)==60);
 assert(digitizer[0]==1 && digitizer[56]==5 && digitizer[59]==1);
 for(unsigned i=0;i<5;++i){auto d=digitizer+1+11*i;assert(d[0]==7 && d[1]==i+4 && d[10]==20+i);assert(std::abs(int(vf_native::u16(d+2))-int(i*8191))<5);assert(std::abs(int(vf_native::u16(d+4))-int(32767-i*8191))<5);}
 for(unsigned i=0;i<5;++i)wire[13+12*i]=0;
 wire[1]=0;
 n=vf_native::encode(wire,0,native);assert(vf_touchscreen::from_native(native,n,digitizer)==60);
 for(unsigned i=0;i<5;++i)assert(digitizer[1+11*i]==0 && digitizer[11+11*i]==0);
 assert(digitizer[59]==0);assert(!vf_touchscreen::from_native(native,13,digitizer));
 FILE *f=std::fopen("/tmp/vf-touchscreen-descriptor.bin","wb");assert(f);std::fwrite(vf_touchscreen_descriptor,1,sizeof(vf_touchscreen_descriptor),f);std::fclose(f);
 std::puts("standard digitizer: five contacts, coordinates, pressure, click and release passed");
}
