#include "annex_b_clean_point.h"
#include <initializer_list>
#include <iostream>
int main() {
  auto test = [](std::initializer_list<uint8_t> bytes, bool expected) {
    return viewflow::windows::annex_b_clean_point({bytes.begin(), bytes.size()}) == expected;
  };
  if (!test({}, false) || !test({0,0,1}, false) ||
      !test({0,0,0,1}, false) || !test({0,0,1,0x65}, true) ||
      !test({0,0,0,1,0x65,0x88}, true) ||
      !test({0,0,1,0x41,0x88}, false) ||
      !test({0,0,1,0x67,0x42,0,0,1,0x68}, false) ||
      !test({0,0,1,0x67,0x42,0,0,1,0x65,0x88}, true) ||
      !test({0,0,1,0x65,0,0,1,0x41}, false) ||
      !test({0,0,1,0xe5}, false) ||
      !test({0,0,1,0x65,0,0,1}, false) ||
      !test({0,0,1,0x65,0,0,3,1,0x41}, true)) return 1;
  std::cout << "PASS Annex-B clean-point hint\n";
}
