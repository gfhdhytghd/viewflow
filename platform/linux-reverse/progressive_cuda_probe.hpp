#pragma once
// Diagnostic device-buffer upload, not the production GL texture path.
#include <cuda.h>
#include <span>
#include <memory>
#include <vector>
#include <stdexcept>
#include <string>
class ProgressiveCudaProbe {
    std::shared_ptr<void> lease_;
    CUcontext context_{};CUstream stream_{};CUevent first_done_{};bool overlap_{};CUdeviceptr device_{};
    void* pinned_{};std::size_t size_{},submitted_{};unsigned bands_{};
    static void check(CUresult r){if(r!=CUDA_SUCCESS){const char* s=nullptr;cuGetErrorString(r,&s);throw std::runtime_error(std::string("CUDA probe: ")+(s?s:"unknown"));}}
    void close()noexcept{
        // Drain all outstanding DMA before unpinning or destroying resources.
        if(stream_)cuStreamSynchronize(stream_);
        if(first_done_)cuEventDestroy(first_done_);
        if(pinned_)cuMemHostUnregister(pinned_);
        if(device_)cuMemFree(device_);
        if(stream_)cuStreamDestroy(stream_);
        if(context_)cuCtxDestroy(context_);
    }
public:
    explicit ProgressiveCudaProbe(std::size_t size):size_(size){try{
        check(cuInit(0));CUdevice gpu{};check(cuDeviceGet(&gpu,0));
        check(cuCtxCreate(&context_,nullptr,0,gpu));
        check(cuStreamCreate(&stream_,CU_STREAM_NON_BLOCKING));check(cuMemAlloc(&device_,size_));check(cuEventCreate(&first_done_,CU_EVENT_DISABLE_TIMING));
    }catch(...){close();throw;}}
    ~ProgressiveCudaProbe(){close();}
    ProgressiveCudaProbe(const ProgressiveCudaProbe&)=delete;
    void retain(std::shared_ptr<void> lease){lease_=std::move(lease);}
    void append(std::span<const std::uint8_t> prefix){
        if(prefix.size()<submitted_ || prefix.size()>size_)throw std::runtime_error("GPU prefix bounds");
        if(prefix.size()==submitted_)return;
        if(!pinned_){check(cuMemHostRegister(const_cast<std::uint8_t*>(prefix.data()),size_,CU_MEMHOSTREGISTER_PORTABLE));pinned_=const_cast<std::uint8_t*>(prefix.data());}
        check(cuMemcpyHtoDAsync(device_+submitted_,prefix.data()+submitted_,prefix.size()-submitted_,stream_));
        if(!bands_)check(cuEventRecord(first_done_,stream_));
        submitted_=prefix.size();++bands_;
    }
    void drain(){check(cuStreamSynchronize(stream_));}
    std::vector<std::uint8_t> readback(){
        if(submitted_!=size_)throw std::runtime_error("incomplete GPU probe frame");
        drain();std::vector<std::uint8_t> result(size_);check(cuMemcpyDtoH(result.data(),device_,size_));return result;
    }
    template<class F> void observe_early(F&& still_incomplete){
        if(!bands_)return;
        const auto status=cuEventQuery(first_done_);
        // Read the producer prefix AFTER observing completed DMA.
        if(status==CUDA_SUCCESS){if(still_incomplete())overlap_=true;}
        else if(status!=CUDA_ERROR_NOT_READY)check(status);
    }
    bool early_completion()const{return overlap_;}
    unsigned bands()const{return bands_;}
};
