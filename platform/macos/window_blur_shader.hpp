#pragma once
// Port of ../windows-composition-preview/hyprland_blur_shader.h.
// Derived from Hyprland 0.56.2 efb50993780079460b0cbed1363e2166a2de1d9f.
// Copyright (c) 2022-2026 vaxerski; BSD-3-Clause; see
// ../windows-composition-preview/Hyprland-LICENSE.
static constexpr char kWindowBlurMetal[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Params { float2 texel; float radius, passes, contrast, brightness, noise, vibrancy;
 float vibrancy_darkness, unused; float2 noise_origin, noise_scale, reserved; };
struct V { float4 position [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) {
 float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};
 return {float4(p[id],0,1),float2((p[id].x+1)*.5,(1-p[id].y)*.5)};
}
constexpr sampler edge(coord::normalized,address::clamp_to_edge,filter::linear);
float sigmoid(float x,float a) {
 a=clamp(a,0.0f,1.0f);
 return x<=a ? a-sqrt(a*a-x*x) : a+sqrt(pow(1-a,2.0f)-pow(x-1,2.0f));
}
float3 rgb2hsl(float3 col) {
 float lo=min(col.r,min(col.g,col.b)), hi=max(col.r,max(col.g,col.b)), delta=hi-lo;
 float lum=(lo+hi)*.5, sat=0, hue=0;
 if(lum>0 && lum<1) sat=delta/((lum<.5?lum:1-lum)*2);
 if(delta>0) {
  float3 masks=float3(hi==col)*float3(hi!=float3(col.g,col.b,col.r));
  hue=dot(float3(0,2,4)+float3(col.g-col.b,col.b-col.r,col.r-col.g)/delta,masks)/6;
  if(hue<0) hue+=1;
 }
 return float3(hue,sat,lum);
}
float3 hsl2rgb(float3 col) {
 float h=col.x,s=col.y,l=col.z; float3 xt;
 if(h<1.0/3) xt=float3(6*(1.0/3-h),6*h,0);
 else if(h<2.0/3) xt=float3(0,6*(2.0/3-h),6*(h-1.0/3));
 else xt=float3(6*(h-2.0/3),0,6*(1-h));
 float3 ct=2*s*min(xt,1.0f)+(1-s);
 return l>=.5 ? (1-l)*ct+(2*l-1) : l*ct;
}
fragment float4 prepare(V i [[stage_in]],texture2d<float> source [[texture(0)]],constant Params& p [[buffer(0)]]) {
 float4 col=source.sample(edge,i.uv);
 if(p.contrast!=1) {float3 x=saturate(col.rgb),t=step(.5f,x),y=mix(x,1-x,t);
  col.rgb=mix(.5*pow(2*y,p.contrast),1-.5*pow(2*y,p.contrast),t);}
 col.rgb*=max(1.0f,p.brightness);return col;
}
fragment float4 down(V i [[stage_in]],texture2d<float> source [[texture(0)]],constant Params& p [[buffer(0)]]) {
 float2 d=p.texel*p.radius;
 float4 color=(source.sample(edge,i.uv)*4+source.sample(edge,i.uv-d)+source.sample(edge,i.uv+d)
  +source.sample(edge,i.uv+float2(d.x,-d.y))+source.sample(edge,i.uv-float2(d.x,-d.y)))/8;
 if(p.vibrancy==0)return color;
 float darkness=1-p.vibrancy_darkness;float3 hsl=rgb2hsl(color.rgb);
 float perceived=sigmoid(sqrt(dot(color.rgb*color.rgb,float3(.299,.587,.114))),.8*darkness);
 float b1=.11*darkness;
 float boost=hsl.y>0?smoothstep(b1-.66*.5,b1+.66*.5,1-(pow(1-hsl.y*cos(.93f),2.0f)+pow(1-perceived*sin(.93f),2.0f))):0;
 return float4(hsl2rgb(float3(hsl.x,clamp(hsl.y+boost*p.vibrancy/p.passes,0.0f,1.0f),hsl.z)),color.a);
}
fragment float4 up(V i [[stage_in]],texture2d<float> source [[texture(0)]],constant Params& p [[buffer(0)]]) {
 float2 d=p.texel*.25*p.radius;
 return (source.sample(edge,i.uv+float2(-2*d.x,0))+source.sample(edge,i.uv+float2(-d.x,d.y))*2
 +source.sample(edge,i.uv+float2(0,2*d.y))+source.sample(edge,i.uv+float2(d.x,d.y))*2
 +source.sample(edge,i.uv+float2(2*d.x,0))+source.sample(edge,i.uv+float2(d.x,-d.y))*2
 +source.sample(edge,i.uv+float2(0,-2*d.y))+source.sample(edge,i.uv+float2(-d.x,-d.y))*2)/12;
}
fragment float4 finish(V i [[stage_in]],texture2d<float> source [[texture(0)]],constant Params& p [[buffer(0)]]) {
 float4 color=source.sample(edge,i.uv);float2 nuv=p.noise_origin+i.uv*p.noise_scale;
 float3 p3=fract(nuv.xyx*1689.1984);p3+=dot(p3,p3.yzx+33.33);
 color.rgb+=(fract((p3.x+p3.y)*p3.z)-.5)*p.noise;
 color.rgb*=min(1.0f,p.brightness);return color;
}
)MSL";
