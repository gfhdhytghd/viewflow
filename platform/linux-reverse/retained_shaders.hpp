#pragma once
namespace viewflow::reverse {
inline constexpr const char* retained_vertex=R"(#version 300 es
out vec2 uv;
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*vec2(2,-2)+vec2(-1,1),0,1);})";
inline constexpr const char* retained_fragment=R"(#version 300 es
precision highp float;
in vec2 uv;out vec4 color;uniform sampler2D luma;uniform sampler2D chroma;uniform sampler2D opacity;uniform vec4 tile;uniform vec4 resident;uniform vec4 body;uniform bool straight_alpha;uniform bool raw_bgra;uniform bool desktop_opaque;
void main(){vec2 local=body.xy+uv*body.zw;if(any(lessThan(local,resident.xy)) || any(greaterThanEqual(local,resident.xy+resident.zw))){discard;}vec2 p=tile.xy+clamp(local-resident.xy,vec2(0.5),resident.zw-vec2(0.5))*tile.zw;if(raw_bgra){color=texture(luma,p);if(desktop_opaque)color.a=1.0;return;}float y=(texture(luma,p).r-16.0/255.0)*255.0/219.0;vec2 c=(texture(chroma,p).rg-vec2(128.0/255.0))*255.0/224.0;
float a=desktop_opaque ? 1.0 : texture(opacity,p).r;vec3 rgb=vec3(y+1.5748*c.y,y-0.187324*c.x-0.468124*c.y,y+1.8556*c.x);color=vec4(straight_alpha ? clamp(rgb,vec3(0),vec3(1))*a : clamp(rgb,vec3(0),vec3(a)),a);})";
}
