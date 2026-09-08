#include "report_state.h"
#include <assert.h>
int main() {
    vf::ReportState s;
    uint8_t frame[32] = {1, 3, 7, 1, 0, 2, 0}; frame[31] = 1;
    assert(vf::valid_report(frame, 32));
    assert(s.apply(frame, 32, [](auto, auto) {return 9;}) == 9);
    assert(!s.active());
    assert(s.apply(frame, 32, [](auto, auto) {return 0;}) == 0 && s.active());
    assert(s.release([](auto p, auto n) {assert(n==32 && p[1]==2 && p[2]==7 && p[3]==1); return 8;})==8);
    assert(s.active());
    assert(s.release([](auto, auto) {return 0;})==0 && !s.active());
    assert(s.release([](auto, auto) {assert(false); return 0;})==0);
    frame[31]=6; assert(!vf::valid_report(frame,32)); frame[31]=1;
    frame[8]=1; assert(!vf::valid_report(frame,32)); frame[8]=0;
    frame[4]=0x80; assert(!vf::valid_report(frame,32)); frame[4]=0;
    frame[31]=2; frame[8]=7; assert(!vf::valid_report(frame,32));
    assert(!vf::valid_report(frame,31));
}
