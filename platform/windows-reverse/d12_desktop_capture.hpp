#pragma once
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <memory>
#include <string>
#include <cwchar>
#include <new>
#include <vector>
#include <optional>

namespace viewflow::reverse::d12 {
// Single-threaded direct Desktop Duplication source. Binding uses adapter LUID
// and output DeviceName, never an enumeration index after initialize().
struct OutputIdentity {
    LUID source_adapter{},target_adapter{};
    UINT32 source_id{},target_id{};
    std::wstring monitor_device_path;
    bool operator==(const OutputIdentity& other) const noexcept {
        return source_adapter.HighPart==other.source_adapter.HighPart && source_adapter.LowPart==other.source_adapter.LowPart &&
            target_adapter.HighPart==other.target_adapter.HighPart && target_adapter.LowPart==other.target_adapter.LowPart &&
            source_id==other.source_id && target_id==other.target_id && monitor_device_path==other.monitor_device_path;
    }
};
// Resolve exactly one active display path; cloned/ambiguous source names cannot
// establish a unique leased target. No display configuration is changed.
inline HRESULT query_output_identity(LUID adapter,const wchar_t* name,OutputIdentity& result) noexcept {
    if(!name || !*name)return E_INVALIDARG;
    try {
        for(unsigned retry=0;retry<4;++retry){
            UINT32 np{},nm{};LONG rc=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&np,&nm);
            if(rc!=ERROR_SUCCESS)return HRESULT_FROM_WIN32(rc);
            std::vector<DISPLAYCONFIG_PATH_INFO> paths(np);std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
            rc=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&np,paths.data(),&nm,modes.data(),nullptr);
            if(rc==ERROR_INSUFFICIENT_BUFFER)continue;
            if(rc!=ERROR_SUCCESS)return HRESULT_FROM_WIN32(rc);
            std::optional<OutputIdentity> found;
            for(UINT32 i=0;i<np;++i){const auto& path=paths[i];
                if(path.sourceInfo.adapterId.HighPart!=adapter.HighPart || path.sourceInfo.adapterId.LowPart!=adapter.LowPart)continue;
                DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};source.header.type=DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                source.header.size=sizeof(source);source.header.adapterId=path.sourceInfo.adapterId;source.header.id=path.sourceInfo.id;
                rc=DisplayConfigGetDeviceInfo(&source.header);if(rc!=ERROR_SUCCESS)return HRESULT_FROM_WIN32(rc);
                if(std::wcscmp(name,source.viewGdiDeviceName))continue;
                if(found)return HRESULT_FROM_WIN32(ERROR_DUP_NAME);
                DISPLAYCONFIG_TARGET_DEVICE_NAME target{};target.header.type=DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
                target.header.size=sizeof(target);target.header.adapterId=path.targetInfo.adapterId;target.header.id=path.targetInfo.id;
                rc=DisplayConfigGetDeviceInfo(&target.header);if(rc!=ERROR_SUCCESS)return HRESULT_FROM_WIN32(rc);
                if(!path.targetInfo.targetAvailable || !target.monitorDevicePath[0])return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;
                found=OutputIdentity{path.sourceInfo.adapterId,path.targetInfo.adapterId,path.sourceInfo.id,path.targetInfo.id,target.monitorDevicePath};
            }
            if(!found)return DXGI_ERROR_NOT_FOUND;
            result=std::move(*found);return S_OK;
        }
        return HRESULT_FROM_WIN32(ERROR_RETRY);
    }catch(const std::bad_alloc&){return E_OUTOFMEMORY;}
}
class DesktopCapture final {
public:
    enum class FrameAccess { direct_d12, d11_only };
private:
    struct State {
        FrameAccess access=FrameAccess::direct_d12;
        Microsoft::WRL::ComPtr<ID3D11Device> device11;
        Microsoft::WRL::ComPtr<ID3D12Device> device12;
        Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication;
        LUID adapter{};
        std::wstring output_name;
        std::optional<OutputIdentity> identity;
        HRESULT validate_identity() noexcept {
            if(!identity)return S_OK;
            OutputIdentity actual;const HRESULT hr=query_output_identity(adapter,output_name.c_str(),actual);
            if(FAILED(hr))return set(hr,"bound DisplayConfig identity unavailable");
            if(actual!=*identity)return set(DXGI_ERROR_ACCESS_LOST,"bound DisplayConfig identity changed");
            return S_OK;
        }
        DXGI_OUTPUT_DESC output{};
        bool held = false;
        HRESULT error = S_OK;
        const char* diagnostic = "not initialized";
        HRESULT set(HRESULT hr, const char* text) noexcept { error = hr; diagnostic = text; return hr; }
        HRESULT reopen() noexcept {
            const HRESULT identity_hr=validate_identity();if(FAILED(identity_hr))return identity_hr;
            Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
            HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
            if (FAILED(hr)) return set(hr, "CreateDXGIFactory1(recover)");
            for (UINT ai = 0;; ++ai) {
                Microsoft::WRL::ComPtr<IDXGIAdapter1> candidate;
                hr = factory->EnumAdapters1(ai, candidate.GetAddressOf());
                if (hr == DXGI_ERROR_NOT_FOUND) return set(hr, "bound adapter unavailable");
                if (FAILED(hr)) return set(hr, "EnumAdapters1(recover)");
                DXGI_ADAPTER_DESC1 desc{}; hr = candidate->GetDesc1(&desc);
                if (FAILED(hr)) return set(hr, "GetDesc1(recover)");
                if (desc.AdapterLuid.HighPart != adapter.HighPart || desc.AdapterLuid.LowPart != adapter.LowPart) continue;
                for (UINT oi = 0;; ++oi) {
                    Microsoft::WRL::ComPtr<IDXGIOutput> out;
                    hr = candidate->EnumOutputs(oi, out.GetAddressOf());
                    if (hr == DXGI_ERROR_NOT_FOUND) return set(hr, "bound output unavailable");
                    if (FAILED(hr)) return set(hr, "EnumOutputs(recover)");
                    DXGI_OUTPUT_DESC od{}; hr = out->GetDesc(&od);
                    if (FAILED(hr)) return set(hr, "Output GetDesc(recover)");
                    if (output_name != od.DeviceName) continue;
                    if (!od.AttachedToDesktop) return set(DXGI_ERROR_NOT_CURRENTLY_AVAILABLE, "bound output detached");
                    Microsoft::WRL::ComPtr<IDXGIOutput1> out1;
                    hr = out.As(&out1); if (FAILED(hr)) return set(hr, "IDXGIOutput1(recover)");
                    hr = out1->DuplicateOutput(device11.Get(), duplication.ReleaseAndGetAddressOf());
                    if (FAILED(hr)) return set(hr, "DuplicateOutput(recover)");
                    output = od;
                    return set(S_OK, "duplication ready");
                }
            }
        }
    };
    std::shared_ptr<State> state_;
public:
    enum class Status { ready, pending, busy, recovering, error };
    class Frame final {
        friend class DesktopCapture;
        std::shared_ptr<State> state_;
        Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication_;
        HANDLE handle_ = nullptr;
        bool held_ = false;
    public:
        Microsoft::WRL::ComPtr<ID3D11Texture2D> texture11;
        Microsoft::WRL::ComPtr<ID3D12Resource> texture12;
        DXGI_OUTDUPL_FRAME_INFO info{};
        D3D11_TEXTURE2D_DESC description{};
        Frame() = default;
        Frame(const Frame&) = delete;
        Frame& operator=(const Frame&) = delete;
        // Caller must retain this entire lease until ALL D3D11/D3D12 consumers
        // are drained. A raw/COM texture reference alone does not retain DD ownership.
        HRESULT release_after_gpu_completion() noexcept {
            if (!held_) return S_OK;
            texture12.Reset(); texture11.Reset();
            if (handle_) { CloseHandle(handle_); handle_ = nullptr; }
            held_ = false;
            HRESULT hr = duplication_->ReleaseFrame();
            state_->held = false;
            if (hr == DXGI_ERROR_ACCESS_LOST) state_->duplication.Reset();
            state_->set(hr, "ReleaseFrame");
            duplication_.Reset();
            return hr;
        }
        ~Frame() { release_after_gpu_completion(); }
    };
    DesktopCapture() = default;
    DesktopCapture(const DesktopCapture&) = delete;
    DesktopCapture& operator=(const DesktopCapture&) = delete;
    HRESULT last_error() const noexcept { return state_ ? state_->error : E_UNEXPECTED; }
    const char* diagnostic() const noexcept { return state_ ? state_->diagnostic : "not initialized"; }
    const DXGI_OUTPUT_DESC* output_description() const noexcept { return state_ ? &state_->output : nullptr; }
    HRESULT initialize(ID3D11Device* device11, ID3D12Device* device12, LUID adapter, const wchar_t* name, const OutputIdentity* identity=nullptr, FrameAccess access=FrameAccess::direct_d12) noexcept {
        if (state_ || !device11 || !device12 || !name || !*name) return E_INVALIDARG;
        Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
        Microsoft::WRL::ComPtr<IDXGIAdapter> actual;
        HRESULT hr = device11->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
        if (FAILED(hr)) return hr;
        hr = dxgi->GetAdapter(actual.GetAddressOf()); if (FAILED(hr)) return hr;
        DXGI_ADAPTER_DESC desc{}; hr = actual->GetDesc(&desc); if (FAILED(hr)) return hr;
        const LUID twelve = device12->GetAdapterLuid();
        if (desc.AdapterLuid.HighPart != adapter.HighPart || desc.AdapterLuid.LowPart != adapter.LowPart ||
            twelve.HighPart != adapter.HighPart || twelve.LowPart != adapter.LowPart) return E_INVALIDARG;
        try {
            state_ = std::make_shared<State>();
            state_->output_name = name;
            state_->access = access;
            if(identity)state_->identity=*identity;
        } catch (const std::bad_alloc&) { state_.reset(); return E_OUTOFMEMORY; }
        state_->device11 = device11; state_->device12 = device12; state_->adapter = adapter;
        hr=state_->validate_identity();if(FAILED(hr)){state_.reset();return hr;}
        return state_->set(S_OK, "bound; duplication opened on acquire");
    }
    Status acquire(std::shared_ptr<Frame>& frame, UINT timeout_ms = 0) noexcept {
        if (!state_ || frame) return Status::error;
        if (state_->held) { state_->set(S_FALSE, "frame lease still held"); return Status::busy; }
        HRESULT hr = state_->validate_identity();
        if(FAILED(hr)){state_->duplication.Reset();return Status::recovering;}
        hr = state_->device11->GetDeviceRemovedReason();
        if (FAILED(hr)) { state_->set(hr, "D3D11 device removed"); return Status::error; }
        hr = state_->device12->GetDeviceRemovedReason();
        if (FAILED(hr)) { state_->set(hr, "D3D12 device removed"); return Status::error; }
        if (!state_->duplication) {
            hr = state_->reopen();
            if (FAILED(hr)) return hr == DXGI_ERROR_NOT_FOUND || hr == DXGI_ERROR_NOT_CURRENTLY_AVAILABLE ||
                hr == DXGI_ERROR_ACCESS_LOST || hr == E_ACCESSDENIED ? Status::recovering : Status::error;
        }
        std::shared_ptr<Frame> next;
        try { next = std::make_shared<Frame>(); }
        catch (const std::bad_alloc&) { state_->set(E_OUTOFMEMORY, "frame lease allocation"); return Status::error; }
        next->state_ = state_; next->duplication_ = state_->duplication;
        Microsoft::WRL::ComPtr<IDXGIResource> raw;
        hr = state_->duplication->AcquireNextFrame(timeout_ms, &next->info, raw.GetAddressOf());
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) { state_->set(hr, "no new frame"); return Status::pending; }
        if (hr == DXGI_ERROR_ACCESS_LOST) { state_->duplication.Reset(); state_->set(hr, "access lost; retry bound output locally"); return Status::recovering; }
        if (FAILED(hr)) { state_->set(hr, "AcquireNextFrame"); return Status::error; }
        next->held_ = true; state_->held = true;
        hr=state_->validate_identity();
        if(FAILED(hr)){raw.Reset();next.reset();state_->duplication.Reset();state_->set(hr,"identity changed during AcquireNextFrame");return Status::recovering;}
        const char* stage = "QueryInterface(frame texture)";
        hr = raw.As(&next->texture11);
        if (SUCCEEDED(hr)) {
            next->texture11->GetDesc(&next->description);
            const auto& td = next->description;
            if (td.Format != DXGI_FORMAT_B8G8R8A8_UNORM || td.MipLevels != 1 || td.ArraySize != 1 || td.SampleDesc.Count != 1) {
                stage = "unsupported DD frame format"; hr = E_INVALIDARG;
            }
        }
        Microsoft::WRL::ComPtr<IDXGIResource1> share;
        // The owned-copy path only reads D11. Do not demand NT shareability of
        // the OS-owned DD texture or open a redundant D12 resource each frame.
        if(state_->access==FrameAccess::direct_d12) {
            if (SUCCEEDED(hr)) { stage = "QueryInterface(frame IDXGIResource1)"; hr = raw.As(&share); }
            if (SUCCEEDED(hr)) { stage = "CreateSharedHandle(actual DD frame)"; hr = share->CreateSharedHandle(nullptr,
                DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &next->handle_); }
            if (SUCCEEDED(hr)) { stage = "OpenSharedHandle(actual DD frame)"; hr = state_->device12->OpenSharedHandle(
                next->handle_, IID_PPV_ARGS(next->texture12.GetAddressOf())); }
        }
        if (FAILED(hr)) {
            // No consumer commands were submitted. Release safely, retaining the
            // import error even though the release itself updates state diagnostics.
            share.Reset(); raw.Reset(); next.reset(); state_->set(hr, stage); return Status::error;
        }
        frame = std::move(next); state_->set(S_OK, state_->access==FrameAccess::direct_d12?"direct DD frame leased":"D11-only DD frame leased"); return Status::ready;
    }
};
} // namespace viewflow::reverse::d12
