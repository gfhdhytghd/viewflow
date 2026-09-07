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
  return 0;
}
