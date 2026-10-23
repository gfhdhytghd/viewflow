set -eu
cmake -S "/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/marker-profile/source/platform/linux-reverse" -B /tmp/viewflow-reverse-marker-profile -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/viewflow-reverse-marker-profile -j4
ctest --test-dir /tmp/viewflow-reverse-marker-profile --output-on-failure
