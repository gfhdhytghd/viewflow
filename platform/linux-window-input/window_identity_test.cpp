#include "window_identity.hpp"
#include <iostream>

int main(int argc, char**) {
    std::cout << (argc > 1 ? viewflow::linux_input::close_window_command :
                 [](const std::string& a, unsigned p, const std::string& s) { return viewflow::linux_input::window_guard(a,p,s); })("0x55675023acb0", 2327048, "180001ed");
}
