#pragma once
#include "annex_b.hpp"
#include <array>
#include <bit>
#include <cmath>
#include <optional>
#include <string_view>
namespace viewflow::reverse {
// H.264 user_data_unregistered SEI. Legacy decoders ignore it, so VFRV framing
// and older receivers remain compatible. Values are effective source settings.
inline constexpr std::string_view blur_recipe_uuid="ViewflowBlur0001";
struct BlurRecipe {
    bool enabled{};
    uint32_t size{},passes{};
    float contrast{},brightness{},noise{},vibrancy{},vibrancy_darkness{};
    bool operator==(const BlurRecipe&) const = default;
    bool valid() const {
        return size<=256&&passes>=1&&passes<=16&&
            std::isfinite(contrast)&&contrast>=0&&std::isfinite(brightness)&&brightness>=0&&
            std::isfinite(noise)&&noise>=0&&std::isfinite(vibrancy)&&vibrancy>=0&&
            std::isfinite(vibrancy_darkness)&&vibrancy_darkness>=0&&vibrancy_darkness<=1;
    }
    int64_t support() const { return (2*int64_t(size)+2)*((int64_t(1)<<passes)-1)+2; }
};
inline std::vector<uint8_t> h264_blur_recipe_sei(const BlurRecipe& recipe) {
    if(!recipe.valid())throw std::runtime_error("invalid blur recipe");
    std::vector<uint8_t> rbsp{5,52};rbsp.insert(rbsp.end(),blur_recipe_uuid.begin(),blur_recipe_uuid.end());
    for(uint32_t word:{1u,uint32_t(recipe.enabled),recipe.size,recipe.passes,std::bit_cast<uint32_t>(recipe.contrast),
        std::bit_cast<uint32_t>(recipe.brightness),std::bit_cast<uint32_t>(recipe.noise),std::bit_cast<uint32_t>(recipe.vibrancy),
        std::bit_cast<uint32_t>(recipe.vibrancy_darkness)})
        for(unsigned i=0;i<4;++i)rbsp.push_back(uint8_t(word>>(8*i)));
    rbsp.push_back(0x80);std::vector<uint8_t> nal{0,0,0,1,6};unsigned zeros=0;
    for(uint8_t byte:rbsp) {
        if(zeros>=2&&byte<=3){nal.push_back(3);zeros=0;}
        nal.push_back(byte);zeros=byte==0?zeros+1:0;
    }
    return nal;
}
inline std::optional<BlurRecipe> blur_recipe_from_annex_b(std::span<const uint8_t> bytes,uint32_t codec) {
    std::optional<BlurRecipe> result;
    for(auto unit:annex_b_units(bytes)) {
        size_t header=codec==1?1:2;
        if(unit.size()<=header||(codec==1?(unit[0]&31)!=6:((unit[0]>>1)&63)!=39))continue;
        std::vector<uint8_t> rbsp;unsigned zeros=0;
        for(uint8_t byte:unit.subspan(header)) {
            if(zeros>=2&&byte==3){zeros=0;continue;}
            rbsp.push_back(byte);zeros=byte==0?zeros+1:0;
        }
        size_t at=0;
        auto number=[&](size_t& value) {
            value=0;
            while(at<rbsp.size()){uint8_t byte=rbsp[at++];value+=byte;if(byte!=255)return true;}
            return false;
        };
        while(at<rbsp.size()&&rbsp[at]!=0x80) {
            size_t type=0,size=0;
            if(!number(type)||!number(size)||size>rbsp.size()-at)break;
            auto payload=std::span(rbsp).subspan(at,size);at+=size;
            if(type!=5||size!=52||!std::equal(blur_recipe_uuid.begin(),blur_recipe_uuid.end(),payload.begin()))continue;
            auto word=[&](unsigned offset) {
                uint32_t value=0;for(unsigned i=0;i<4;++i)value|=uint32_t(payload[offset+i])<<(8*i);return value;
            };
            if(word(16)!=1||word(20)>1)continue;
            BlurRecipe recipe{word(20)!=0,word(24),word(28),std::bit_cast<float>(word(32)),
                std::bit_cast<float>(word(36)),std::bit_cast<float>(word(40)),std::bit_cast<float>(word(44)),std::bit_cast<float>(word(48))};
            if(recipe.valid())result=recipe;
        }
    }
    return result;
}
}
