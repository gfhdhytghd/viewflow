#include "virtual_display_transient_checks.hpp"
#include <cassert>
#include <vector>
using namespace viewflow::display_transient;
template<class F> bool rejected(F fn){try{fn();return false;}catch(const std::runtime_error&){return true;}}
struct Identity {int adapter,target;bool primary;bool operator==(const Identity&)const=default;};
struct Record {int name;Identity id;int mode;};
int main(){
    assert(checks::payload_bytes(3,2,512,24,1560)==1536);
    for(auto size:{1559ull,1561ull})assert(rejected([&]{checks::payload_bytes(3,2,512,24,size);}));
    assert(rejected([]{checks::payload_bytes(0,0,512,24,24);}));
    assert(rejected([]{checks::payload_bytes(3,3,512,24,1560);}));
    assert(rejected([]{checks::payload_bytes(0xffffffffull,0,512,24,0);}));
    assert(rejected([]{checks::payload_bytes(1,0,512,UINT64_MAX,511);}));
    const auto same=[](const Record& a,const Record& b){return a.name==b.name&&a.id==b.id;};
    Record expected{6,{7,42,false},60},current=expected;
    assert(&checks::before_mutation(expected,&current,same)==&current);
    assert(rejected([&]{checks::before_mutation(expected,static_cast<const Record*>(nullptr),same);}));
    // Simulate two rollback steps: first valid; monitor reuses the same name
    // before second mutation. Mode equality must not hide the identity change.
    unsigned writes=0;
    checks::before_mutation(expected,&current,same);++writes;
    current.id.target=43;
    assert(rejected([&]{checks::before_mutation(expected,&current,same);++writes;}));assert(writes==1);
    current=expected;current.id.primary=true;
    assert(rejected([&]{checks::before_mutation(expected,&current,same);}));
    constexpr std::uint32_t optional_orientation=0x80,required_display=0x5c0020;
    constexpr auto fields=checks::restored_fields(optional_orientation,required_display);
    static_assert((fields&optional_orientation)==optional_orientation);
    static_assert((fields&required_display)==required_display);
}
