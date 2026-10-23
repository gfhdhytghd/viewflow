#include "warmup_admission.h"
#include <cstdio>
#include <initializer_list>
using viewflow::windows_preview::WarmupAdmission;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (false)
int main() {
  CHECK(WarmupAdmission::valid_count(1));
  CHECK(WarmupAdmission::valid_count(3));
  for (auto count : {0u, 2u, 4u, 0xffffffffu}) {
    WarmupAdmission invalid(count);
    CHECK(!invalid.admit(true, 1)); CHECK(!invalid.finish());
  }
  WarmupAdmission legacy;
  CHECK(legacy.admit(false, 1)); CHECK(legacy.finish());
  CHECK(!legacy.admit(true, 2));
  WarmupAdmission one;
  CHECK(one.admit(true, 1)); CHECK(!one.finish());
  CHECK(one.complete(1)); CHECK(one.admit(false, 2)); CHECK(one.finish());
  WarmupAdmission legacy_batch;
  CHECK(legacy_batch.admit(true, 1)); CHECK(legacy_batch.admit(false, 2));
  CHECK(legacy_batch.complete(1)); CHECK(legacy_batch.finish());
  WarmupAdmission three(3);
  for (uint64_t id : {1ull, 4ull, 9ull}) {
    CHECK(three.admit(true, id)); CHECK(!three.finish()); CHECK(three.complete(id));
  }
  CHECK(three.finish()); CHECK(three.admit(false, 12)); CHECK(three.finish());
  CHECK(!three.admit(true, 13));
  for (uint32_t done = 0; done < 3; ++done) {
    WarmupAdmission early(3);
    for (uint32_t id = 1; id <= done; ++id) {
      CHECK(early.admit(true, id)); CHECK(early.complete(id));
    }
    CHECK(!early.finish()); CHECK(!early.admit(false, 4));
    CHECK(!early.admit(true, 5)); // terminal rejection
  }
  WarmupAdmission pending(3);
  CHECK(pending.admit(true, 1)); CHECK(!pending.admit(true, 2));
  WarmupAdmission mismatch(3);
  CHECK(mismatch.admit(true, 1)); CHECK(!mismatch.complete(2));
  WarmupAdmission duplicate(3);
  CHECK(duplicate.admit(true, 2)); CHECK(duplicate.complete(2));
  CHECK(!duplicate.admit(true, 2));
  WarmupAdmission extra(3);
  for (uint64_t id = 1; id <= 3; ++id) {
    CHECK(extra.admit(true, id)); CHECK(extra.complete(id));
  }
  CHECK(!extra.admit(true, 4));
  std::puts("PASS bounded decode-only warmup admission");
}
