#pragma once
#include "atlas_frame_bindings.h"

namespace viewflow::windows_preview {
// Frame identity and source timestamps advance on each update. Every field
// that maps those pixels to a proxy must remain identical for bound updates.
inline bool SameSurfaceLayout(const AtlasFrameBinding& a, const AtlasFrameBinding& b) {
  const auto& x=a.layout;const auto& y=b.layout;
  if(a.width!=b.width || a.height!=b.height || x.stream!=y.stream ||
     x.geometry_epoch!=y.geometry_epoch || x.config_generation!=y.config_generation ||
     x.revision!=y.revision || !x.patches || x.patches!=y.patches ||
     a.opaque_patches!=b.opaque_patches || x.tiles.size()!=y.tiles.size() ||
     x.desktop.has_value()!=y.desktop.has_value())return false;
  for(size_t i=0;i<x.tiles.size();++i) {
    const auto& p=x.tiles[i];const auto& q=y.tiles[i];
    if(p.window!=q.window || p.geometry_epoch!=q.geometry_epoch ||
       p.placement_generation!=q.placement_generation || p.x!=q.x || p.y!=q.y ||
       p.width!=q.width || p.height!=q.height)return false;
  }
  if(x.desktop) {
    const auto same_rect=[](const auto& p,const auto& q) {
      return p.x_millidip==q.x_millidip && p.y_millidip==q.y_millidip &&
          p.width_millidip==q.width_millidip && p.height_millidip==q.height_millidip;
    };
    if(x.desktop->topology_generation!=y.desktop->topology_generation ||
       !same_rect(x.desktop->viewport,y.desktop->viewport) ||
       x.desktop->windows.size()!=y.desktop->windows.size())return false;
    for(size_t i=0;i<x.desktop->windows.size();++i) {
      const auto& p=x.desktop->windows[i];const auto& q=y.desktop->windows[i];
      if(p.window!=q.window || !same_rect(p.bounds,q.bounds) || p.movable!=q.movable ||
         p.z_order!=q.z_order || p.raise_serial!=q.raise_serial)return false;
    }
  }
  return true;
}
}
