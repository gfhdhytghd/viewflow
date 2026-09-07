#include "expired_frame_disposition.h"
#include <cstdio>
#include <initializer_list>
using namespace viewflow::windows_preview;
int main() {
  using S = vfgp_deadline::Status;
  using D = ExpiredFrameDisposition;
  for (bool enabled : {false, true}) {
    if (expired_frame_disposition(S::Ok, enabled) != D::Admit) return 1;
    for (auto error : {S::Missing, S::InvalidLocalFrequency, S::FrequencyMismatch})
      if (expired_frame_disposition(error, enabled) != D::Fail) return 2;
  }
  if (expired_frame_disposition(S::Expired, false) != D::Fail) return 3;
  if (expired_frame_disposition(S::Expired, true) != D::RejectExpired) return 4;
  // The boundary remains exact regardless of recovery mode. Only disposition
  // changes; recovery cannot turn an expired admission into Admit.
  for (uint64_t now : {100ull, 101ull, 102ull}) {
    auto status = vfgp_deadline::admit_live(
        true, false, viewflow::vfgp::DeadlineQpc{101, 1000}, 1000, now);
    auto expected = now < 101 ? D::Admit : D::RejectExpired;
    if (expired_frame_disposition(status, true) != expected) return 5;
  }
  std::puts("PASS explicit expired-frame disposition without admission extension");
}
