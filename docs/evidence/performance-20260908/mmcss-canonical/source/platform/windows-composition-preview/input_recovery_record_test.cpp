#include "vfgp_parser.h"
#include <array>
#include <cassert>

using namespace viewflow::vfgp;
static void put64(std::vector<uint8_t>& b, size_t at, uint64_t value) {
  for (size_t i = 0; i < 8; ++i) b[at+i] = uint8_t(value >> (56-i*8));
}
static std::vector<uint8_t> record(uint64_t sequence = 1) {
  std::vector<uint8_t> b(input_recovery_bytes);
  b[0]='V'; b[1]='F'; b[2]='G'; b[3]='P'; b[4]=6; b[11]=152;
  put64(b,16,sequence); put64(b,48,2); put64(b,64,3);
  for (size_t i=0;i<10;++i) put64(b,72+i*8,4+i);
  return b;
}
static void rejected_records() {
  auto bytes = record(10);
  bytes.resize(rejected_input_bytes);
  bytes[4] = 9; bytes[5] = 1; bytes[6] = 1; bytes[11] = 176;
  put64(bytes,96,6); put64(bytes,104,0); put64(bytes,152,10);
  put64(bytes,160,9); put64(bytes,168,10);
  assert(DecodeRejectedInput(bytes));
  assert(!DecodeInputRecovery(bytes));
  for (size_t chunk = 1; chunk <= bytes.size(); ++chunk) {
    Parser parser(4096,true,true,true); std::vector<Frame> output;
    for (size_t offset = 0; offset < bytes.size(); offset += chunk)
      assert(parser.Push(std::span(bytes).subspan(offset,(std::min)(chunk,bytes.size()-offset)), &output));
    assert(parser.Finish() && output.size() == 1 && output[0].input_recovery->rejection_kind == 1);
    auto resume = bytes;
    resume[5] = 2; put64(resume,16,11); put64(resume,104,1);
    assert(DecodeRejectedInput(resume) && parser.Push(resume,&output)); // Same geometry is explicit V9 only.
    assert(!parser.Push(record(11), &output)); // Shared V6/V9 control replay floor.
  }
  for (const auto at : {5u,6u,16u,48u,64u,72u,80u,88u,96u,112u,120u,128u,136u,144u,152u,160u,168u}) {
    auto bad = bytes;
    if (at < 8) bad[at] = 0; else put64(bad,at,0);
    assert(!DecodeRejectedInput(bad));
  }
  for (const auto at : {7u,12u,24u,32u,104u}) {
    auto bad = bytes; bad[at] = 1; assert(!DecodeRejectedInput(bad));
  }
  for (const auto length : {152u,175u}) {
    Parser parser(length,true,true,true); std::vector<Frame> output;
    assert(!parser.Push(bytes,&output));
  }
  Parser disabled(4096,true,true,false); std::vector<Frame> output;
  assert(!disabled.Push(bytes,&output));
}

int main() {
  rejected_records();
  const auto bytes=record();
  auto decoded=DecodeInputRecovery(bytes);
  assert(decoded && decoded->sequence==1 && decoded->stream==AtlasId(0,2) &&
      decoded->window==AtlasId(0,3) && decoded->previous_epoch==6 && decoded->geometry_epoch==7 &&
      decoded->grant_generation==8 && decoded->source_frame==10 && decoded->deadline_qpc==12 && decoded->frequency==13);
  for (size_t chunk=1;chunk<=bytes.size();++chunk) {
    Parser parser(4096,true,true,true); std::vector<Frame> output;
    for (size_t offset=0;offset<bytes.size();offset+=chunk)
      assert(parser.Push(std::span(bytes).subspan(offset,(std::min)(chunk,bytes.size()-offset)),&output));
    assert(parser.Finish() && output.size()==1 && output[0].input_recovery);
    assert(output[0].identity==0 && !output[0].atlas && !output[0].deadline_qpc &&
        output[0].color_au.empty() && output[0].alpha.empty());
    assert(!parser.Push(bytes,&output)); // Independent control replay ledger.
    assert(!parser.Finish());
  }
  for (size_t length=1;length<bytes.size();++length) {
    Parser parser(4096,true,true,true); std::vector<Frame> output;
    assert(parser.Push(std::span(bytes).first(length),&output));
    assert(output.empty() && !parser.Finish());
    assert(!DecodeInputRecovery(std::span(bytes).first(length)));
  }
  for (const auto offset : {16U,48U,64U,72U,80U,88U,96U,104U,112U,120U,128U,136U,144U}) {
    auto bad=bytes; put64(bad,offset,0);
    assert(!DecodeInputRecovery(bad));
    Parser parser(4096,true,true,true); std::vector<Frame> output;
    assert(!parser.Push(bad,&output) && output.empty());
  }
  for (const auto offset : {5U,6U,7U,12U,24U,32U}) {
    auto bad=bytes; bad[offset]=1;
    assert(!DecodeInputRecovery(bad));
  }
  { auto bad=bytes; put64(bad,96,6); assert(!DecodeInputRecovery(bad)); }
  for (const auto mode : {0,1,2}) {
    Parser parser(mode==2?151:4096,true,mode!=1,mode!=0); std::vector<Frame> output;
    assert(!parser.Push(bytes,&output));
  }
  // Control sequences cannot advance or reset the independent picture ledger.
  std::vector<uint8_t> picture(42); picture[0]='V';picture[1]='F';picture[2]='G';picture[3]='P';
  picture[4]=1;picture[11]=40;picture[15]=2;picture[27]=1;picture[31]=1;picture[35]=1;picture[39]=1;
  put64(picture,16,1);
  Parser parser(4096,true,true,true);std::vector<Frame> output;
  assert(parser.Push(picture,&output));
  assert(parser.Push(record(100),&output));
  put64(picture,16,2);assert(parser.Push(picture,&output));
  assert(parser.Finish() && output.size()==3 && output[0].identity==1 &&
      output[1].input_recovery->sequence==100 && output[2].identity==2);
}
