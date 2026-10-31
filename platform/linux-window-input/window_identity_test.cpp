#include "window_identity.hpp"
#include <iostream>

int main() {
    std::cout << viewflow::linux_input::window_guard("0x55675023acb0", 2327048, "180001ed");
}
