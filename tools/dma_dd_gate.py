"""Pure log gate for owned DD + shared-source DMA; never a display/input action."""
import re


def ready(log):
    adopted = set(re.findall(r'profile_dd_submit pts=(\d+)\b[^\n]*\bwidth=6144 height=3456 shared_source=1 completed=0', log))
    completed = set(re.findall(r'profile_dd_shared_ready pts=(\d+)\b[^\n]*\bwidth=6144 height=3456 completed=1', log))
    return bool(adopted & completed)
