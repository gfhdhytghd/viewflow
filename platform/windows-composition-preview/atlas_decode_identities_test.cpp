#include "atlas_decode_identities.h"
using namespace viewflow::windows_preview;
int main() {
  AtlasDecodeIdentities identities;
  for (uint64_t i=1;i<=3;++i) {
    auto local=identities.Stage(i,64,64,true);
    if (!local || *local!=i) return 1;
    auto warmup=identities.Take(*local,64,64);
    if (!warmup || !warmup->warmup || warmup->source_identity!=i) return 2;
  }
  auto local=identities.Stage(1,64,64,false);
  if (!local || *local!=4 || identities.Take(1,64,64) || identities.Take(4,32,64)) return 3;
  auto live=identities.Take(4,64,64);
  if (!live || live->warmup || live->source_identity!=1 || identities.Take(4,64,64)) return 4;
  if (identities.Stage(2,128,64,false) || !identities.Empty()) return 5;
  for (uint64_t i=2;i<=9;++i) if (!identities.Stage(i,64,64,false)) return 6;
  if (identities.Stage(10,64,64,false)) return 7;
  return 0;
}
