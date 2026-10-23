# Initial WGC interval build failure

The isolated initial snapshot used std::getenv in the shared capture module. MSVC /WX rejected the deprecated CRT function with C4996. No executable was run or installed. Source maps and the failed build log are retained. The separately named [v2 snapshot](../wgc-interval-v2/README.md) uses GetEnvironmentVariableA and strict integer parsing.
