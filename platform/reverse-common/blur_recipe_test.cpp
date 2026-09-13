#include "blur_recipe.hpp"
#include <cassert>
#include <cstdio>
#include <limits>
using namespace viewflow::reverse;
int main() {
    BlurRecipe recipe{true,5,4,.8916f,1,.0117f,.1696f,0};
    auto bytes=h264_blur_recipe_sei(recipe);
    assert(blur_recipe_from_annex_b(bytes,1)==recipe);
    assert(recipe.support()==182);
    auto changed=recipe;changed.enabled=false;changed.size=9;changed.passes=2;changed.contrast=1.2f;
    auto next=h264_blur_recipe_sei(changed);bytes.insert(bytes.end(),next.begin(),next.end());
    assert(blur_recipe_from_annex_b(bytes,1)==changed);
    assert(changed.support()==62);
    auto unknown=h264_blur_recipe_sei(recipe);unknown[7]='X';assert(!blur_recipe_from_annex_b(unknown,1));
    auto truncated=h264_blur_recipe_sei(recipe);truncated.resize(25);assert(!blur_recipe_from_annex_b(truncated,1));
    auto invalid=recipe;invalid.noise=std::numeric_limits<float>::quiet_NaN();assert(!invalid.valid());
    assert(annex_b_units(bytes).size()==2);
    std::puts("PASS blur recipe: SEI escaping, live replacement, disable, support, unknown/truncated metadata");
}
