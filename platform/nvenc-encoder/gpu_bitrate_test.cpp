// Owned EGL texture oracle. Reuse the integration fixture's EGL/DMA-BUF helpers.
#define main viewflow_integration_fixture_main
#include "gpu_dmabuf_encoder_integration_test.cu"
#undef main

int main(int argc, char** argv) {
    const bool av1 = argc > 1 && std::strcmp(argv[1], "av1") == 0;
    const bool stress = argc > 3 && std::strcmp(argv[3], "stress") == 0;
    const bool fixed = argc > 2 && std::strcmp(argv[2], "fixed") == 0;
    W=3840; H=2160;
    Egl e;
    if (!ck(e.init(), "owned EGL fixture")) return 1;
    GLuint tex=0; glGenTextures(1,&tex); glBindTexture(GL_TEXTURE_2D,tex);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    std::vector<unsigned char> pixels(size_t(W)*H*4);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,W,H,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
    viewflow::gpu::GpuDmabufEncoderConfig config{W,H,16U*1024U*1024U};
    config.transparency=false; config.colorCodec=av1?4:2; config.bitrateKbps=fixed?0:900000;
    viewflow::gpu::GpuDmabufEncoder encoder(config);
    if (!ck(encoder.ready(), "bitrate encoder")) return 1;
    uint64_t bytes[3]{};
    // Three two-second segments; the first half second of each is settling time.
    for (int frame=0;frame<360;++frame) {
        if (!fixed && (frame==120 || frame==240)) {
            std::string error;
            if (!ck(encoder.setBitrateKbps(frame==120?8000:32000,&error),error.c_str())) return 1;
        }
        if (!ck(eglMakeCurrent(e.d,e.s,e.s,e.c)==EGL_TRUE,"producer context")) return 1;
        glBindTexture(GL_TEXTURE_2D,tex);
        // Scrolling editor-like glyphs, flat panels, and a moving gradient image.
        for (int y=0;y<H;++y) for(int x=0;x<W;++x) {
            int sy=y+frame*3;
            unsigned char v=unsigned((x/960)%2?238:32);
            if(x<2800 && sy%24<14 && x%13<8) {
                unsigned glyph=unsigned(x/13)*1664525U+unsigned(sy/24)*1013904223U;
                if((glyph>>((x%7+(stress?y:sy)%5)%24))&1) v=unsigned((x/960)%2?40:218);
            }
            auto p=(size_t(y)*W+x)*4;
            pixels[p]=x>2800?unsigned((x+frame*5+y/3)%256):v;
            pixels[p+1]=x>2800?unsigned((y+frame*3)%256):v;
            pixels[p+2]=x>2800?unsigned((x/3+y/7)%256):v;
            pixels[p+3]=255;
        }
        glTexSubImage2D(GL_TEXTURE_2D,0,0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
        Export exported;
        if(!ck(exportFrame(e,tex,exported),"owned DMA-BUF export")) return 1;
        viewflow::gpu::DmabufFrame input{};
        input.dmaBufFd=exported.fd; input.nativeFenceFd=exported.fence;
        input.imageWidth=W;input.imageHeight=H;input.cropWidth=W;input.cropHeight=H;
        input.stride=exported.stride;input.offset=exported.offset;input.modifier=exported.modifier;input.fourcc=0x34324241U;
        input.metadata={uint64_t(frame+1),uint64_t(frame+1)*16666667,1};
        viewflow::gpu::EncodedDmabufFrame output;
        std::string error;
        if(!ck(encoder.encode(input,frame%120==0,deadlineNs(5000),output,&error),error.c_str())) return 1;
        if(frame%120==0 && !ck(output.idr,"requested IDR survives reconfigure")) return 1;
        if(frame%120>=30) bytes[frame/120]+=output.colorAnnexB.size();
    }
    for(int i=0;i<3;++i) std::printf("bitrate codec=%s mode=%s segment=%d target_kbps=%d measured_kbps=%.1f frames=90\n",
        av1?"av1":"h264",fixed?"qp10":"vbr-cq7",i,fixed?0:(i==0?900000:i==1?8000:32000),double(bytes[i])*8*60/90/1000);
    if(!fixed) {
        const double low=double(bytes[1])*8*60/90/1000;
        const double high=double(bytes[2])*8*60/90/1000;
        if(!ck(low<16000 && low>4000 && high>16000 && high>low*1.5 && high<45000,"bitrate follows runtime target")) return 1;
    }
    return 0;
}
