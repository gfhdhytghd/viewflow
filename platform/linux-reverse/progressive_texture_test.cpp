#include <sys/eventfd.h>
#include <unistd.h>
#include "gpu_decoder.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <chrono>
#include <thread>
#include <iostream>
using namespace viewflow::reverse;
int main(){try{
    auto query=reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    EGLDeviceEXT devices[8]{};EGLint count{};if(!query || !get_display || !query(8,devices,&count) || !count)throw std::runtime_error("probe EGL devices");
    auto display=get_display(EGL_PLATFORM_DEVICE_EXT,devices[0],nullptr);
    if(!eglInitialize(display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API))throw std::runtime_error("probe EGL init");
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config{};if(!eglChooseConfig(display,attrs,&config,1,&count) || !count)throw std::runtime_error("probe EGL config");
    const EGLint size[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE},version[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    auto surface=eglCreatePbufferSurface(display,config,size);auto context=eglCreateContext(display,config,EGL_NO_CONTEXT,version);
    if(!eglMakeCurrent(display,surface,surface,context))throw std::runtime_error("probe EGL context");

    constexpr unsigned w=6144,h=3456;constexpr std::size_t row=w*4,total=row*h;
    struct Bank{shm::ProgressiveFrame header{};std::vector<std::uint8_t> bytes=std::vector<std::uint8_t>(total);};
    auto bank=std::make_shared<Bank>();shm::ProgressiveStorage storage(bank->header,bank->bytes,bank);
    shm::ProgressiveReference ref{123,1,total,0,w,h};auto writer=storage.begin(ref);
    std::shared_ptr<shm::ProgressiveStorage::Read> reader=storage.acquire(writer->reference());
    struct Notify {int fd=eventfd(0,EFD_NONBLOCK|EFD_CLOEXEC);~Notify(){if(fd>=0)close(fd);}} notify;
    if(notify.fd<0)throw std::runtime_error("eventfd");
    GpuDecoder decoder;decoder.start(3);decoder.begin_progressive(reader,notify.fd,424242);reader.reset();
    unsigned polls=0;
    for(unsigned y=0;y<h;y+=128){
        const unsigned rows=std::min(128u,h-y);std::vector<std::uint8_t> source(row*rows);
        for(std::size_t i=0;i<source.size();++i){auto offset=y*row+i;source[i]=std::uint8_t((offset>>12)^offset);}
        writer->append(source,row,rows);
        if(decoder.poll_progressive()!=GpuDecoder::ProgressiveStatus::pending || decoder.y_texture()!=0)throw std::runtime_error("partial texture exposed");
        ++polls;
    }
    writer->finish();writer.reset();
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(decoder.poll_progressive()==GpuDecoder::ProgressiveStatus::pending){
        if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("GPU completion timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::uint64_t notifications{};
    if(read(notify.fd,&notifications,sizeof(notifications))!=sizeof(notifications) || notifications!=1)throw std::runtime_error("completion notification missing or duplicated");
    const auto retained=decoder.y_texture();if(!retained)throw std::runtime_error("missing completed texture");
    GLuint fbo{};glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,retained,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("probe framebuffer");
    std::vector<std::uint8_t> result(total);glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,result.data());
    if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("probe readback");
    for(std::size_t i=0;i<total;++i)if(result[i]!=std::uint8_t((i>>12)^i))throw std::runtime_error("texture byte mismatch "+std::to_string(i));
    // A second frame aborts after an asynchronous prefix submission.
    ++ref.sequence;writer=storage.begin(ref);if(!writer)throw std::runtime_error("completed lease not released");
    reader=storage.acquire(writer->reference());decoder.begin_progressive(reader);reader.reset();
    std::vector<std::uint8_t> band(row*128,42);writer->append(band,row,128);
    if(decoder.poll_progressive()!=GpuDecoder::ProgressiveStatus::pending)throw std::runtime_error("early complete");
    writer.reset();
    if(decoder.poll_progressive()!=GpuDecoder::ProgressiveStatus::aborted || decoder.y_texture()!=retained)throw std::runtime_error("abort lost snapshot");
    glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,result.data());
    for(std::size_t i=0;i<total;++i)if(result[i]!=std::uint8_t((i>>12)^i))throw std::runtime_error("abort mutated snapshot");
    ++ref.sequence;writer=storage.begin(ref);if(!writer)throw std::runtime_error("aborted lease not released");writer.reset();
    // Warm reuse, then shrink/grow: every generation must replace all bytes.
    for(unsigned frame=0;frame<5;++frame){
        ++ref.sequence;ref.width=frame==3?17:w;ref.height=frame==3?13:h;
        const auto stride=std::size_t(ref.width)*4,extent=stride*ref.height;
        writer=storage.begin(ref);if(!writer)throw std::runtime_error("warm slot busy");
        reader=storage.acquire(writer->reference());decoder.begin_progressive(reader);reader.reset();
        const auto previous=decoder.y_texture();
        for(unsigned y=0;y<ref.height;y+=128){
            const auto rows=std::min(128u,ref.height-y);std::vector<std::uint8_t> source(stride*rows);
            for(std::size_t i=0;i<source.size();++i){auto offset=y*stride+i;source[i]=std::uint8_t((offset>>12)^offset^ref.sequence);}
            writer->append(source,stride,rows);
            if(decoder.poll_progressive()!=GpuDecoder::ProgressiveStatus::pending || decoder.y_texture()!=previous)throw std::runtime_error("warm partial replaced snapshot");
        }
        writer->finish();writer.reset();
        deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
        while(decoder.poll_progressive()==GpuDecoder::ProgressiveStatus::pending){
            if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("warm GPU timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,decoder.y_texture(),0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("warm framebuffer");
        glReadPixels(0,0,ref.width,ref.height,GL_RGBA,GL_UNSIGNED_BYTE,result.data());
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("warm GL error");
        for(std::size_t i=0;i<extent;++i)if(result[i]!=std::uint8_t((i>>12)^i^ref.sequence))throw std::runtime_error("warm texture mismatch");
    }
    {
        // Two decoders read the same bank using the shared upload context. Destroy the registration's
        // original decoder while the other still holds an asynchronous upload.
        auto shared_cache=GpuDecoder::make_upload_cache();
        auto first=std::make_unique<GpuDecoder>(shared_cache);
        auto second=std::make_unique<GpuDecoder>(shared_cache);
        first->start(3);second->start(3);
        auto concurrent_bank=std::make_shared<Bank>();
        shm::ProgressiveStorage concurrent_storage(concurrent_bank->header,concurrent_bank->bytes,concurrent_bank);
        shm::ProgressiveReference concurrent_ref{999,1,total,0,w,h};
        auto concurrent_writer=concurrent_storage.begin(concurrent_ref);
        auto concurrent_reader=std::shared_ptr<shm::ProgressiveStorage::Read>(concurrent_storage.acquire(concurrent_writer->reference()));
        first->begin_progressive(concurrent_reader);second->begin_progressive(concurrent_reader);
        std::vector<std::uint8_t> source(total,97);concurrent_writer->append(source,row,h);concurrent_writer->finish();
        first->poll_progressive();second->poll_progressive();
        // First may already have finished; its texture indicates completion.
        deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
        while(!first->y_texture()){
            first->poll_progressive();if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("first shared upload timeout");
        }
        first.reset();
        while(!second->y_texture()){
            second->poll_progressive();if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("second shared upload timeout");
        }
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,second->y_texture(),0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("shared framebuffer");
        glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,result.data());
        if(glGetError()!=GL_NO_ERROR || result!=source)throw std::runtime_error("shared registration pixels");
    }
    glDeleteFramebuffers(1,&fbo);
    std::cout<<"texture_bytes="<<total<<" prefix_polls="<<polls<<" mismatches=0 completion_notification=1 abort_snapshot_preserved=1 lease_reusable=1 shared_decoder_registration=1 warm_generations=5 shrink_grow=1 renderer="<<glGetString(GL_RENDERER)<<"\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
