#pragma once
#import <CoreImage/CoreImage.h>
#include "../reverse-common/window_residency.hpp"

namespace viewflow::macos {
// Missing pixels are not transparent pixels. Replace the received rectangle,
// including its transparent pixels, and preserve everything outside it.
inline CIImage* retain_window_patch(CIContext* context, CIImage* previous,
    CIImage* atlas, unsigned atlas_height, const viewflow::reverse::Tile& tile) {
    namespace vf = viewflow::reverse;
    const auto r=vf::resident_rect(tile);
    if(previous && (!r.width || !r.height))return previous;
    const CGRect extent=CGRectMake(0,0,tile.width,tile.height);
    CIImage* result=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:extent];
    const CGRect update=CGRectMake(r.x,tile.height-r.y-r.height,r.width,r.height);
    if(previous) {
        const CGRect bands[]={CGRectMake(0,0,tile.width,update.origin.y),
            CGRectMake(0,CGRectGetMaxY(update),tile.width,tile.height-CGRectGetMaxY(update)),
            CGRectMake(0,update.origin.y,update.origin.x,update.size.height),
            CGRectMake(CGRectGetMaxX(update),update.origin.y,tile.width-CGRectGetMaxX(update),update.size.height)};
        for(const auto band:bands)if(band.size.width>0 && band.size.height>0)
            result=[[previous imageByCroppingToRect:band] imageByCompositingOverImage:result];
    }
    if(r.width && r.height) {
        const CGRect crop=CGRectMake(tile.atlas_x,atlas_height-tile.atlas_y-r.height,r.width,r.height);
        CIImage* patch=[[atlas imageByCroppingToRect:crop] imageByApplyingTransform:
            CGAffineTransformMakeTranslation(update.origin.x-crop.origin.x,update.origin.y-crop.origin.y)];
        result=[patch imageByCompositingOverImage:result];
    }
    if(!previous || r==vf::PixelRect{0,0,tile.width,tile.height})return result;
    // Bound the dependency graph: never accumulate one CI node per old frame.
    CGImageRef snapshot=[context createCGImage:result fromRect:extent];
    if(!snapshot)return previous;
    CIImage* retained=[CIImage imageWithCGImage:snapshot];CGImageRelease(snapshot);return retained;
}
}
