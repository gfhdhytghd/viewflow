// Owned synthetic pixels only. No desktop capture, windows, focus or input.
#include "egl_device.hpp"
#include "probe_texture.hpp"
#include "../nvenc-encoder/gpu_dmabuf_encoder.cuh"
#include "../nvenc-encoder/portable_dmabuf_import.hpp"
#include "../linux-reverse/gpu_decoder.hpp"
#include <GLES2/gl2ext.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <unistd.h>
extern "C" {
#include <libavutil/frame.h>
}
namespace {
constexpr int width=256,height=128,tileSize=64;
int64_t deadline() {return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()+5000000000ll;}
std::string json(const std::string& s) {
    std::string out="\"";
    for(unsigned char c:s) {
        if(c=='"' || c=='\\') {out+='\\';out+=c;}
        else if(c<32) {char b[7];std::snprintf(b,sizeof(b),"\\u%04x",c);out+=b;}
        else out+=c;
    }
    return out+'"';
}
struct Fixture {
    viewflow::media::EglDevice& egl;
    GLuint texture{};
    EGLImageKHR image=EGL_NO_IMAGE_KHR;
    int fd=-1,fence=-1;
    EGLint stride{},offset{},fourcc{};
    EGLuint64KHR modifier{};
    Fixture(viewflow::media::EglDevice& e):egl(e) {
        try {
            glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
            std::vector<unsigned char> rgba(tileSize*tileSize*4);
            for(size_t i=0;i<rgba.size();i+=4) {rgba[i]=50;rgba[i+1]=25;rgba[i+2]=10;rgba[i+3]=128;}
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,tileSize,tileSize,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());
            auto create=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
            auto query=reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
            auto exportImage=reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(eglGetProcAddress("eglExportDMABUFImageMESA"));
            auto createSync=reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(eglGetProcAddress("eglCreateSyncKHR"));
            auto dupSync=reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(eglGetProcAddress("eglDupNativeFenceFDANDROID"));
            auto destroySync=reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(eglGetProcAddress("eglDestroySyncKHR"));
            if(!create || !query || !exportImage || !createSync || !dupSync || !destroySync) throw std::runtime_error("EGL fixture export unavailable");
            const EGLint attrs[]={EGL_IMAGE_PRESERVED_KHR,EGL_TRUE,EGL_NONE};
            image=create(egl.display(),eglGetCurrentContext(),EGL_GL_TEXTURE_2D_KHR,reinterpret_cast<EGLClientBuffer>(uintptr_t(texture)),attrs);
            EGLint planes{};
            if(image==EGL_NO_IMAGE_KHR || !query(egl.display(),image,&fourcc,&planes,&modifier) || planes!=1 ||
                !exportImage(egl.display(),image,&fd,&stride,&offset)) throw std::runtime_error("EGL fixture DMA-BUF export failed");
            const EGLint syncAttrs[]={EGL_NONE};
            auto sync=createSync(egl.display(),EGL_SYNC_NATIVE_FENCE_ANDROID,syncAttrs);
            if(sync==EGL_NO_SYNC_KHR) throw std::runtime_error("EGL fixture native fence unavailable");
            glFlush();fence=dupSync(egl.display(),sync);destroySync(egl.display(),sync);
            if(fence<0) throw std::runtime_error("EGL fixture native fence export failed");
        } catch(...) {release();throw;}
    }
    void release()noexcept {
        if(fd>=0) close(fd);
        if(fence>=0) close(fence);
        auto destroy=reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        if(image!=EGL_NO_IMAGE_KHR && destroy) destroy(egl.display(),image);
        if(texture) glDeleteTextures(1,&texture);
    }
    ~Fixture(){egl.makeCurrent();release();}
    viewflow::gpu::DmabufFrame frame(uint64_t id)const {
        viewflow::gpu::DmabufFrame f;
        f.dmaBufFd=fd;f.nativeFenceFd=fence;f.imageWidth=tileSize;f.imageHeight=tileSize;
        f.stride=stride;f.offset=offset;f.fourcc=fourcc;f.modifier=modifier;
        f.cropWidth=tileSize;f.cropHeight=tileSize;f.metadata={id,id,1};return f;
    }
};
void verifyTexture(unsigned texture,int x,int y,int expected) {
    const auto pixel=viewflow::media::sampleTexture(texture,(float(x)+.5f)/width,(float(y)+.5f)/height);
    if(std::abs(int(pixel[0])-expected)>6)
        throw std::runtime_error("decoded EGL luma sample mismatch: expected "+std::to_string(expected)+", got "+std::to_string(pixel[0]));
}
}
int main(int argc,char** argv) {
    std::string backend="auto",node;
    try {
        for(int i=1;i<argc;i+=2) {
            if(i+1>=argc) throw std::invalid_argument("usage: viewflow-media-probe [--backend auto|nvidia|vaapi] [--render-node /dev/dri/renderD…]");
            if(!std::strcmp(argv[i],"--backend")) backend=argv[i+1];
            else if(!std::strcmp(argv[i],"--render-node")) node=argv[i+1];
            else throw std::invalid_argument("unknown media probe argument");
        }
        setenv("VIEWFLOW_MEDIA_BACKEND",backend.c_str(),1);
        if(!node.empty()) setenv("VIEWFLOW_MEDIA_RENDER_NODE",node.c_str(),1);
        auto selected=viewflow::media::selection(false);node=selected.renderNode;
        backend=selected.vaapi?"vaapi":"nvidia";
        viewflow::media::EglDevice egl(node);
        Fixture fixture(egl);
        // The producer is our own current context: complete its upload first.
        glFinish();
        auto portable=viewflow::gpu::readPortableDmabuf(egl.display(),{fixture.frame(1),0,0,deadline()});
        for(size_t i=0;i<portable.rgba.size();i+=4)
            if(portable.rgba[i]!=100 || portable.rgba[i+1]!=50 || portable.rgba[i+2]!=20 || portable.rgba[i+3]!=128)
                throw std::runtime_error("portable DMA-BUF readback/unpremultiply mismatch");
        viewflow::reverse::GpuDecoder decoder;decoder.start(1);
        std::string error;
        viewflow::gpu::GpuDmabufEncoder encoder({width,height,4*1024*1024,2},&error);
        if(!encoder.ready()) throw std::runtime_error(error);
        egl.makeCurrent();
        unsigned frames=0;
        for(unsigned id=1;id<=8;++id) {
            auto expires=deadline();auto input=fixture.frame(id);
            std::vector<viewflow::gpu::DmabufAtlasTile> tiles={{input,0,0,expires},{input,128,32,expires}};
            viewflow::gpu::SparseOptions sparse{false,width,height,{{0,0,0,0},{128,32,1,0}},true};
            viewflow::gpu::EncodedDmabufFrame encoded;
            viewflow::gpu::EncodeDisposition disposition{};
            if(!encoder.encodeAtlas(tiles,{id,id,1},id==1 || id==5,expires,encoded,&error,&disposition,id>4?&sparse:nullptr))
                throw std::runtime_error(error);
            if(encoded.alpha().size()!=width*height) throw std::runtime_error("alpha dimensions changed");
            for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
                const int alpha=(x<tileSize && y<tileSize) || (x>=128 && x<128+tileSize && y>=32 && y<32+tileSize)?128:0;
                if(encoded.alpha()[size_t(y)*width+x]!=alpha) throw std::runtime_error("atlas alpha mismatch");
            }
            if((id==1 || id==5) && !encoded.idr) throw std::runtime_error("IDR request not honored");
            egl.makeCurrent();
            for(auto& frame:decoder.submit(encoded.colorAnnexB,id*166667ll)) {
                if(frame->width!=width || frame->height!=height) throw std::runtime_error("decoded geometry mismatch");
                decoder.upload(frame);
                const int expected=((47*100+157*50+16*20+128)>>8)+16;
                verifyTexture(decoder.y_texture(),24,24,expected);
                verifyTexture(decoder.y_texture(),150,48,expected);
                verifyTexture(decoder.y_texture(),100,100,16);
                const auto uv=viewflow::media::sampleTexture(decoder.uv_texture(),24.5f/width,24.5f/height);
                const int wantU=((-26*100-87*50+112*20+128)>>8)+128;
                const int wantV=((112*100-102*50-10*20+128)>>8)+128;
                if(std::abs(int(uv[0])-wantU)>6 || std::abs(int(uv[1])-wantV)>6)
                    throw std::runtime_error("decoded EGL chroma sample mismatch");
                ++frames;
            }
        }
        if(frames!=8) throw std::runtime_error("decoder did not produce all probe frames");
        std::cout<<"{\"ok\":true,\"backend\":"<<json(backend)<<",\"render_node\":"<<json(node)
            <<",\"codec\":\"h264\",\"frames\":8,\"hardware_encode\":true,\"hardware_decode\":true,\"egl_import\":true,\"alpha_atlas\":true,\"portable_capture\":true,\"synthetic_only\":true}\n";
        return 0;
    } catch(const std::exception& error) {
        std::cout<<"{\"ok\":false,\"backend\":"<<json(backend)<<",\"render_node\":"<<json(node)<<",\"error\":"<<json(error.what())<<"}\n";
        return 1;
    }
}
