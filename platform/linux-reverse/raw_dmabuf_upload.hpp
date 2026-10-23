#pragma once
#include "../reverse-common/wire.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <array>
#include <sys/stat.h>
#include <climits>
#include <list>
#include <stdexcept>
#include <string_view>

namespace viewflow::reverse {
// Rendering-thread/current-context only. Import lifetime includes the slot
// lease in each in-flight job; cached imports retain only export ownership.
// GPU sampling is copied into the receiver's own
// texture before the source slot can be returned to its Windows writer.
class RawDmaBufUpload {
    struct Entry {
        // Retain the export/backing only, never the writer's slot lease.
        std::shared_ptr<void> owner;
        dev_t device{};ino_t inode{};std::uint64_t offset{};
        unsigned pitch{},width{},height{};
        EGLDisplay display=EGL_NO_DISPLAY;
        EGLContext context=EGL_NO_CONTEXT;
        EGLImageKHR image=EGL_NO_IMAGE_KHR;
        GLuint texture{};
        PFNEGLDESTROYIMAGEKHRPROC destroy{};
        ~Entry(){if(texture)glDeleteTextures(1,&texture);if(image!=EGL_NO_IMAGE_KHR)destroy(display,image);}
    };
    struct Job {
        std::shared_ptr<SharedPixels> pixels;
        std::shared_ptr<Entry> entry;
        GLsync done{};
    };
    std::list<Job> jobs_;
    std::list<std::shared_ptr<Entry>> cache_;
    std::size_t imports_{},hits_{};
    static constexpr std::size_t cache_limit=8;
    GLuint program_{},fbo_{},vao_{};
    PFNEGLCREATEIMAGEKHRPROC create_{};
    PFNEGLDESTROYIMAGEKHRPROC destroy_{};
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind_{};
    bool modifiers_{};
    static bool extension(const char* text,std::string_view name){
        std::string_view list=text?text:"";
        while(!list.empty()){const auto end=list.find(' ');if(list.substr(0,end)==name)return true;if(end==list.npos)break;list.remove_prefix(end+1);}return false;
    }
    static bool gl_extension(std::string_view name){
        GLint count{};glGetIntegerv(GL_NUM_EXTENSIONS,&count);
        for(GLint i=0;i<count;++i){const auto* value=glGetStringi(GL_EXTENSIONS,i);if(value && name==reinterpret_cast<const char*>(value))return true;}return false;
    }
    static void check(const char* stage){
        if(glGetError()!=GL_NO_ERROR){while(glGetError()!=GL_NO_ERROR){}throw std::runtime_error(stage);}
    }
    static GLuint shader(GLenum kind,const char* text){
        GLuint result=glCreateShader(kind);glShaderSource(result,1,&text,nullptr);glCompileShader(result);
        GLint ok{};glGetShaderiv(result,GL_COMPILE_STATUS,&ok);
        if(!ok){glDeleteShader(result);throw std::runtime_error("raw DMA-BUF shader compile");}return result;
    }
    struct State {
        GLint program{},draw_fbo{},vao{},active{},external{},sampler{},viewport[4]{};
        GLboolean mask[4]{};
        static constexpr std::array<GLenum,9> toggles={GL_BLEND,GL_DEPTH_TEST,GL_STENCIL_TEST,GL_CULL_FACE,GL_SCISSOR_TEST,GL_DITHER,GL_RASTERIZER_DISCARD,GL_SAMPLE_ALPHA_TO_COVERAGE,GL_SAMPLE_COVERAGE};
        std::array<GLboolean,toggles.size()> enabled{};
        State(){
            glGetIntegerv(GL_CURRENT_PROGRAM,&program);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&draw_fbo);
            glGetIntegerv(GL_VERTEX_ARRAY_BINDING,&vao);glGetIntegerv(GL_ACTIVE_TEXTURE,&active);
            glGetIntegerv(GL_VIEWPORT,viewport);glGetBooleanv(GL_COLOR_WRITEMASK,mask);
            glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES,&external);glGetIntegerv(GL_SAMPLER_BINDING,&sampler);
            for(std::size_t i=0;i<toggles.size();++i)enabled[i]=glIsEnabled(toggles[i]);
        }
        ~State(){
            for(std::size_t i=0;i<toggles.size();++i){if(enabled[i])glEnable(toggles[i]);else glDisable(toggles[i]);}
            glColorMask(mask[0],mask[1],mask[2],mask[3]);glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw_fbo);glUseProgram(program);glBindVertexArray(vao);
            glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_EXTERNAL_OES,external);glBindSampler(0,sampler);glActiveTexture(active);
        }
    };
    void release(Job& job) noexcept {
        if(job.done)glDeleteSync(job.done);
        job.entry.reset();
        job.pixels.reset();
    }
    void initialize(){
        if(program_)return;
        const auto display=eglGetCurrentDisplay();
        if(display==EGL_NO_DISPLAY || !extension(eglQueryString(display,EGL_EXTENSIONS),"EGL_EXT_image_dma_buf_import") ||
           !gl_extension("GL_OES_EGL_image_external") || !gl_extension("GL_OES_EGL_image_external_essl3"))
            throw std::runtime_error("raw DMA-BUF external import unavailable");
        create_=reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroy_=reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        bind_=reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        if(!create_ || !destroy_ || !bind_)throw std::runtime_error("raw DMA-BUF image entry points unavailable");
        modifiers_=extension(eglQueryString(display,EGL_EXTENSIONS),"EGL_EXT_image_dma_buf_import_modifiers");
        const GLuint vs=shader(GL_VERTEX_SHADER,"#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);}");
        GLuint fs{};
        try{fs=shader(GL_FRAGMENT_SHADER,"#version 300 es\n#extension GL_OES_EGL_image_external_essl3 : require\nprecision highp float;uniform highp samplerExternalOES source;uniform highp vec2 imageSize;out vec4 color;void main(){color=texture(source,gl_FragCoord.xy/imageSize).bgra;}");}
        catch(...){glDeleteShader(vs);throw;}
        const GLuint program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);
        glDeleteShader(vs);glDeleteShader(fs);GLint ok{};glGetProgramiv(program,GL_LINK_STATUS,&ok);
        if(!ok){glDeleteProgram(program);throw std::runtime_error("raw DMA-BUF shader link");}
        program_=program;glGenFramebuffers(1,&fbo_);glGenVertexArrays(1,&vao_);check("raw DMA-BUF GL resources");
    }
public:
    RawDmaBufUpload()=default;
    RawDmaBufUpload(const RawDmaBufUpload&)=delete;
    RawDmaBufUpload& operator=(const RawDmaBufUpload&)=delete;
    ~RawDmaBufUpload(){drain();cache_.clear();if(program_)glDeleteProgram(program_);if(fbo_)glDeleteFramebuffers(1,&fbo_);if(vao_)glDeleteVertexArrays(1,&vao_);}
    std::size_t import_count() const noexcept{return imports_;}
    std::size_t cache_hits() const noexcept{return hits_;}
    std::size_t cache_size() const noexcept{return cache_.size();}
    std::size_t pending() const noexcept{return jobs_.size();}
    void drain() noexcept {
        if(!jobs_.empty())glFinish();
        for(auto& job:jobs_)release(job);
        jobs_.clear();
    }
    // No wait/time cutoff. WAIT_FAILED uses a local full drain before releasing
    // any slot; it never treats a timing target as permission to recycle pixels.
    std::size_t poll() noexcept {
        for(auto it=jobs_.begin();it!=jobs_.end();){
            const GLenum result=glClientWaitSync(it->done,0,0);
            if(result==GL_WAIT_FAILED){glFinish();while(glGetError()!=GL_NO_ERROR){}for(auto& job:jobs_)release(job);jobs_.clear();break;}
            if(result==GL_ALREADY_SIGNALED || result==GL_CONDITION_SATISFIED){release(*it);it=jobs_.erase(it);}else ++it;
        }
        return jobs_.size();
    }
    // Destination has the existing raw path's R/B sampling swizzle. The shader
    // writes BGRA byte order into RGBA8 storage, preserving unmodified alpha.
    void upload(std::shared_ptr<SharedPixels> pixels,GLuint destination,unsigned width,unsigned height){
        if(!pixels || !pixels->dma_buffer || !destination || !width || !height || width>16384 || height>16384)
            throw std::runtime_error("raw DMA-BUF arguments");
        const auto& dma=*pixels->dma_buffer;
        if(dma.fd<0 || !dma.owner || dma.offset>INT_MAX || dma.pitch!=std::uint64_t(width)*4 || dma.pitch>INT_MAX)
            throw std::runtime_error("raw DMA-BUF descriptor");
        poll();initialize();State state;
        jobs_.emplace_back();auto it=std::prev(jobs_.end());auto& job=*it;
        job.pixels=std::move(pixels);
        bool drawn=false;
        try{
            struct stat identity{};
            if(fstat(dma.fd,&identity)!=0)throw std::runtime_error("raw DMA-BUF identity");
            const auto display=eglGetCurrentDisplay();const auto context=eglGetCurrentContext();
            for(auto found=cache_.begin();found!=cache_.end();++found){
                const auto& e=**found;
                if(e.device==identity.st_dev && e.inode==identity.st_ino && e.offset==dma.offset &&
                   e.pitch==dma.pitch && e.width==width && e.height==height && e.display==display && e.context==context){
                    job.entry=*found;cache_.splice(cache_.end(),cache_,found);++hits_;break;
                }
            }
            if(!job.entry){
                if(cache_.size()==cache_limit){
                    auto victim=cache_.begin();
                    while(victim!=cache_.end() && victim->use_count()!=1)++victim;
                    // All imports busy: complete outstanding local copies, retaining
                    // every source lease until completion, instead of disabling DMA.
                    if(victim==cache_.end()){
                        glFinish();
                        for(auto& pending:jobs_)if(&pending!=&job)release(pending);
                        for(auto pending=jobs_.begin();pending!=jobs_.end();)if(pending!=it)pending=jobs_.erase(pending);else ++pending;
                        victim=cache_.begin();
                    }
                    cache_.erase(victim);
                }
                auto entry=std::make_shared<Entry>();entry->owner=dma.owner;
                entry->device=identity.st_dev;entry->inode=identity.st_ino;entry->offset=dma.offset;
                entry->pitch=dma.pitch;entry->width=width;entry->height=height;
                entry->display=display;entry->context=context;entry->destroy=destroy_;
            EGLint attrs[]={EGL_WIDTH,static_cast<EGLint>(width),EGL_HEIGHT,static_cast<EGLint>(height),EGL_LINUX_DRM_FOURCC_EXT,DRM_FORMAT_ARGB8888,
                EGL_DMA_BUF_PLANE0_FD_EXT,dma.fd,EGL_DMA_BUF_PLANE0_OFFSET_EXT,static_cast<EGLint>(dma.offset),EGL_DMA_BUF_PLANE0_PITCH_EXT,static_cast<EGLint>(dma.pitch),
                EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,0,EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,0,EGL_NONE};
            if(!modifiers_)attrs[12]=EGL_NONE;
            entry->image=create_(entry->display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,nullptr,attrs);
            if(entry->image==EGL_NO_IMAGE_KHR)throw std::runtime_error("raw DMA-BUF EGL import");
            glGenTextures(1,&entry->texture);glBindTexture(GL_TEXTURE_EXTERNAL_OES,entry->texture);bind_(GL_TEXTURE_EXTERNAL_OES,entry->image);check("raw DMA-BUF external texture bind");
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
                check("raw DMA-BUF external texture parameters");
                cache_.push_back(entry);job.entry=std::move(entry);++imports_;
            }
            glBindTexture(GL_TEXTURE_EXTERNAL_OES,job.entry->texture);
            glBindSampler(0,0);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,fbo_);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,destination,0);
            if(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("raw DMA-BUF snapshot FBO");
            for(const auto cap:State::toggles)glDisable(cap);
            glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glViewport(0,0,width,height);glUseProgram(program_);glBindVertexArray(vao_);
            glUniform1i(glGetUniformLocation(program_,"source"),0);glUniform2f(glGetUniformLocation(program_,"imageSize"),width,height);
            check("raw DMA-BUF snapshot setup");
            glDrawArrays(GL_TRIANGLES,0,3);drawn=true;check("raw DMA-BUF snapshot draw");
            job.done=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);if(!job.done)throw std::runtime_error("raw DMA-BUF snapshot fence");
            glFlush();check("raw DMA-BUF snapshot submit");
        }catch(...){
            if(drawn)glFinish();
            release(job);jobs_.erase(it);
            while(glGetError()!=GL_NO_ERROR){}
            throw;
        }
    }
};
}
