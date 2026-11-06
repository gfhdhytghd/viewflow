#include "windows_keys.hpp"
#include <cassert>
#include <set>
using namespace viewflow::reverse::windows_keys;
int main() {
    std::set<unsigned> scans, codes;
    for(auto entry:table) {
        assert(scans.insert(entry.scan).second);assert(codes.insert(entry.evdev).second);
        auto native=to_windows(entry.evdev);assert(native);
        unsigned scan=native->scan|(native->extended?0xe000:0);
        assert(scan==entry.scan && from_scan(scan)==entry.evdev);
        auto flags=(unsigned(native->scan)<<16)|(native->extended?(1u<<24):0);
        assert(from_message(0,flags)==entry.evdev);
        assert(from_message(0,flags|(1u<<30)|(1u<<31))==entry.evdev);
    }
    for(unsigned i=0;i<12;++i)assert(to_windows(183+i)->scan==(i==11?0x76:0x64+i));
    assert(from_scan(0xe01d)==97 && from_scan(0x1d)==29);
    assert(from_scan(0xe01c)==96 && from_scan(0x1c)==28);
    assert(from_scan(0xe037)==99 && from_scan(0x54)==99);
    assert(from_message(0x13,0x45u<<16)==119 && to_windows(119)->virtual_key==0x13);
    assert(from_scan(0x45)==69 && from_scan(0xe045)==69);
    assert(from_scan(0x73)==89 && from_scan(0x7d)==124 && from_scan(0x56)==86);
    assert(from_scan(0xe030)==115 && from_scan(0xe010)==165 && from_scan(0xe06a)==158);
    assert(!from_scan(0) && !from_scan(0xe02a) && !from_scan(0xffff) && !to_windows(0));
}
