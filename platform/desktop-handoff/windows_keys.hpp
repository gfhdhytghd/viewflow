#pragma once
#include <optional>
#include <utility>
namespace viewflow::handoff {
// One adapter boundary; replace with reverse-common's shared Windows table
// when the parallel key-table change is merged. No modifier policy here.
inline unsigned evdev_scan(unsigned scan,bool extended) {
    if(!extended) {
        if(scan<=88)return scan;
        if(scan>=0x64 && scan<=0x6e)return 183+scan-0x64;
        if(scan==0x76)return 194;
        switch(scan){case 0x73:return 89;case 0x70:return 93;case 0x79:return 92;
          case 0x7b:return 94;case 0x7d:return 124;case 0x7e:return 121;default:return 0;}
    }
    switch(scan){case 0x1c:return 96;case 0x1d:return 97;case 0x35:return 98;case 0x37:return 99;
      case 0x38:return 100;case 0x47:return 102;case 0x48:return 103;case 0x49:return 104;
      case 0x4b:return 105;case 0x4d:return 106;case 0x4f:return 107;case 0x50:return 108;
      case 0x51:return 109;case 0x52:return 110;case 0x53:return 111;case 0x5b:return 125;
      case 0x5c:return 126;case 0x5d:return 127;default:return 0;}
}
inline std::optional<std::pair<unsigned,bool>> windows_scan(unsigned evdev) {
    for(bool extended:{false,true})for(unsigned scan=1;scan<256;++scan)
        if(evdev_scan(scan,extended)==evdev)return {{scan,extended}};
    return {};
}
}
