#pragma once
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include "async_trace.hpp"

namespace vf_diag {
inline void trace(const char* format,...) {
    static const bool async=[] {const auto* v=std::getenv("VIEWFLOW_ASYNC_TRACE");return v && std::strcmp(v,"1")==0;}();
    va_list args;va_start(args,format);
    if(!async){std::vfprintf(stderr,format,args);va_end(args);return;}
    static AsyncTrace output([](const char* line,void*){std::fputs(line,stderr);});
    char line[AsyncTrace::line_size+1];
    const int n=std::vsnprintf(line,sizeof(line),format,args);va_end(args);
    if(n<0)return;
    output.push(line);
}

// Per-frame timing and fixture selection are opt-in. Ordinary remote capture
// keeps the full configured rectangle and avoids per-frame diagnostic I/O.
inline bool enabled() {
    static const bool value = [] {
        const char* setting = std::getenv("VIEWFLOW_REVERSE_DIAGNOSTICS");
        return setting && std::strcmp(setting, "1") == 0;
    }();
    return value;
}
// Keep explicit fixture selection independent of measurement overhead.
inline bool metrics() {
    static const bool quiet=[] {const auto* v=std::getenv("VIEWFLOW_REVERSE_DIAGNOSTICS_QUIET");return v && std::strcmp(v,"1")==0;}();
    return enabled() && !quiet;
}
}
