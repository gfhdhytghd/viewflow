#pragma once
#include "d12_desktop_capture.hpp"
#include "d12_shared_capture.hpp"
#include <dwmapi.h>
#include <set>
#include <array>
#include <cstdio>

namespace viewflow::reverse::d12 {
// DD returns an unrotated surface with the desktop image rotated inside it.
// This copy-only path has no rotation shader yet; keep those outputs on WGC.
constexpr bool fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION rotation) noexcept {
    return rotation==DXGI_MODE_ROTATION_IDENTITY;
}
static_assert(fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION_IDENTITY));
static_assert(!fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION_UNSPECIFIED));
static_assert(!fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION_ROTATE90));
static_assert(!fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION_ROTATE180));
static_assert(!fullscreen_copy_rotation_supported(DXGI_MODE_ROTATION_ROTATE270));
// Off-by-default adapter owned by one Source. Caller must serialize all calls
// with that Source's capture/publication lock. No activation or input injection.
// Only an explicitly reserved, already correctly sized output may be supplied.
class FullscreenWindowCapture {
    static constexpr const wchar_t* property=L"Viewflow.FullscreenCapture.Owner";
    HWND window_{};RECT original_{},backing_{};POINT delta_{};
    static constexpr const wchar_t* popup_property=L"Viewflow.FullscreenCapture.PopupRestore";
    struct PopupRestore {HWND window;POINT target;};
    std::vector<PopupRestore> restore_popups_;

    std::uint64_t generation_{};bool bound_{};
    std::int64_t capture_time_{},bind_completed_qpc_{};
    std::unique_ptr<DesktopCapture> capture_;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    struct Copy {
        std::shared_ptr<DesktopCapture::Frame> frame;
        unsigned slot{};
        std::uint64_t generation{};
    };
    struct Slot {
        Microsoft::WRL::ComPtr<ID3D11Query> done;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
        Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> view;
    };
    std::array<Slot,2> slots_;unsigned next_slot_{};
    std::optional<Copy> pending_;
    std::unique_ptr<SharedCapture> shared_pool_;
    Microsoft::WRL::ComPtr<ID3D12Device3> shared_device_;
    Microsoft::WRL::ComPtr<ID3D11Query> shared_error_done_;
    struct SharedPending {std::shared_ptr<DesktopCapture::Frame> frame;std::shared_ptr<SharedCapture::Snapshot> snapshot;};
    std::optional<SharedPending> shared_pending_;
    bool shared_attempted_{},shared_disabled_{};
    bool drain_shared(bool wait=false) noexcept {
        while(shared_pending_) {
            bool complete=FAILED(device_->GetDeviceRemovedReason());
            if(shared_pending_->snapshot)complete|=shared_pending_->snapshot->producer_complete();
            else if(!complete) {
                const auto hr=context_->GetData(shared_error_done_.Get(),nullptr,0,D3D11_ASYNC_GETDATA_DONOTFLUSH);
                complete=hr==S_OK;
                if(FAILED(hr)) {
                    Microsoft::WRL::ComPtr<ID3D11Query> replacement;D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT,0};
                    if(FAILED(device_->CreateQuery(&desc,&replacement)))return false;
                    context_->End(replacement.Get());context_->Flush();shared_error_done_=std::move(replacement);
                }
            }
            if(complete){shared_pending_.reset();return true;}
            if(!wait)return false;
            Sleep(1);
        }
        return true;
    }
    bool owns_window() const noexcept {return window_ && IsWindow(window_) && GetPropW(window_,property)==this;}
    static bool same(const RECT& a,const RECT& b) noexcept {return a.left==b.left&&a.top==b.top&&a.right==b.right&&a.bottom==b.bottom;}
    static RECT visible_bounds(HWND window) noexcept {
        RECT r{};if(FAILED(DwmGetWindowAttribute(window,DWMWA_EXTENDED_FRAME_BOUNDS,&r,sizeof(r))))GetWindowRect(window,&r);return r;
    }
    bool exclusive() const noexcept {
        if(!owns_window())return false;
        RECT actual=visible_bounds(window_);if(!same(actual,backing_)||!IsWindowVisible(window_)||IsIconic(window_))return false;
        // Fullscreen DD transmits the final opaque Windows desktop composition,
        // including its background. It does not preserve the window's WGC alpha.
        // Explicit layered/region windows keep the ordinary fusion path.
        const auto style=GetWindowLongPtrW(window_,GWL_EXSTYLE);
        if((style&(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOREDIRECTIONBITMAP)))return false;
        HRGN region=CreateRectRgn(0,0,0,0);if(!region)return false;
        const int region_kind=GetWindowRgn(window_,region);DeleteObject(region);
        if(region_kind!=ERROR)return false;
        // Z order is only relevant above the target; covered windows below it
        // do not contribute to the duplicated desktop. Owned popups anywhere
        // are handled separately so they are never baked and proxied twice.
        std::set<HWND> above;
        try {
            for(HWND candidate=GetWindow(window_,GW_HWNDPREV);candidate;candidate=GetWindow(candidate,GW_HWNDPREV))
                if(!above.insert(candidate).second)return false; // Topology changed during enumeration.
        }catch(...){return false;}
        struct Check {HWND target;RECT bounds;const std::set<HWND>& above;bool okay=true;} check{window_,backing_,above};
        EnumWindows([](HWND hwnd,LPARAM parameter)->BOOL {
            auto& c=*reinterpret_cast<Check*>(parameter);
            if(hwnd==c.target)return TRUE;
            if(!IsWindowVisible(hwnd)||IsIconic(hwnd))return TRUE;
            DWORD cloaked{};if(SUCCEEDED(DwmGetWindowAttribute(hwnd,DWMWA_CLOAKED,&cloaked,sizeof(cloaked)))&&cloaked)return TRUE;
            // Owned popups are separate fusion proxies, even when outside the
            // reserved output. Do not bake or strand them during a DD transition.
            if(GetAncestor(hwnd,GA_ROOTOWNER)==c.target){c.okay=false;return FALSE;}
            RECT rect{},intersection{};if(c.above.contains(hwnd) && GetWindowRect(hwnd,&rect)&&IntersectRect(&intersection,&rect,&c.bounds)){c.okay=false;return FALSE;}
            return TRUE;
        },reinterpret_cast<LPARAM>(&check));
        return check.okay;
    }
    // Device removal terminates pending GPU access; otherwise wait for actual
    // query completion. No frame-period timeout permits premature ReleaseFrame.
    bool drain(bool wait=false) noexcept {
        if(!drain_shared(wait))return false;
        if(!pending_)return true;
        // Submission already flushed once. Query failure is not completion:
        // put a replacement EVENT after the copy on the same immediate context.
        for(;;){
            auto& slot=slots_[pending_->slot];
            const HRESULT hr=context_->GetData(slot.done.Get(),nullptr,0,D3D11_ASYNC_GETDATA_DONOTFLUSH);
            if(hr==S_OK || FAILED(device_->GetDeviceRemovedReason())){pending_.reset();return true;}
            if(FAILED(hr)){
                Microsoft::WRL::ComPtr<ID3D11Query> replacement;
                D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT,0};
                if(FAILED(device_->CreateQuery(&desc,&replacement)))return false;
                context_->End(replacement.Get());context_->Flush();slot.done=std::move(replacement);
            }
            if(!wait)return false; // Retain the DD lease; render loop retries.
            Sleep(1);
        }
    }

public:
    enum class Status { ready,pending,window_fallback };
    FullscreenWindowCapture()=default;
    FullscreenWindowCapture(const FullscreenWindowCapture&)=delete;
    ~FullscreenWindowCapture(){
        while(!drain(true))Sleep(1); // Teardown cannot abandon an in-flight DD lease.
        if(!restore()){if(owns_window())RemovePropW(window_,property);for(auto& popup:restore_popups_)if(GetPropW(popup.window,popup_property)==this)RemovePropW(popup.window,popup_property);}
        // Runtime must explicitly retry failed restoration before destroying its
        // Source. Teardown still removes our property rather than leave a dangling pointer.
    }
    bool bound() const noexcept {return bound_;}
    ID3D12Device3* shared_device() const noexcept {return shared_device_.Get();}
    void enable_shared(ID3D12Device3* device) noexcept {
        if(shared_attempted_ || !bound_ || !device)return;
        shared_attempted_=true;
        try {
            auto pool=std::make_unique<SharedCapture>();
            HRESULT hr=pool->initialize(device_.Get(),context_.Get(),device,SharedCapture::Role::dd_source);
            D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT,0};
            if(SUCCEEDED(hr))hr=device_->CreateQuery(&desc,&shared_error_done_);
            if(SUCCEEDED(hr)){shared_pool_=std::move(pool);shared_device_=device;}
            std::fprintf(stderr,"reverse-fullscreen shared-pool enabled=%u hr=0x%08lx lazy=1\n",unsigned(SUCCEEDED(hr)),static_cast<unsigned long>(hr));
        }catch(...){shared_disabled_=true;}
    }
    std::int64_t capture_time_100ns() const noexcept {return capture_time_;}
    POINT presentation_delta() const noexcept {return delta_;}
    RECT presentation_rect(RECT rect) const noexcept {
        if(bound_){OffsetRect(&rect,-delta_.x,-delta_.y);}return rect;
    }
    POINT backing_point(POINT point) const noexcept {
        if(bound_){point.x+=delta_.x;point.y+=delta_.y;}return point;
    }
    // Runtime invokes only after paired IVSHMEM opt-in fullscreen mode 2.
    // The supplied monitor must be explicitly reserved by the runtime pool.
    HRESULT bind(HWND window,HMONITOR monitor,const OutputIdentity& identity,
                 ID3D11Device* device,ID3D11DeviceContext* context,ID3D12Device* device12,
                 unsigned width,unsigned height,std::uint64_t generation){
        if(bound_||window_||!window||!monitor||!device||!context||!device12||!generation||
           !width||!height||width>16384||height>16384)return E_INVALIDARG;
        MONITORINFOEXW mi{};mi.cbSize=sizeof(mi);
        if(!GetMonitorInfoW(monitor,&mi))return HRESULT_FROM_WIN32(GetLastError());
        if((mi.dwFlags&MONITORINFOF_PRIMARY)||unsigned(mi.rcMonitor.right-mi.rcMonitor.left)!=width||
           unsigned(mi.rcMonitor.bottom-mi.rcMonitor.top)!=height)return E_INVALIDARG;
        OutputIdentity current;HRESULT hr=query_output_identity(identity.source_adapter,mi.szDevice,current);
        if(FAILED(hr))return hr;if(current!=identity)return DXGI_ERROR_ACCESS_LOST;
        auto capture=std::make_unique<DesktopCapture>();
        hr=capture->initialize(device,device12,identity.source_adapter,mi.szDevice,&identity,DesktopCapture::FrameAccess::d11_only);if(FAILED(hr))return hr;
        // Establish actual DD capability before moving the requested window.
        std::shared_ptr<DesktopCapture::Frame> capability;
        const auto status=capture->acquire(capability,0);
        if(status!=DesktopCapture::Status::ready&&status!=DesktopCapture::Status::pending)return capture->last_error();
        capability.reset();
        const auto* output=capture->output_description();
        if(!output || !fullscreen_copy_rotation_supported(output->Rotation)) {
            std::fprintf(stderr,"reverse-fullscreen fallback=wgc reason=copy-only-DD-rotation-unsupported rotation=%u scope=this-window\n",output?unsigned(output->Rotation):0u);
            return DXGI_ERROR_UNSUPPORTED;
        }
        RECT original{};if(!GetWindowRect(window,&original))return HRESULT_FROM_WIN32(GetLastError());
        if(GetPropW(window,property))return HRESULT_FROM_WIN32(ERROR_BUSY);
        if(!SetPropW(window,property,this))return HRESULT_FROM_WIN32(GetLastError());
        window_=window;original_=original;backing_=mi.rcMonitor;generation_=generation;
        device_=device;context_=context;capture_=std::move(capture);
        const auto visible=visible_bounds(window);
        delta_={backing_.left-visible.left,backing_.top-visible.top};
        // Only HWNDs observed before migration have a proven original position.
        // New popups cause WGC fallback but are not moved by an intersection
        // guess: their application may have chosen absolute coordinates.
        struct Save {FullscreenWindowCapture* self;bool okay=true;} save{this};
        EnumWindows([](HWND hwnd,LPARAM arg)->BOOL{
            auto& saved=*reinterpret_cast<Save*>(arg);auto& self=*saved.self;
            if(hwnd==self.window_||GetAncestor(hwnd,GA_ROOTOWNER)!=self.window_)return TRUE;
            RECT r{};if(!GetWindowRect(hwnd,&r))return TRUE;
            if(GetPropW(hwnd,popup_property)){saved.okay=false;return FALSE;}
            try{self.restore_popups_.push_back({hwnd,{r.left,r.top}});}catch(...){saved.okay=false;return FALSE;}
            if(!SetPropW(hwnd,popup_property,&self)){self.restore_popups_.pop_back();saved.okay=false;return FALSE;}
            return TRUE;
        },reinterpret_cast<LPARAM>(&save));
        if(!save.okay){restore();return E_FAIL;}

        // Set bound before mutation so every failure attempts owned restoration.
        bound_=true;
        if(!SetWindowPos(window,nullptr,backing_.left-(visible.left-original.left),backing_.top-(visible.top-original.top),
            width+(original.right-original.left)-(visible.right-visible.left),height+(original.bottom-original.top)-(visible.bottom-visible.top),SWP_NOACTIVATE|SWP_NOZORDER)){
            hr=HRESULT_FROM_WIN32(GetLastError());restore();return hr;
        }
        if(!exclusive()){restore();return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;}
        LARGE_INTEGER boundary{};QueryPerformanceCounter(&boundary);bind_completed_qpc_=boundary.QuadPart;
        return S_OK;
    }
    Status poll(Microsoft::WRL::ComPtr<ID3D11Texture2D>& snapshot,Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>& view,std::uint64_t generation,std::shared_ptr<SharedCapture::Snapshot>* shared=nullptr){
        snapshot.Reset();view.Reset();if(shared)shared->reset();
        if(!bound_||generation!=generation_||!exclusive())return Status::window_fallback;
        if(!drain_shared())return Status::pending;
        if(pending_){
            const HRESULT hr=context_->GetData(slots_[pending_->slot].done.Get(),nullptr,0,D3D11_ASYNC_GETDATA_DONOTFLUSH);
            // S_FALSE alone does not establish a healthy device. Device removal
            // ends GPU access and must not strand a DD lease in perpetual pending.
            if(FAILED(device_->GetDeviceRemovedReason())){drain();return Status::window_fallback;}
            if(hr==S_FALSE)return Status::pending;
            if(FAILED(hr)){drain();return Status::window_fallback;}
            if(pending_->generation!=generation){pending_.reset();return Status::window_fallback;}
            LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);
            const auto stamp=pending_->frame->info.LastPresentTime.QuadPart;
            if(stamp>0 && frequency.QuadPart>0)capture_time_=stamp/frequency.QuadPart*10000000+(stamp%frequency.QuadPart)*10000000/frequency.QuadPart;
            snapshot=slots_[pending_->slot].texture;view=slots_[pending_->slot].view;pending_.reset();return Status::ready;
        }
        std::shared_ptr<DesktopCapture::Frame> frame;
        const auto status=capture_->acquire(frame,0);
        if(status==DesktopCapture::Status::pending||status==DesktopCapture::Status::busy)return Status::pending;
        if(status!=DesktopCapture::Status::ready)return Status::window_fallback;
        const auto* output=capture_->output_description();
        if(!output || !fullscreen_copy_rotation_supported(output->Rotation)) {
            std::fprintf(stderr,"reverse-fullscreen fallback=wgc reason=copy-only-DD-rotation-unsupported rotation=%u scope=this-window\n",output?unsigned(output->Rotation):0u);
            return Status::window_fallback; // No consumer commands use this lease.
        }
        // Pre-bind or pointer-only DD frames do not prove the relocated output
        // image. Retain the last snapshot until a newly composed image arrives.
        if(frame->info.LastPresentTime.QuadPart<=bind_completed_qpc_)return Status::pending;
        if(frame->description.Width!=unsigned(backing_.right-backing_.left)||frame->description.Height!=unsigned(backing_.bottom-backing_.top))return Status::window_fallback;
        if(shared && shared_pool_ && !shared_disabled_) {
            // Keep the borrowed DD acquisition before submitting any GPU work.
            shared_pending_.emplace(SharedPending{frame,{}});
            std::shared_ptr<SharedCapture::Snapshot> owned;
            const auto result=shared_pool_->capture(frame->texture11.Get(),owned);
            if(result==SharedCapture::Status::busy){shared_pending_.reset();return Status::pending;}
            if(result==SharedCapture::Status::ready) {
                shared_pending_->snapshot=owned;
                LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);
                const auto stamp=frame->info.LastPresentTime.QuadPart;
                capture_time_=stamp/frequency.QuadPart*10000000+(stamp%frequency.QuadPart)*10000000/frequency.QuadPart;
                snapshot=owned->owned11;view=owned->view11;*shared=std::move(owned);
                // Consumer queue waits on producer fence; no CPU completion wait.
                return Status::ready;
            }
            // Even failed Signal may follow a submitted copy. A preallocated
            // EVENT protects the DD lease while the ordinary route recovers.
            context_->End(shared_error_done_.Get());context_->Flush();shared_disabled_=true;
            std::fprintf(stderr,"reverse-fullscreen shared-pool fallback=ordinary-DD-copy hr=0x%08lx\n",static_cast<unsigned long>(shared_pool_->last_error()));
            return Status::pending;
        }
        // Both slots are reused only on the rendering thread. The caller must
        // enqueue its D11 immediate-context copy before the next poll; the
        // existing Transport.enqueue makes such an owned shared snapshot.
        // Direct asynchronous D12 consumption would instead require slot leases.
        const unsigned index=next_slot_;auto& slot=slots_[index];
        if(!slot.texture){
            auto desc=frame->description;desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;desc.MiscFlags=0;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
            Slot replacement;
            if(FAILED(device_->CreateTexture2D(&desc,nullptr,&replacement.texture)))return Status::window_fallback;
            if(FAILED(device_->CreateShaderResourceView(replacement.texture.Get(),nullptr,&replacement.view)))return Status::window_fallback;
            D3D11_QUERY_DESC q{D3D11_QUERY_EVENT,0};if(FAILED(device_->CreateQuery(&q,&replacement.done)))return Status::window_fallback;
            slot=std::move(replacement);
        }
        Copy copy;copy.frame=frame;copy.generation=generation;copy.slot=index;
        context_->CopyResource(slot.texture.Get(),frame->texture11.Get());context_->End(slot.done.Get());context_->Flush();
        next_slot_=(next_slot_+1)%slots_.size();
        pending_=std::move(copy);return Status::pending;
    }
    // False means restoration needs retry; reservation must remain held.
    bool restore() noexcept {
        if(!drain())return false;
        if(owns_window()){
            if(!SetWindowPos(window_,nullptr,original_.left,original_.top,original_.right-original_.left,
                original_.bottom-original_.top,SWP_NOACTIVATE|SWP_NOZORDER))return false;
            RECT actual{};if(!GetWindowRect(window_,&actual)||!same(actual,original_))return false;
            for(auto& popup:restore_popups_){
                if(!IsWindow(popup.window)||GetPropW(popup.window,popup_property)!=this)continue;
                RECT rect{};
                if(!GetWindowRect(popup.window,&rect))return false;
                if((rect.left!=popup.target.x||rect.top!=popup.target.y) &&
                   !SetWindowPos(popup.window,nullptr,popup.target.x,popup.target.y,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER))return false;
                if(!GetWindowRect(popup.window,&rect)||rect.left!=popup.target.x||rect.top!=popup.target.y)return false;
                RemovePropW(popup.window,popup_property);
            }
            RemovePropW(window_,property);
        }
        for(auto& popup:restore_popups_)if(GetPropW(popup.window,popup_property)==this)RemovePropW(popup.window,popup_property);
        restore_popups_.clear();
        slots_={};next_slot_=0;
        shared_pool_.reset();shared_device_.Reset();shared_error_done_.Reset();
        shared_attempted_=shared_disabled_=false;
        capture_.reset();window_=nullptr;bound_=false;delta_={};context_.Reset();device_.Reset();return true;
    }
};
}
