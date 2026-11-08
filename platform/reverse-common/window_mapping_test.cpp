#include "window_surface.hpp"
#include "source_drag.hpp"
#include "window_resize.hpp"
#include "window_regions.hpp"
#include <cassert>
#include <cmath>
namespace vf=viewflow::reverse;
int main() {
    // Native-frame grabs use logical body units; legacy grabs use scaled
    // desktop units. Both must land at the same point on a scale-two host.
    vf::Tile legacy_grab,native_grab;
    native_grab.flags=16;native_grab.pixel_scale=2;
    for(double receiver_scale:{1.,1.5,2.,3.}) {
        const auto x=vf::drag_grab_pixels(120,2), y=vf::drag_grab_pixels(24,2);
        assert(vf::drag_grab_points(legacy_grab,x,receiver_scale)==240/receiver_scale);
        assert(vf::drag_grab_points(native_grab,120,receiver_scale)==240/receiver_scale);
        assert(vf::drag_grab_points(legacy_grab,y,receiver_scale)==48/receiver_scale);
        assert(vf::drag_grab_points(native_grab,24,receiver_scale)==48/receiver_scale);
    }
    assert(-3072+500-vf::drag_grab_points(native_grab,120,2)==-2692);
    vf::Tile windows_grab;windows_grab.flags=16;windows_grab.pixel_scale=1;
    assert(vf::drag_grab_points(windows_grab,120,2)==60);
    // Source hint can start without a local mouseDown. Source release clears
    // the hint but must not stop local following before the physical mouseUp.
    vf::SourceDrag source_drag;
    assert(source_drag.observe(true,false,true)==vf::SourceDragAction::none);
    assert(source_drag.observe(true,true,false)==vf::SourceDragAction::none);
    assert(source_drag.observe(true,true,true)==vf::SourceDragAction::begin);
    assert(source_drag.observe(false,true,false)==vf::SourceDragAction::follow);
    assert(source_drag.observe(false,false,true)==vf::SourceDragAction::finish);
    assert(source_drag.observe(false,false,true)==vf::SourceDragAction::none);
    assert(source_drag.observe(true,true,true)==vf::SourceDragAction::begin);
    source_drag.cancel();
    assert(source_drag.observe(true,true,true)==vf::SourceDragAction::none);
    assert(source_drag.observe(false,true,true)==vf::SourceDragAction::none);
    assert(source_drag.observe(true,true,true)==vf::SourceDragAction::begin);
    assert(source_drag.observe(true,false,true)==vf::SourceDragAction::finish);
    assert(source_drag.observe(true,true,true)==vf::SourceDragAction::none); // old hint, new press
    // Resize follows the pointer: no pause-based debounce, latest wins.
    vf::WindowResize resize;
    assert(!resize.ready());
    resize.queue({10,20,800,600});
    assert(resize.ready());
    resize.queue({10,20,1000,800});
    assert(resize.ready() && resize.candidate->width==1000);
    resize.cancel();assert(!resize.ready());
    for(int i=0;i<1000;++i) {
        resize.queue({-3072+i,-299+i,1000+i,800});
        assert(resize.ready() && resize.candidate->width==1000+i);
    }
    resize.cancel();assert(!resize.ready()); // fullscreen or successful send
    // Interactive-resize state detection from an xdg_toplevel state list.
    const std::uint32_t activated_only[]={4};
    const std::uint32_t resizing[]={4,3,1};
    assert(!vf::toplevel_resizing(activated_only,1) && vf::toplevel_resizing(resizing,3) && !vf::toplevel_resizing(resizing,0));
    // Top strip moves, content below it does not; short windows keep a third.
    assert(vf::classify_pointer(0,584)==vf::PointerRegion::titlebar);
    assert(vf::classify_pointer(43.9,584)==vf::PointerRegion::titlebar);
    assert(vf::classify_pointer(44,584)==vf::PointerRegion::content);
    assert(vf::classify_pointer(-1,584)==vf::PointerRegion::content);
    assert(vf::classify_pointer(30,90)==vf::PointerRegion::content);
    assert(vf::classify_pointer(28.9,87)==vf::PointerRegion::titlebar);
    // Source clicks stay inside the source resize zone margin.
    assert(vf::inset_source_point(0,584)==vf::source_edge_inset_points);
    assert(vf::inset_source_point(584,584)==584-vf::source_edge_inset_points);
    assert(vf::inset_source_point(300,584)==300);
    assert(vf::inset_source_point(-20,584)==vf::source_edge_inset_points);
    assert(vf::inset_source_point(0,4)==1 && vf::inset_source_point(0,0)==0);
    assert(!vf::drag_exceeds_slop(2,2) && vf::drag_exceeds_slop(4,0) && vf::drag_exceeds_slop(-3,3));
    // A stretched proxy (resize ahead of the source frame) has no letterbox:
    // the whole surface is body and pointer mapping scales to the old frame.
    const auto stretched=vf::body_surface(1000,800);
    assert(vf::body_point(stretched,0,0) && vf::body_point(stretched,999,799) && !vf::body_point(stretched,1000,0));
    assert(vf::local_pointer(500,1000,1600,true)==800);
    // A tiled 1000x800 proxy still displays an old 1600x900 Retina body.
    const auto fit=vf::fitted_body(1000,800,1600,900);
    assert(fit.x==0 && fit.y==118 && fit.body_width==1000 && fit.body_height==563);
    assert(!vf::body_point(fit,500,117));
    assert(vf::body_point(fit,500,400));
    assert(!vf::body_point(fit,500,681));
    // Negative parking origin, scale two, compositor gaps and borders do not
    // enter the local ratio. Source actual bounds win over requested geometry.
    const double px=(500-fit.x)*1600./fit.body_width;
    assert(-3072+vf::local_pointer(px,1600,800,true)==-2672);
    assert(-299+vf::local_pointer(450,900,450,true)==-74);
    assert(vf::local_pointer(1600,1600,800,true)==799.5);
    assert(vf::local_pointer(-40,1600,800,true)==0);
    assert(vf::local_pointer(-40,1600,800,false)==-20); // held drag
    assert(vf::local_pointer(800,1600,1200,true)==600); // resize before next frame
    for(auto dimensions : {std::pair{1600u,900u},std::pair{16384u,16384u}}) {
        const auto packed=std::bit_cast<unsigned>(vf::pointer_extent(dimensions.first,dimensions.second));
        assert((packed&65535u)==dimensions.first && (packed>>16)==dimensions.second);
    }
    // A compositor tiling transition must reach a debounced source request,
    // even when the source still reports a different (minimum) window size.
    vf::GeometrySync sync;
    const vf::Geometry local{8,12,500,400},remote{8,12,800,600};
    assert(sync.observe(local,remote,0,false)==vf::GeometryAction::send_local);
    resize.queue(local);
    assert(sync.observe(local,remote,0,false)==vf::GeometryAction::none);
    assert(resize.ready());
    // The source divides the scale-two request back to logical AX points.
    const auto physical_width=resize.candidate->width*2;
    assert(physical_width/2==500);
    resize.cancel();sync.sent(20);
    assert(sync.observe(local,remote,20,false)==vf::GeometryAction::none);
    const auto constrained=vf::fitted_body(local.width,local.height,1600,1200);
    assert(constrained.body_width==500 && constrained.body_height==375);
    assert(vf::local_pointer(800,1600,800,true)==400);
    // A final bounds check clamps a stale global press into the new backing.
    assert(-3072+vf::local_pointer(-4000-(-3072),1,800,true)==-3072);
    assert(-299+vf::local_pointer(1000-(-299),1,600,true)==300.5);
    const auto portrait=vf::fitted_body(600,1000,1600,900);
    assert(portrait.body_width==600 && portrait.body_height==338 && portrait.y==331);
    const auto fullscreen=vf::fitted_body(1920,1080,1600,900);
    assert(fullscreen.x==0 && fullscreen.y==0 && fullscreen.body_width==1920);
    assert(vf::fitted_body(0,0,1600,900).body_width==0);
}
