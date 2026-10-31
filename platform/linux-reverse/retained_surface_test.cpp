#include "retained_surface.hpp"
#include "bgra_alpha.hpp"
#include "retained_shaders.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <array>
#include <cassert>
#include <cstdio>
using namespace viewflow::reverse;
using Pixel=std::array<unsigned char,4>;
GLuint compile(GLenum kind,const char* source) {
    const auto shader=glCreateShader(kind);glShaderSource(shader,1,&source,nullptr);glCompileShader(shader);
    GLint ok=0;glGetShaderiv(shader,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[4096]{};glGetShaderInfoLog(shader,sizeof(log),nullptr,log);std::fprintf(stderr,"%s\n",log);}
    assert(ok);return shader;
}
int main() {
    for(unsigned offset=0;offset<32;++offset)for(unsigned n=0;n<1024;++n){
        std::vector<std::uint8_t> input(offset+4*n),output(n+2,0x7b);
        for(unsigned i=0;i<input.size();++i)input[i]=(i*73)%256;
        for(auto extract : {extract_bgra_alpha,extract_bgra_alpha_baseline}) {
        std::fill(output.begin(),output.end(),0x7b);
        extract(std::span(input).subspan(offset),std::span(output).subspan(1,n));
        assert(output.front()==0x7b && output.back()==0x7b);
        for(unsigned i=0;i<n;++i)assert(output[i+1]==input[offset+4*i+3]);
        }
    }

    {
        RetainedAlpha retained;Tile tile;tile.width=tile.height=2;
        const std::vector<uint8_t> plane{1,2,3,4,5,6,7,8};
        retained.update(4,tile,plane);assert((retained.pixels==std::vector<uint8_t>{1,2,5,6}));
        const auto revision=retained.revision;retained.update(4,tile,plane,true);assert(retained.revision==revision);
        // The same immutable alpha plane does not imply the same atlas crop.
        tile.atlas_x=2;retained.update(4,tile,plane,true);
        assert((retained.pixels==std::vector<uint8_t>{3,4,7,8}));assert(retained.revision>revision);
    }

    // No Wayland connection, desktop input or focus. Run the production shader
    // against an offscreen EGL device and compare every retained pixel.
    auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    auto getDisplay=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    EGLDeviceEXT devices[8]{};EGLint count=0;assert(query&&getDisplay&&query(8,devices,&count)&&count);
    auto display=getDisplay(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);assert(eglInitialize(display,nullptr,nullptr));
    assert(eglBindAPI(EGL_OPENGL_ES_API));
    const EGLint attributes[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};assert(eglChooseConfig(display,attributes,&config,1,&count)&&count);
    const EGLint size[]={EGL_WIDTH,8,EGL_HEIGHT,8,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    auto surface=eglCreatePbufferSurface(display,config,size);auto context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
    assert(eglMakeCurrent(display,surface,surface,context));
    auto vs=compile(GL_VERTEX_SHADER,retained_vertex),fs=compile(GL_FRAGMENT_SHADER,retained_fragment);
    auto program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);
    GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);assert(ok);glUseProgram(program);
    glUniform1i(glGetUniformLocation(program,"raw_bgra"),1);
    glUniform1i(glGetUniformLocation(program,"luma"),0);
    GLuint input=0;glGenTextures(1,&input);
    RetainedSurface cache;RetainedAlpha alpha;
    Tile absent;absent.width=absent.height=16384;set_resident_rect(absent,{});
    alpha.update(1,absent,{});assert(alpha.pixels.empty()); // no initial 16K allocation for metadata-only windows

    auto update=[&](unsigned w,unsigned h,PixelRect r,Pixel color,unsigned bx=0,unsigned by=0) {
        cache.bind(w,h);glViewport(0,0,w,h);glDisable(GL_BLEND);
        std::vector<Pixel> pixels(std::max(1u,r.width*r.height),color);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,input);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,std::max(1u,r.width),std::max(1u,r.height),0,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
        glUniform4f(glGetUniformLocation(program,"tile"),0,0,1.f/std::max(1u,r.width),1.f/std::max(1u,r.height));
        glUniform4f(glGetUniformLocation(program,"body"),bx,by,w,h);
        glUniform4f(glGetUniformLocation(program,"resident"),r.x,r.y,r.width,r.height);
        Tile tile;tile.flags=16;tile.width=w+bx;tile.height=h+by;tile.body_x=bx;tile.body_y=by;tile.body_width=w;tile.body_height=h;
        set_resident_rect(tile,r);
        const auto update=retained_update_rect(tile);
        if(update.width && update.height) {
            glEnable(GL_SCISSOR_TEST);glScissor(update.x,h-update.y-update.height,update.width,update.height);
            glDrawArrays(GL_TRIANGLES,0,3);glDisable(GL_SCISSOR_TEST);
        }
        assert(glGetError()==GL_NO_ERROR);
        std::vector<uint8_t> a(pixels.size(),color[3]);alpha.update(std::max(1u,r.width),tile,a);
        const auto revision=alpha.revision;alpha.update(std::max(1u,r.width),tile,a,true);assert(alpha.revision==revision);
    };
    auto verify=[&](unsigned w,unsigned h,const std::vector<Pixel>& expected) {
        cache.bind(w,h);std::vector<Pixel> actual(size_t(w)*h);glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,actual.data());
        for(unsigned y=0;y<h/2;++y)for(unsigned x=0;x<w;++x)std::swap(actual[size_t(y)*w+x],actual[size_t(h-1-y)*w+x]);
        if(actual!=expected){std::fprintf(stderr,"mismatch size=%ux%u\n",w,h);for(size_t i=0;i<actual.size();++i)if(actual[i]!=expected[i])std::fprintf(stderr,"pixel %zu actual=%u,%u,%u,%u expected=%u,%u,%u,%u\n",i,actual[i][0],actual[i][1],actual[i][2],actual[i][3],expected[i][0],expected[i][1],expected[i][2],expected[i][3]);}assert(actual==expected);assert(alpha.width==w&&alpha.height==h);
        for(size_t i=0;i<actual.size();++i)assert(alpha.pixels[i]==actual[i][3]);
    };
    const Pixel red{255,0,0,255},green{0,255,0,255},clear{0,0,0,0};
    std::vector<Pixel> expected(12,red);update(4,3,{0,0,4,3},red);verify(4,3,expected);
    update(4,3,{1,1,2,1},green);expected[5]=expected[6]=green;verify(4,3,expected);
    // A real transparent update erases stale content; omitted pixels do not.
    update(4,3,{2,1,1,1},clear);expected[6]=clear;verify(4,3,expected);
    update(4,3,{},clear);verify(4,3,expected);
    // New area has no received pixels; overlap retains exact source positions.
    update(6,4,{},clear);std::vector<Pixel> grown(24,clear);
    for(unsigned y=0;y<3;++y)for(unsigned x=0;x<4;++x)grown[y*6+x]=expected[y*4+x];
    verify(6,4,grown);
    update(3,2,{},clear);std::vector<Pixel> shrunk(6);
    for(unsigned y=0;y<2;++y)for(unsigned x=0;x<3;++x)shrunk[y*3+x]=expected[y*4+x];
    verify(3,2,shrunk);
    // Native body offsets must not shift updates relative to the saved image.
    update(3,2,{8,5,1,1},green,7,5);shrunk[1]=green;
    verify(3,2,shrunk);
    cache.present(3,2);std::vector<Pixel> presented(6);glReadPixels(0,0,3,2,GL_RGBA,GL_UNSIGNED_BYTE,presented.data());for(unsigned x=0;x<3;++x)std::swap(presented[x],presented[3+x]);assert(presented==shrunk);
    // A fitted image clears both letterbox bands. This uses only an EGL
    // pbuffer and retained synthetic pixels, never a live surface/capture.
    cache.present(3,4,0,1,3,2);
    std::vector<Pixel> boxed(12);glReadPixels(0,0,3,4,GL_RGBA,GL_UNSIGNED_BYTE,boxed.data());
    for(unsigned x=0;x<3;++x) {
        assert((boxed[x]==Pixel{0,0,0,255}));
        assert((boxed[9+x]==Pixel{0,0,0,255}));
        assert(boxed[3+x]==shrunk[3+x] && boxed[6+x]==shrunk[x]);
    }
    // Desktop Duplication alpha is undefined. The same snapshot draw must
    // preserve RGB but force opaque alpha, without changing ordinary WGC.
    glUniform1i(glGetUniformLocation(program,"desktop_opaque"),1);
    const Pixel desktop_pixel{37,83,149,0};
    update(3,2,{0,0,3,2},desktop_pixel);
    cache.bind(3,2);std::vector<Pixel> opaque(6);
    glReadPixels(0,0,3,2,GL_RGBA,GL_UNSIGNED_BYTE,opaque.data());
    for(const auto pixel:opaque)assert((pixel==Pixel{37,83,149,255}));
    glUniform1i(glGetUniformLocation(program,"desktop_opaque"),0);
    update(3,2,{0,0,3,2},clear);verify(3,2,std::vector<Pixel>(6,clear));
    std::printf("retained RGBA/alpha partial, empty, transparent, resize, offset and presentation: passed (%s)\n",glGetString(GL_RENDERER));
    cache.reset();glDeleteTextures(1,&input);glDeleteProgram(program);glDeleteShader(vs);glDeleteShader(fs);
    eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
}
