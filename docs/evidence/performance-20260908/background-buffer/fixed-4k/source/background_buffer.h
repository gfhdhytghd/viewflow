#pragma once
// Isolated fixed-geometry experiment. The 16x16 anchor must be covered by the
// fixture's opaque center. Production needs an opaque-anchor/fallback policy and
// geometry generations; this class deliberately is not wired into the receiver.
class BackgroundBuffer {
  using Surface=winrt::Windows::UI::Composition::CompositionDrawingSurface;
  enum Status { Free, Writing, Ready, Displayed, Retired };
  struct Slot { Surface surface{nullptr}; Status status=Free; };
  struct State {
    std::mutex mutex;
    std::array<Slot,3> slots;
    int ready=-1,displayed=-1;
    std::atomic<uint64_t> captures{},published{},taken{},busy{},ticks{},gpu_pending{};
    std::atomic<long> error{};
  };
  std::shared_ptr<State> state_=std::make_shared<State>();
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID2D1Device> d2d_;
  winrt::Windows::UI::Composition::CompositionGraphicsDevice graphics_{nullptr};
  winrt::Windows::UI::Composition::ContainerVisual parent_{nullptr};
  winrt::Windows::UI::Composition::SpriteVisual source_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession capture_{nullptr};
  winrt::com_ptr<ID3D11Query> query_;
  std::jthread worker_;
  UINT width_,height_,hz_;
 public:
  static constexpr float halo=128;
  struct Publication { Surface surface{nullptr}; int retired=-1; };
  BackgroundBuffer(Compositor const& c,ID3D11Device* foreground,UINT w,UINT h,UINT hz):width_(w+UINT(halo)*2),height_(h+UINT(halo)*2),hz_(hz) {
    using namespace winrt;using namespace winrt::Windows::Graphics;
    com_ptr<IDXGIDevice> fgdxgi;check_hresult(foreground->QueryInterface(fgdxgi.put()));com_ptr<IDXGIAdapter> adapter;check_hresult(fgdxgi->GetAdapter(adapter.put()));
    check_hresult(D3D11CreateDevice(adapter.get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,device_.put(),nullptr,context_.put()));
    auto dxgi=device_.as<IDXGIDevice>();check_hresult(D2D1CreateDevice(dxgi.get(),nullptr,d2d_.put()));
    auto interop=c.as<ABI::Windows::UI::Composition::ICompositorInterop>();
    check_hresult(interop->CreateGraphicsDevice(d2d_.get(),reinterpret_cast<ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(put_abi(graphics_))));
    for(auto& slot:state_->slots)slot.surface=graphics_.CreateDrawingSurface({float(width_),float(height_)},winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
    parent_=c.CreateContainerVisual();parent_.Size({float(w),float(h)});
    // Parent clipping is ignored by CreateFromVisual(child), while this tiny
    // covered area keeps the host-backdrop dependency live in DWM.
    parent_.Clip(c.CreateInsetClip(512,512,float(w)-528,float(h)-528));
    source_=c.CreateSpriteVisual();source_.Size({float(width_),float(height_)});source_.Offset({-halo,-halo,0});
    SparsePrototypeBlur effect;effect.sigma=12;effect.Source(CompositionEffectSourceParameter(L"background"));
    auto brush=c.CreateEffectFactory(effect).CreateBrush();brush.SetSourceParameter(L"background",c.CreateHostBackdropBrush());source_.Brush(brush);parent_.Children().InsertAtTop(source_);
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{nullptr};check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(winrt_device))));
    auto item=Capture::GraphicsCaptureItem::CreateFromVisual(source_);
    pool_=Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(winrt_device,winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,3,{int(width_),int(height_)});
    capture_=pool_.CreateCaptureSession(item);capture_.IsCursorCaptureEnabled(false);capture_.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan{10000000/hz_});
    D3D11_QUERY_DESC q{D3D11_QUERY_EVENT,0};check_hresult(device_->CreateQuery(&q,query_.put()));
  }
  ~BackgroundBuffer(){if(worker_.joinable()){worker_.request_stop();worker_.join();}try{if(capture_)capture_.Close();if(pool_)pool_.Close();}catch(...) {}}
  auto Parent()const{return parent_;}
  void Start(){capture_.StartCapture();worker_=std::jthread([this](std::stop_token stop){
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      int pending=-1;auto next=std::chrono::steady_clock::now();
      while(!stop.stop_requested()) {
        const auto now=std::chrono::steady_clock::now();
        if(now>=next){const auto tick=++state_->ticks;source_.Offset({-halo+float(tick%2)*0.01f,-halo,0});next=now+std::chrono::nanoseconds(1000000000/hz_);}
        if(pending>=0){
          BOOL done=FALSE;auto hr=context_->GetData(query_.get(),&done,sizeof(done),D3D11_ASYNC_GETDATA_DONOTFLUSH);winrt::check_hresult(hr);
          if(hr==S_OK&&done){std::lock_guard lock(state_->mutex);if(state_->ready>=0)state_->slots[state_->ready].status=Free;state_->slots[pending].status=Ready;state_->ready=pending;++state_->published;pending=-1;}
          else {++state_->gpu_pending;std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
        }
        auto frame=pool_.TryGetNextFrame();if(!frame){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}++state_->captures;
        int index=-1;{
          std::lock_guard lock(state_->mutex);for(int i=0;i<3;++i)if(state_->slots[i].status==Free){state_->slots[i].status=Writing;index=i;break;}
        }
        if(index<0){++state_->busy;frame.Close();continue;}
        auto access=frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();winrt::com_ptr<ID3D11Texture2D> texture;
        winrt::check_hresult(access->GetInterface(winrt::guid_of<ID3D11Texture2D>(),texture.put_void()));
        auto drawing=state_->slots[index].surface.as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
        winrt::com_ptr<ID3D11Texture2D> destination;POINT offset{};winrt::check_hresult(drawing->BeginDraw(nullptr,__uuidof(ID3D11Texture2D),destination.put_void(),&offset));
        D3D11_TEXTURE2D_DESC td{},dd{};texture->GetDesc(&td);destination->GetDesc(&dd);
        if(td.Width<width_||td.Height<height_||offset.x<0||offset.y<0||uint64_t(offset.x)+width_>dd.Width||uint64_t(offset.y)+height_>dd.Height){drawing->EndDraw();throw winrt::hresult_error(E_FAIL,L"background surface size mismatch");}
        D3D11_BOX box{0,0,0,width_,height_,1};context_->CopySubresourceRegion(destination.get(),0,UINT(offset.x),UINT(offset.y),0,texture.get(),0,&box);
        winrt::check_hresult(drawing->EndDraw());context_->End(query_.get());context_->Flush();frame.Close();pending=index;
      }
    }catch(winrt::hresult_error const& e){state_->error=e.code().value;}catch(...){state_->error=E_FAIL;}
  });}
  std::optional<Publication> Take(){
    std::unique_lock lock(state_->mutex,std::try_to_lock);if(!lock||state_->ready<0)return {};
    const auto index=state_->ready,old=state_->displayed;state_->ready=-1;state_->displayed=index;state_->slots[index].status=Displayed;
    if(old>=0)state_->slots[old].status=Retired;++state_->taken;return Publication{state_->slots[index].surface,old};
  }
  void RetireAfterCommit(Compositor const& c,int index){
    if(index<0)return;auto state=state_;c.RequestCommitAsync().Completed([state,index](auto const&,auto status){
      if(status!=winrt::Windows::Foundation::AsyncStatus::Completed)return;
      std::lock_guard lock(state->mutex);if(state->slots[index].status==Retired)state->slots[index].status=Free;
    });
  }
  void Report(FILE* log){std::fprintf(log,"background-cache hz=%u width=%u height=%u halo=128 captures=%llu published=%llu taken=%llu busy=%llu ticks=%llu gpu_pending_polls=%llu error=%08lx separate_device=1 input_injected=0\n",hz_,width_,height_,state_->captures.load(),state_->published.load(),state_->taken.load(),state_->busy.load(),state_->ticks.load(),state_->gpu_pending.load(),state_->error.load());}
};
