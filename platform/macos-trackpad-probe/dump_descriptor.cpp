#include "descriptor.h"
#include <cstdio>
int main() {
    return std::fwrite(vf_descriptor, 1, sizeof(vf_descriptor), stdout)
        == sizeof(vf_descriptor) ? 0 : 1;
}
