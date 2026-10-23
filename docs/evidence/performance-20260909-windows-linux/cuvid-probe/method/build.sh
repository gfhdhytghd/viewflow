set -eu
cmake -S "/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/cuvid-probe/source/platform/linux-reverse" -B /tmp/viewflow-reverse-cuvid-probe -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/viewflow-reverse-cuvid-probe --target viewflow_reverse_decoder_probe -j4
