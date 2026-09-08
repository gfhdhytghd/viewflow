#include "atlas_frame_bindings.h"
using namespace viewflow::windows_preview;
static viewflow::vfgp::Frame frame(uint64_t id) {
  viewflow::vfgp::Frame value;
  value.identity=id; value.width=8; value.height=8;
  value.deadline_qpc=viewflow::vfgp::DeadlineQpc{1000+id,10'000'000};
  value.atlas=viewflow::vfgp::AtlasLayout{{0,99},1,1,1,100+id,true,true,
      {{{0,1},1,1,id,100+id,0,0,4,4}}};
  return value;
}
int main() {
  AtlasFrameBindings bindings;
  auto first=frame(1), second=frame(2);
  second.atlas->revision=2; second.atlas->tiles[0].placement_generation=2; second.atlas->tiles[0].x=4;
  if (!bindings.Stage(first) || !bindings.Stage(second)) return 1;
  const auto* original=bindings.Find(1,8,8);
  if (!original || original->layout.tiles[0].x!=0 || original->deadline.deadline!=1001 ||
      bindings.Find(1,4,4) || bindings.Find(3,8,8)) return 2;
  if (!bindings.Commit(2) || bindings.Find(1,8,8) || !bindings.Empty()) return 3;
  auto wrong=frame(3); wrong.atlas->revision=2;
  if (bindings.Stage(wrong)) return 4;
  AtlasFrameBindings initial;
  first.atlas->color_keyframe=false;
  if (initial.Stage(first)) return 5;
  first.atlas->color_keyframe=true;
  if (!initial.Stage(first)) return 6;
  auto gap=frame(3); gap.atlas->alpha_keyframe=false;
  if (initial.Stage(gap)) return 7;
  gap.atlas->alpha_keyframe=true;
  if (!initial.Stage(gap)) return 8;
  AtlasFrameBindings bounded;
  for (uint64_t id=1;id<=8;++id) if (!bounded.Stage(frame(id))) return 9;
  if (bounded.Stage(frame(9))) return 10;
  // Unknown/ambiguous discard must leave all pending layouts unchanged.
  if (bounded.DiscardUnbound(1) || bounded.DiscardUnbound(9) ||
      !bounded.Find(1,8,8) || !bounded.Find(8,8,8)) return 11;
  AtlasFrameBindings recovery;
  if (!recovery.Stage(frame(1)) || recovery.DiscardUnbound(2) ||
      !recovery.Find(1,8,8) || !recovery.DiscardUnbound(1)) return 12;
  if (!recovery.Empty() || recovery.Find(1,8,8) || recovery.Commit(1) ||
      recovery.DiscardUnbound(1) || recovery.Stage(frame(1))) return 13;
  auto dependent=frame(2);
  dependent.atlas->color_keyframe=false;
  if (recovery.Stage(dependent)) return 14;
  dependent.atlas->color_keyframe=true; dependent.atlas->alpha_keyframe=false;
  if (recovery.Stage(dependent)) return 15;
  // Fresh IDR still cannot reuse source timestamps/identities after discard.
  auto stale=frame(2); stale.atlas->tiles[0].source_frame=1;
  if (recovery.Stage(stale)) return 16;
  stale=frame(2); stale.atlas->tiles[0].source_ns=101;
  if (recovery.Stage(stale)) return 17;
  auto resumed=frame(2);
  if (!recovery.Stage(resumed) || !recovery.Commit(2)) return 18;
  auto following=frame(3); following.atlas->color_keyframe=false;
  if (!recovery.Stage(following) || !recovery.Commit(3)) return 19;
  AtlasFrameBindings growth;
  auto small=frame(1); if(!growth.Stage(small) || !growth.Commit(1))return 20;
  auto large=frame(2);large.width=16;
  if(growth.Stage(large))return 21; // Extent changes need a new revision.
  large.atlas->revision=2;large.atlas->color_keyframe=false;
  if(growth.Stage(large))return 22;
  large.atlas->color_keyframe=true;
  if(!growth.Stage(large) || !growth.Find(2,16,8) || growth.Find(2,8,8))return 23;
  AtlasFrameBindings moving;
  auto start=frame(1);
  start.atlas->desktop=viewflow::vfgp::DesktopLayout{1,{0,0,8000,8000}, {{{0,1},{0,0,4000,4000},true,0,0}}};
  if(!moving.Stage(start))return 24;
  auto moved=frame(2);moved.atlas->desktop=start.atlas->desktop;
  moved.atlas->desktop->windows[0].bounds.x_millidip=1000;
  moved.atlas->color_keyframe=false;
  if(!moving.Stage(moved))return 25;
  const auto* before=moving.Find(1,8,8);const auto* after=moving.Find(2,8,8);
  if(!before || !after || before->layout.desktop->windows[0].bounds.x_millidip!=0 ||
      after->layout.desktop->windows[0].bounds.x_millidip!=1000)return 26;
  auto stale_topology=frame(3);stale_topology.atlas->desktop=moved.atlas->desktop;
  stale_topology.atlas->desktop->topology_generation=0;
  if(moving.Stage(stale_topology))return 27;
  AtlasFrameBindings opacity;
  auto opaque=frame(1),transparent=frame(2);
  opaque.atlas->patches=std::vector<viewflow::vfgp::AtlasPatch>{{0,0,0,2,2,4,4}};
  transparent.atlas->patches=opaque.atlas->patches;
  opaque.alpha.assign(64,255);transparent.alpha=opaque.alpha;
  transparent.alpha[3*8+3]=0;
  if(!opacity.Stage(opaque) || !opacity.Stage(transparent))return 28;
  const auto* opaque_binding=opacity.Find(1,8,8);
  const auto* transparent_binding=opacity.Find(2,8,8);
  if(!opaque_binding || !transparent_binding ||
      opaque_binding->opaque_patches!=std::vector<uint8_t>{1} ||
      transparent_binding->opaque_patches!=std::vector<uint8_t>{0})return 29;
  AtlasFrameBindings shared_opacity;
  auto shared1=frame(1),shared2=frame(2),edge=frame(3),changed=frame(4),reshaped=frame(5);
  const auto immutable=std::make_shared<const std::vector<uint8_t>>(64,255);
  shared1.shared_alpha=immutable;shared2.shared_alpha=immutable;edge.shared_alpha=immutable;
  shared1.atlas->patches=opaque.atlas->patches;shared2.atlas->patches=shared1.atlas->patches;
  edge.atlas->patches=shared1.atlas->patches;edge.atlas->patches->at(0).x=0;edge.atlas->revision=2;
  changed.atlas->patches=shared1.atlas->patches;changed.atlas->revision=3;
  auto changed_samples=std::vector<uint8_t>(64,255);changed_samples[3*8+3]=0;
  changed.shared_alpha=std::make_shared<const std::vector<uint8_t>>(std::move(changed_samples));
  reshaped.atlas->patches=changed.atlas->patches;reshaped.atlas->revision=4;
  reshaped.width=16;reshaped.height=4;reshaped.shared_alpha=immutable;
  if(!shared_opacity.Stage(shared1)||!shared_opacity.Stage(shared2)||!shared_opacity.Stage(edge)||
     !shared_opacity.Stage(changed)||!shared_opacity.Stage(reshaped))return 30;
  for(auto id:{1,2,3,4,5}) {
    const auto* b=shared_opacity.Find(id,id==5?16:8,id==5?4:8);
    if(!b || b->opaque_patches!=std::vector<uint8_t>{uint8_t(id<=2)})return 31;
  }
  return 0;
}
