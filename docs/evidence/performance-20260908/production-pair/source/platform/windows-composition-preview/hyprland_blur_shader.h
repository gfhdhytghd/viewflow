#pragma once
static constexpr char kHyprlandBlurShader[]=R"HYPR(
// Derived from Hyprland 0.56.2, efb50993780079460b0cbed1363e2166a2de1d9f.
// Copyright (c) 2022-2026 vaxerski; BSD-3-Clause; see Hyprland-LICENSE.
Texture2D source:register(t0);SamplerState edge:register(s0);
cbuffer Params:register(b0){float2 texel;float radius;float passes;float contrast;float brightness;float noise;float vibrancy;float vibrancy_darkness;float unused;float2 noise_origin;float2 noise_scale;float2 reserved;}
struct V{float4 p:SV_Position;float2 uv:TEXCOORD;};
V vs(uint id:SV_VertexID){float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};V o;o.p=float4(p[id],0,1);o.uv=float2((p[id].x+1)*.5,(1-p[id].y)*.5);return o;}
// see http://alienryderflex.com/hsp.html
static const float Pr = 0.299;
static const float Pg = 0.587;
static const float Pb = 0.114;

// Y is "v" ( brightness ). X is "s" ( saturation )
// see https://www.desmos.com/3d/a88652b9a4
// Determines if high brightness or high saturation is more important
static const float a = 0.93;
static const float b = 0.11;
static const float c = 0.66; //  Determines the smoothness of the transition of unboosted to boosted colors
//

// http://www.flong.com/archive/texts/code/shapers_circ/
float doubleCircleSigmoid(float x, float a) {
    a = clamp(a, 0.0, 1.0);

    float y = .0;
    if (x <= a) {
        y = a - sqrt(a * a - x * x);
    } else {
        y = a + sqrt(pow(1. - a, 2.) - pow(x - 1., 2.));
    }
    return y;
}

float3 rgb2hsl(float3 col) {
    float red   = col.r;
    float green = col.g;
    float blue  = col.b;

    float minc  = min(col.r, min(col.g, col.b));
    float maxc  = max(col.r, max(col.g, col.b));
    float delta = maxc - minc;

    float lum = (minc + maxc) * 0.5;
    float sat = 0.0;
    float hue = 0.0;

    if (lum > 0.0 && lum < 1.0) {
        float mul = (lum < 0.5) ? (lum) : (1.0 - lum);
        sat       = delta / (mul * 2.0);
    }

    if (delta > 0.0) {
        float3 maxcVec = maxc.xxx;
        float3 masks   = float3((maxcVec == col)) * float3((maxcVec != float3(green, blue, red)));
        float3 adds    = float3(0.0, 2.0, 4.0) + float3(green - blue, blue - red, red - green) / delta;

        hue += dot(adds, masks);
        hue /= 6.0;

        if (hue < 0.0)
            hue += 1.0;
    }

    return float3(hue, sat, lum);
}

float3 hsl2rgb(float3 col) {
    const float onethird = 1.0 / 3.0;
    const float twothird = 2.0 / 3.0;
    const float rcpsixth = 6.0;

    float       hue = col.x;
    float       sat = col.y;
    float       lum = col.z;

    float3        xt = ((float3)0.0);

    if (hue < onethird) {
        xt.r = rcpsixth * (onethird - hue);
        xt.g = rcpsixth * hue;
        xt.b = 0.0;
    } else if (hue < twothird) {
        xt.r = 0.0;
        xt.g = rcpsixth * (twothird - hue);
        xt.b = rcpsixth * (hue - onethird);
    } else
        xt = float3(rcpsixth * (hue - twothird), 0.0, rcpsixth * (1.0 - hue));

    xt = min(xt, 1.0);

    float sat2   = 2.0 * sat;
    float satinv = 1.0 - sat;
    float luminv = 1.0 - lum;
    float lum2m1 = (2.0 * lum) - 1.0;
    float3  ct     = (sat2 * xt) + satinv;

    float3  rgb;
    if (lum >= 0.5)
        rgb = (luminv * ct) + lum2m1;
    else
        rgb = lum * ct;

    return rgb;
}


float4 prepare(V i):SV_Target{
 float4 col=source.Sample(edge,i.uv);
 if(contrast!=1){float3 x=saturate(col.rgb);float3 t=step(.5,x);float3 y=lerp(x,1-x,t);float3 a=.5*pow(2*y,contrast);col.rgb=lerp(a,1-a,t);}
 col.rgb*=max(1,brightness);return col;
}
float4 down(V i):SV_Target{
 // Hyprland uses full-sized scratch buffers and halfpixel=1/fullWidth.
 // Compact levels use 1/sourceWidth after changing the UV coordinate basis.
 float2 d=texel*radius;float4 sum=source.Sample(edge,i.uv)*4;
 sum+=source.Sample(edge,i.uv-d);sum+=source.Sample(edge,i.uv+d);
 sum+=source.Sample(edge,i.uv+float2(d.x,-d.y));sum+=source.Sample(edge,i.uv-float2(d.x,-d.y));
 float4 color=sum/8;
 if(vibrancy==0)return color;
 float darkness=1-vibrancy_darkness;float3 hsl=rgb2hsl(color.rgb);
 float perceivedBrightness=doubleCircleSigmoid(sqrt(color.r*color.r*Pr+color.g*color.g*Pg+color.b*color.b*Pb),.8*darkness);
 float b1=b*darkness;float boostBase=hsl[1]>0?smoothstep(b1-c*.5,b1+c*.5,1-(pow(1-hsl[1]*cos(a),2)+pow(1-perceivedBrightness*sin(a),2))):0;
 float saturation=clamp(hsl[1]+boostBase*vibrancy/passes,0,1);
 return float4(hsl2rgb(float3(hsl[0],saturation,hsl[2])),color[3]);
}
float4 up(V i):SV_Target{
 // Hyprland halfpixel=.25/fullWidth, transformed to the compact source level.
 float2 d=texel*.25*radius;
 float4 sum=source.Sample(edge,i.uv+float2(-2*d.x,0));
 sum+=source.Sample(edge,i.uv+float2(-d.x,d.y))*2;
 sum+=source.Sample(edge,i.uv+float2(0,2*d.y));
 sum+=source.Sample(edge,i.uv+float2(d.x,d.y))*2;
 sum+=source.Sample(edge,i.uv+float2(2*d.x,0));
 sum+=source.Sample(edge,i.uv+float2(d.x,-d.y))*2;
 sum+=source.Sample(edge,i.uv+float2(0,-2*d.y));
 sum+=source.Sample(edge,i.uv+float2(-d.x,-d.y))*2;return sum/12;
}
float4 finish(V i):SV_Target{
 float4 color=source.Sample(edge,i.uv);float2 nuv=noise_origin+i.uv*noise_scale;float3 p3=frac(nuv.xyx*1689.1984);
 p3+=dot(p3,p3.yzx+33.33);float hash=frac((p3.x+p3.y)*p3.z);
 color.rgb+=(hash-.5)*noise;color.rgb*=min(1,brightness);return color;
}
)HYPR";
