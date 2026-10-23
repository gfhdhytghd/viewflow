# Primary references

[Intel VPL encode structures](https://intel.github.io/libvpl/latest/API_ref/VPL_structs_encode.html) defines GPB OFF as regular HEVC P pictures and QPI/QPP/QPB as constant-QP controls. [Streaming guidance](https://intel.github.io/libvpl/latest/appendix/VPL_apnds_c.html) describes runtime readback and low latency encoding. CQP does not retain the CBR bitrate constraint; quality and size must be evaluated separately before adoption. LowDelayBRC is not applied here because its documented modes exclude CBR.
