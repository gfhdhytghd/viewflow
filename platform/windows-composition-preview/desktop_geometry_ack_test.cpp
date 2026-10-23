#include "desktop_geometry_ack.h"
#include "ordered_desktop_output.h"
#include "vfgp_parser.h"
#include <cassert>
#include <vector>
int main() {
  std::vector<uint8_t> bytes(128);bytes[0]='V';bytes[1]='F';bytes[2]='G';bytes[3]='P';bytes[4]=10;bytes[11]=128;
  const auto set=[&](size_t o,uint64_t n){for(size_t i=0;i<8;++i)bytes[o+7-i]=uint8_t(n>>(i*8));};
  set(16,9);set(48,1);set(64,2);set(72,3);set(80,4);set(88,uint64_t(-1250));set(104,640000);set(112,480000);
  auto ack=viewflow::vfgp::DecodeDesktopGeometryAck(bytes);
  assert(ack && ack->x==-1250 && ack->sequence==9 && ack->drag==3);
  viewflow::vfgp::Parser parser(4096,true,true,true,true);
  std::vector<viewflow::vfgp::Frame> frames;
  for(auto byte:bytes)assert(parser.Push(std::span(&byte,1),&frames));
  assert(parser.Finish() && frames.size()==1 && frames[0].desktop_geometry_ack);
  bytes[120]=1;assert(!viewflow::vfgp::DecodeDesktopGeometryAck(bytes));
  std::deque<std::string> queue;
  const std::string prefix="desktop-move-v1 stream_hi=0 stream_lo=1 window_hi=0 window_lo=2 drag_id=3 config_generation=1 topology_generation=1 phase=";
  using viewflow::windows_preview::queue_desktop_output;
  queue_desktop_output(queue,prefix+"begin sequence=1\n");
  queue_desktop_output(queue,prefix+"update sequence=2\n");
  queue_desktop_output(queue,prefix+"update sequence=3\n");
  assert(queue.size()==2 && queue.back().find("sequence=3")!=std::string::npos);
  queue_desktop_output(queue,"button release\n");
  queue_desktop_output(queue,prefix+"update sequence=4\n");
  queue_desktop_output(queue,prefix+"end sequence=5\n");
  assert(queue.size()==5);
}
