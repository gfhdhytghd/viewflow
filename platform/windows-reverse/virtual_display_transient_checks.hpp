#pragma once
#include <cstdint>
#include <limits>
#include <stdexcept>
namespace viewflow::display_transient::checks {
inline std::uint64_t payload_bytes(std::uint64_t count,std::uint64_t selected,
                                   std::uint64_t record_size,std::uint64_t header_size,
                                   std::uint64_t file_size){
    // ReadFile/WriteFile byte counts are DWORD. Reject overflow before casting
    // or allocating; also reject both truncated and trailing payload bytes.
    if(!count || selected>=count || !record_size ||
       count>std::numeric_limits<std::uint32_t>::max()/record_size)
        throw std::runtime_error("backup payload count/size invalid");
    const auto bytes=count*record_size;
    if(header_size>std::numeric_limits<std::uint64_t>::max()-bytes || file_size!=header_size+bytes)
        throw std::runtime_error("backup length mismatch");
    return bytes;
}
template<class Record,class Identity>
const Record& before_mutation(const Record& expected,const Record* current,Identity identity){
    if(!current || !identity(expected,*current))throw std::runtime_error("output identity changed before mutation");
    return *current;
}
constexpr std::uint32_t restored_fields(std::uint32_t original,std::uint32_t public_display_fields){
    return original|public_display_fields;
}
}
