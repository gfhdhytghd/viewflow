#pragma once
#include "portable_rgba.hpp"
#include <EGL/egl.h>
namespace viewflow::gpu {
// Caller has validated the descriptor and waited its producer fence. All GPU
// reads finish before return, including when an exception unwinds the import.
CpuTile readPortableDmabuf(EGLDisplay,const DmabufAtlasTile&);
}
