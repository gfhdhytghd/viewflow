Texture2D<float> color:register(t0);
RWTexture2D<uint> summary:register(u0);
groupshared uint opaque_group[256];
[numthreads(16,16,1)]
void main(uint3 group:SV_GroupID,uint3 local:SV_GroupThreadID) {
    uint width,height;color.GetDimensions(width,height);uint opaque=1;
    [unroll] for(uint y=0;y<4;++y) [unroll] for(uint x=0;x<4;++x) {
        uint2 p=group.xy*64+local.xy*4+uint2(x,y);
        if(p.x<width && p.y<height) {
            uint value=uint(round(saturate(color.Load(int3(p,0)))*255.0));
            opaque&=uint(value==255);
        }
    }
    uint index=local.y*16+local.x;opaque_group[index]=opaque;GroupMemoryBarrierWithGroupSync();
    [unroll] for(uint stride=128;stride>0;stride>>=1) {
        if(index<stride)opaque_group[index]&=opaque_group[index+stride];
        GroupMemoryBarrierWithGroupSync();
    }
    if(index==0)summary[group.xy]=opaque_group[0];
}
