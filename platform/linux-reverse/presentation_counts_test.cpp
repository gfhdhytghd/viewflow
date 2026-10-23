#include "presentation_counts.hpp"
#include <cassert>
#include <cmath>
using namespace viewflow::reverse;
int main() {
    PresentationCounts counts;counts.begin(1);
    auto& first=counts.windows[1];auto& second=counts.windows[2];
    first.present(100,1000000000,true,"DP-1");
    first.present(101,1016666667,true,"DP-1");
    first.present(101,1033333334,true,"DP-1");
    second.present(100,1000000000,true,"DP-1");
    assert(first.presented==3 && first.duplicate_pts==1 && first.source_pts.size()==2);
    assert(second.presented==1 && second.source_pts.size()==1); // no atlas double sum
    assert(std::abs(first.feedback_fps()-60)<0.001);
    assert(std::abs(first.unique_source_fps()-30)<0.001);
    first.present(999,0,false,"DP-1");assert(first.invalid==1 && first.source_pts.size()==2);
    ++first.discarded;++first.untracked;
    assert(!counts.due(20000000000ULL) && counts.due(20000000001ULL));
    first.present(99,990000000,true,"DP-1");assert(first.first_ns==990000000);
    first.present(102,1050000000,true,"DP-2");assert(first.output=="mixed");
    counts.clear(20000000001ULL);assert(counts.windows.empty() && !counts.due(20000000002ULL));
}
