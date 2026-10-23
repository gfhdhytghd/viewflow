#pragma once
#include "vfgp_deadline_admission.h"

namespace viewflow::windows_preview {
enum class ExpiredFrameDisposition { Admit, RejectExpired, Fail };
constexpr ExpiredFrameDisposition expired_frame_disposition(
    vfgp_deadline::Status status, bool recovery_enabled) {
  if (status == vfgp_deadline::Status::Ok)
    return ExpiredFrameDisposition::Admit;
  if (status == vfgp_deadline::Status::Expired && recovery_enabled)
    return ExpiredFrameDisposition::RejectExpired;
  return ExpiredFrameDisposition::Fail;
}
}  // namespace viewflow::windows_preview
