#pragma once
#include "../reverse-common/backdrop.hpp"
#include "../reverse-common/backdrop_shm.hpp"
#include <png.h>
#include <filesystem>
#include <functional>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <sys/mman.h>
#include <fcntl.h>
#include <new>
#include <cstring>

namespace viewflow::reverse {
class BackdropClient {
    std::string path_;
    BackdropShm* memory_{};
    int fd_{-1};
    uint64_t id_;
    std::mutex mutex_;
    std::condition_variable changed_;
    bool stopping_{};
    int32_t source_x_{}, source_y_{};
    std::function<void(std::vector<uint8_t>)> send_;
    std::thread worker_;
    void run() {
        uint64_t last=0, sequence=0;
        std::vector<uint8_t> previous;
        int32_t previous_x=INT32_MIN,previous_y=INT32_MIN;
        while(true) {
            int32_t source_x,source_y;
            {
                std::unique_lock lock(mutex_);
                changed_.wait_for(lock,std::chrono::milliseconds(33),[&]{return stopping_;});
                if(stopping_)break;
                source_x=source_x_;source_y=source_y_;
            }
            const auto version=memory_->sequence.load(std::memory_order_acquire);
            if(!version || (version&1) || version==last)continue;
            const auto width=memory_->width,height=memory_->height;
            if(!width || !height || width>8192 || height>8192 || uint64_t(width)*height*4>backdrop_shm_pixels)continue;
            Backdrop frame;frame.id=id_;frame.sequence=++sequence;frame.pixel_width=width;frame.pixel_height=height;
            frame.x=source_x+memory_->x-memory_->window_x;frame.y=source_y+memory_->y-memory_->window_y;
            frame.width=memory_->logical_width;frame.height=memory_->logical_height;
            std::vector<uint8_t> pixels(static_cast<size_t>(width)*height*4);
            std::memcpy(pixels.data(),memory_+1,pixels.size());
            std::atomic_thread_fence(std::memory_order_acquire);
            if(memory_->sequence.load(std::memory_order_acquire)!=version)continue;
            last=version;
            if(pixels==previous && frame.x==previous_x && frame.y==previous_y)continue;
            png_image png{};png.version=PNG_IMAGE_VERSION;png.width=width;png.height=height;png.format=PNG_FORMAT_RGBA;png.flags=PNG_IMAGE_FLAG_FAST;
            png_alloc_size_t bytes=0;
            if(!png_image_write_to_memory(&png,nullptr,&bytes,0,pixels.data(),0,nullptr) || bytes>max_backdrop_record-52) {png_image_free(&png);continue;}
            frame.png.resize(bytes);
            if(!png_image_write_to_memory(&png,frame.png.data(),&bytes,0,pixels.data(),0,nullptr)) {png_image_free(&png);continue;}
            png_image_free(&png);frame.png.resize(bytes);
            try {send_(pack_backdrop(frame));} catch(const std::exception& error) {std::fprintf(stderr,"popup backdrop output stopped: %s\n",error.what());break;}
            if(previous.empty())std::fprintf(stderr,"popup backdrop id=%llu first=%ux%u png=%zu\n",(unsigned long long)id_,width,height,frame.png.size());
            previous=std::move(pixels);previous_x=frame.x;previous_y=frame.y;
        }
    }
public:
    BackdropClient(uint64_t id,uint64_t address,int32_t source_x,int32_t source_y,std::function<void(std::vector<uint8_t>)> send)
        :id_(id),source_x_(source_x),source_y_(source_y),send_(std::move(send)) {
        std::filesystem::create_directories(backdrop_directory());
        path_=backdrop_directory()+"/"+std::to_string(getpid())+"-"+std::to_string(address);
        fd_=open(path_.c_str(),O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
        if(fd_<0)throw std::runtime_error("create popup backdrop shared buffer");
        if(ftruncate(fd_,backdrop_shm_size)!=0){close(fd_);unlink(path_.c_str());throw std::runtime_error("size popup backdrop buffer");}
        auto* mapped=mmap(nullptr,backdrop_shm_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd_,0);
        if(mapped==MAP_FAILED){close(fd_);unlink(path_.c_str());throw std::runtime_error("map popup backdrop buffer");}
        memory_=new(mapped) BackdropShm{};
        memory_->pid=static_cast<uint32_t>(getpid());memory_->window=address;
        memory_->magic=backdrop_shm_magic;
        worker_=std::thread([this]{run();});
    }
    ~BackdropClient() {
        {std::lock_guard lock(mutex_);stopping_=true;}
        changed_.notify_all();if(worker_.joinable())worker_.join();
        unlink(path_.c_str());if(memory_)munmap(memory_,backdrop_shm_size);if(fd_>=0)close(fd_);
    }
    void update(int32_t source_x,int32_t source_y) {std::lock_guard lock(mutex_);source_x_=source_x;source_y_=source_y;}
};
}
