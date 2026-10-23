Texture2D<float4> color:register(t0);
float4 vs(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}
float ps(float4 pos:SV_Position):SV_Target{return color.Load(int3(pos.xy,0)).a;}
