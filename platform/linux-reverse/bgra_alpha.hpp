#pragma once
#include <span>
#include <cstdint>
#include <stdexcept>
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif
namespace viewflow::reverse {
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2")))
inline void extract_bgra_alpha_avx2(const std::uint8_t* source,std::uint8_t* target,std::size_t count) {
    std::size_t i=0;
    // AVX2 packs operate within 128-bit lanes; restore pixel order.
    const auto order=_mm256_setr_epi32(0,4,1,5,2,6,3,7);
    for(;i+32<=count;i+=32) {
        const auto a=_mm256_srli_epi32(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(source+4*i)),24);
        const auto b=_mm256_srli_epi32(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(source+4*i+32)),24);
        const auto c=_mm256_srli_epi32(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(source+4*i+64)),24);
        const auto d=_mm256_srli_epi32(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(source+4*i+96)),24);
        const auto packed=_mm256_packus_epi16(_mm256_packs_epi32(a,b),_mm256_packs_epi32(c,d));
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(target+i),_mm256_permutevar8x32_epi32(packed,order));
    }
    for(;i<count;++i)target[i]=source[i*4+3];
}
#endif
// Kept separately so the non-AVX2 path is exercised on AVX2 build hosts too.
inline void extract_bgra_alpha_baseline(std::span<const std::uint8_t> bgra,std::span<std::uint8_t> alpha) {
    const auto* source=bgra.data();auto* target=alpha.data();std::size_t i=0;
#if defined(__x86_64__) || defined(_M_X64)
    for(;i+16<=alpha.size();i+=16) {
        const auto a=_mm_srli_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(source+4*i)),24);
        const auto b=_mm_srli_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(source+4*i+16)),24);
        const auto c=_mm_srli_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(source+4*i+32)),24);
        const auto d=_mm_srli_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(source+4*i+48)),24);
        _mm_storeu_si128(reinterpret_cast<__m128i*>(target+i),_mm_packus_epi16(_mm_packs_epi32(a,b),_mm_packs_epi32(c,d)));
    }
#endif
    for(;i<alpha.size();++i)target[i]=source[i*4+3];
}
inline void extract_bgra_alpha(std::span<const std::uint8_t> bgra,std::span<std::uint8_t> alpha) {
    if(bgra.size()%4 || bgra.size()/4!=alpha.size())throw std::runtime_error("BGRA alpha extent");
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
    static const bool avx2=__builtin_cpu_supports("avx2");
    if(avx2){extract_bgra_alpha_avx2(bgra.data(),alpha.data(),alpha.size());return;}
#endif
    extract_bgra_alpha_baseline(bgra,alpha);
}

}
