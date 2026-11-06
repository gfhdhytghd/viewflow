#pragma once
#include <cstdint>
#include <optional>
namespace viewflow::reverse::windows_keys {
// Windows Set 1 make codes; 0xe0xx denotes the extended message bit.
// Standard keys, F1-F24, keypad, ISO/JIS/Korean and consumer/browser keys.
// Reference: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input
// Linux identities: include/uapi/linux/input-event-codes.h. Unknown/OEM keys
// without a defined mapping are rejected, never misinterpreted as text.
struct Mapping { unsigned scan, evdev; };
inline constexpr Mapping table[]{
    {0x0001, 1},
    {0x0002, 2},
    {0x0003, 3},
    {0x0004, 4},
    {0x0005, 5},
    {0x0006, 6},
    {0x0007, 7},
    {0x0008, 8},
    {0x0009, 9},
    {0x000a, 10},
    {0x000b, 11},
    {0x000c, 12},
    {0x000d, 13},
    {0x000e, 14},
    {0x000f, 15},
    {0x0010, 16},
    {0x0011, 17},
    {0x0012, 18},
    {0x0013, 19},
    {0x0014, 20},
    {0x0015, 21},
    {0x0016, 22},
    {0x0017, 23},
    {0x0018, 24},
    {0x0019, 25},
    {0x001a, 26},
    {0x001b, 27},
    {0x001c, 28},
    {0x001d, 29},
    {0x001e, 30},
    {0x001f, 31},
    {0x0020, 32},
    {0x0021, 33},
    {0x0022, 34},
    {0x0023, 35},
    {0x0024, 36},
    {0x0025, 37},
    {0x0026, 38},
    {0x0027, 39},
    {0x0028, 40},
    {0x0029, 41},
    {0x002a, 42},
    {0x002b, 43},
    {0x002c, 44},
    {0x002d, 45},
    {0x002e, 46},
    {0x002f, 47},
    {0x0030, 48},
    {0x0031, 49},
    {0x0032, 50},
    {0x0033, 51},
    {0x0034, 52},
    {0x0035, 53},
    {0x0036, 54},
    {0x0037, 55},
    {0x0038, 56},
    {0x0039, 57},
    {0x003a, 58},
    {0x003b, 59},
    {0x003c, 60},
    {0x003d, 61},
    {0x003e, 62},
    {0x003f, 63},
    {0x0040, 64},
    {0x0041, 65},
    {0x0042, 66},
    {0x0043, 67},
    {0x0044, 68},
    {0x0046, 70},
    {0x0047, 71},
    {0x0048, 72},
    {0x0049, 73},
    {0x004a, 74},
    {0x004b, 75},
    {0x004c, 76},
    {0x004d, 77},
    {0x004e, 78},
    {0x004f, 79},
    {0x0050, 80},
    {0x0051, 81},
    {0x0052, 82},
    {0x0053, 83},
    {0xe045, 69},
    {0x0056, 86},
    {0x0057, 87},
    {0x0058, 88},
    {0x0059, 117},
    {0x005c, 95},
    {0x0070, 93},
    {0x0073, 89},
    {0x0079, 92},
    {0x007b, 94},
    {0x007d, 124},
    {0x007e, 121},
    {0x00f1, 123},
    {0x00f2, 122},
    {0x0064, 183},
    {0x0065, 184},
    {0x0066, 185},
    {0x0067, 186},
    {0x0068, 187},
    {0x0069, 188},
    {0x006a, 189},
    {0x006b, 190},
    {0x006c, 191},
    {0x006d, 192},
    {0x006e, 193},
    {0x0076, 194},
    {0xe01c, 96},
    {0xe01d, 97},
    {0xe035, 98},
    {0xe037, 99},
    {0xe038, 100},
    {0xe047, 102},
    {0xe048, 103},
    {0xe049, 104},
    {0xe04b, 105},
    {0xe04d, 106},
    {0xe04f, 107},
    {0xe050, 108},
    {0xe051, 109},
    {0xe052, 110},
    {0xe053, 111},
    {0xe05b, 125},
    {0xe05c, 126},
    {0xe05d, 127},
    {0xe010, 165},
    {0xe019, 163},
    {0xe020, 113},
    {0xe021, 140},
    {0xe022, 164},
    {0xe024, 166},
    {0xe02e, 114},
    {0xe030, 115},
    {0xe032, 172},
    {0xe05e, 116},
    {0xe05f, 142},
    {0xe063, 143},
    {0xe065, 217},
    {0xe066, 156},
    {0xe067, 173},
    {0xe068, 128},
    {0xe069, 159},
    {0xe06a, 158},
    {0xe06b, 157},
    {0xe06c, 155},
    {0xe06d, 226},
};
struct NativeKey { std::uint16_t scan; bool extended; std::uint16_t virtual_key{}; };
inline constexpr std::optional<unsigned> from_scan(unsigned scan) {
    // Message aliases: NumLock is also reported without E0; Alt+PrintScreen
    // is SysRq. Canonical output uses E045/E037, respectively.
    if(scan==0x45)scan=0xe045;
    if(scan==0x54)scan=0xe037;
    for(auto entry:table)if(entry.scan==scan)return entry.evdev;
    return {};
}
inline constexpr std::optional<unsigned> from_message(unsigned vk, std::uint32_t flags) {
    // Pause uses E1, which WM_KEY* cannot encode in its extended bit. Preserve
    // it by VK identity instead of accidentally treating it as NumLock.
    if(vk==0x13)return 119;
    if(vk==0x15)return 122; // Hangul
    if(vk==0x19)return 123; // Hanja
    return from_scan(((flags>>16)&255) | ((flags&(1u<<24))?0xe000:0));
}
inline constexpr std::optional<NativeKey> to_windows(unsigned evdev) {
    if(evdev==119)return NativeKey{0,false,0x13}; // SendInput VK_PAUSE, not an invalid E1 scan.
    for(auto entry:table)if(entry.evdev==evdev)
        return NativeKey{static_cast<std::uint16_t>(entry.scan&255),(entry.scan&0xff00)==0xe000,0};
    return {};
}
}
