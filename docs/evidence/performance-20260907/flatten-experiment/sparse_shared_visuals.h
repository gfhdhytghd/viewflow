#pragma once
#include <map>
#include <tuple>
// Shared atlas brush and per-proxy sparse visual cache.

struct SparsePrototypeBlur
    : implements<SparsePrototypeBlur, IGraphicsEffect, IGraphicsEffectSource,
                 ABI::Windows::Graphics::Effects::IGraphicsEffectD2D1Interop> {
  hstring Name() const { return L"ViewflowBlur"; }
  void Name(hstring const &) {}
  IGraphicsEffectSource src{nullptr};
  float sigma{};
  IGraphicsEffectSource Source() const { return src; }
  void Source(IGraphicsEffectSource const &v) { src = v; }
  HRESULT __stdcall GetEffectId(CLSID *id) noexcept final {
    if (!id)
      return E_POINTER;
    *id = CLSID_D2D1GaussianBlur;
    return S_OK;
  }
  HRESULT __stdcall GetNamedPropertyMapping(
      LPCWSTR p, UINT *i,
      ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING
          *m) noexcept final {
    if (!p || !i || !m || wcscmp(p, L"Sigma"))
      return E_INVALIDARG;
    *i = D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION;
    *m = ABI::Windows::Graphics::Effects::
        GRAPHICS_EFFECT_PROPERTY_MAPPING_DIRECT;
    return S_OK;
  }
  HRESULT __stdcall GetPropertyCount(UINT *n) noexcept final {
    if (!n)
      return E_POINTER;
    *n = 3;
    return S_OK;
  }
  HRESULT __stdcall
  GetProperty(UINT i,
              ABI::Windows::Foundation::IPropertyValue **v) noexcept final {
    if (!v || i > D2D1_GAUSSIANBLUR_PROP_BORDER_MODE)
      return E_INVALIDARG;
    *v = nullptr;
    try {
      IPropertyValue value{nullptr};
      if (i == D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION)
        value = box_value(sigma).as<IPropertyValue>();
      else if (i == D2D1_GAUSSIANBLUR_PROP_OPTIMIZATION)
        value = box_value(uint32_t(D2D1_GAUSSIANBLUR_OPTIMIZATION_BALANCED))
                    .as<IPropertyValue>();
      else
        value = box_value(uint32_t(D2D1_BORDER_MODE_HARD)).as<IPropertyValue>();
      *v = static_cast<ABI::Windows::Foundation::IPropertyValue *>(
          get_abi(value));
      (*v)->AddRef();
      return S_OK;
    } catch (...) {
      return to_hresult();
    }
  }
  HRESULT __stdcall GetSourceCount(UINT *n) noexcept final {
    if (!n)
      return E_POINTER;
    *n = 1;
    return S_OK;
  }
  HRESULT __stdcall
  GetSource(UINT i, ABI::Windows::Graphics::Effects::IGraphicsEffectSource *
                        *v) noexcept final {
    if (!v || i)
      return E_INVALIDARG;
    *v = nullptr;
    if (src) {
      *v =
          static_cast<ABI::Windows::Graphics::Effects::IGraphicsEffectSource *>(
              get_abi(src));
      (*v)->AddRef();
    }
    return S_OK;
  }
};
struct SparseMaskTransform : implements<SparseMaskTransform, IGraphicsEffect,
    IGraphicsEffectSource, ABI::Windows::Graphics::Effects::IGraphicsEffectD2D1Interop> {
  IGraphicsEffectSource source{nullptr};
  std::array<float,6> matrix{1,0,0,1,0,0};
  hstring Name() const {return L"SparseMaskTransform";}
  void Name(hstring const&) {}
  HRESULT __stdcall GetEffectId(CLSID* id) noexcept final {
    if(!id)return E_POINTER;*id=CLSID_D2D12DAffineTransform;return S_OK;
  }
  HRESULT __stdcall GetNamedPropertyMapping(LPCWSTR name,UINT* index,
      ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING* mapping) noexcept final {
    if(!name || !index || !mapping || wcscmp(name,L"TransformMatrix"))return E_INVALIDARG;
    *index=D2D1_2DAFFINETRANSFORM_PROP_TRANSFORM_MATRIX;
    *mapping=ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING_DIRECT;
    return S_OK;
  }
  HRESULT __stdcall GetPropertyCount(UINT* count) noexcept final {
    if(!count)return E_POINTER;*count=4;return S_OK;
  }
  HRESULT __stdcall GetProperty(UINT index,ABI::Windows::Foundation::IPropertyValue** result) noexcept final {
    if(!result || index>3)return E_INVALIDARG;*result=nullptr;
    try {
      IPropertyValue value{nullptr};
      switch(index) {
        case D2D1_2DAFFINETRANSFORM_PROP_INTERPOLATION_MODE:
          value=box_value(uint32_t(D2D1_2DAFFINETRANSFORM_INTERPOLATION_MODE_LINEAR)).as<IPropertyValue>();break;
        case D2D1_2DAFFINETRANSFORM_PROP_BORDER_MODE:
          value=box_value(uint32_t(D2D1_BORDER_MODE_SOFT)).as<IPropertyValue>();break;
        case D2D1_2DAFFINETRANSFORM_PROP_TRANSFORM_MATRIX:
          value=PropertyValue::CreateSingleArray(matrix).as<IPropertyValue>();break;
        default:value=box_value(1.0f).as<IPropertyValue>();break;
      }
      *result=static_cast<ABI::Windows::Foundation::IPropertyValue*>(get_abi(value));
      (*result)->AddRef();return S_OK;
    } catch(...) {return to_hresult();}
  }
  HRESULT __stdcall GetSourceCount(UINT* count) noexcept final {
    if(!count)return E_POINTER;*count=1;return S_OK;
  }
  HRESULT __stdcall GetSource(UINT index,ABI::Windows::Graphics::Effects::IGraphicsEffectSource** result) noexcept final {
    if(!result || index)return E_INVALIDARG;*result=nullptr;
    if(source){*result=static_cast<ABI::Windows::Graphics::Effects::IGraphicsEffectSource*>(get_abi(source));(*result)->AddRef();}
    return S_OK;
  }
};

struct SparseBackdropComposite : implements<SparseBackdropComposite, IGraphicsEffect,
    IGraphicsEffectSource, ABI::Windows::Graphics::Effects::IGraphicsEffectD2D1Interop> {
  std::array<IGraphicsEffectSource,2> sources{nullptr,nullptr};
  hstring Name() const {return L"SparseBackdropComposite";}
  void Name(hstring const&) {}
  HRESULT __stdcall GetEffectId(CLSID* id) noexcept final {if(!id)return E_POINTER;*id=CLSID_D2D1Composite;return S_OK;}
  HRESULT __stdcall GetNamedPropertyMapping(LPCWSTR,UINT*,ABI::Windows::Graphics::Effects::GRAPHICS_EFFECT_PROPERTY_MAPPING*) noexcept final {return E_INVALIDARG;}
  HRESULT __stdcall GetPropertyCount(UINT* count) noexcept final {if(!count)return E_POINTER;*count=1;return S_OK;}
  HRESULT __stdcall GetProperty(UINT index,ABI::Windows::Foundation::IPropertyValue** result) noexcept final {
    if(!result || index)return E_INVALIDARG;*result=nullptr;
    try {auto value=box_value(uint32_t(D2D1_COMPOSITE_MODE_SOURCE_IN)).as<IPropertyValue>();
      *result=static_cast<ABI::Windows::Foundation::IPropertyValue*>(get_abi(value));(*result)->AddRef();return S_OK;
    } catch(...) {return to_hresult();}
  }
  HRESULT __stdcall GetSourceCount(UINT* count) noexcept final {if(!count)return E_POINTER;*count=2;return S_OK;}
  HRESULT __stdcall GetSource(UINT index,ABI::Windows::Graphics::Effects::IGraphicsEffectSource** result) noexcept final {
    if(!result || index>=2)return E_INVALIDARG;*result=nullptr;
    if(sources[index]){*result=static_cast<ABI::Windows::Graphics::Effects::IGraphicsEffectSource*>(get_abi(sources[index]));(*result)->AddRef();}return S_OK;
  }
};
struct SharedSparseScene {
  using Key = std::tuple<uint32_t,uint32_t,uint32_t,uint32_t>;
  struct Node {
    SpriteVisual background{nullptr}; Visual clip{nullptr};
    InsetClip crop{nullptr};
    SpriteVisual pixels{nullptr}; CompositionEffectBrush masked{nullptr};
    uint32_t atlas_x{},atlas_y{};
  };
  bool flatten_foreground=true;
  ContainerVisual root{nullptr};
  CompositionSurfaceBrush brush{nullptr};
  Compositor compositor{nullptr};
  CompositionBrush backdrop{nullptr};
  CompositionEffectFactory masked_factory{nullptr};
  winrt::Windows::Foundation::Size atlas_size{};
  std::map<Key,Node> nodes;
  std::vector<Key> order;
};
struct SharedSparsePlan {
  CompositionDrawingSurface surface{nullptr};
  winrt::Windows::Foundation::Size size{};
  std::map<SharedSparseScene::Key,SharedSparseScene::Node> nodes;
  std::vector<SharedSparseScene::Key> order;
  size_t created{},retargeted{};
  bool reattach{};
};
// Plans belong to this scene and are committed serially by the presenter.
// Destruction of an uncommitted plan leaves the visible tree untouched.
inline SharedSparsePlan stage_shared_sparse_visuals(SharedSparseScene const& scene,
    CompositionDrawingSurface const& surface,
    std::span<const viewflow::vfgp::AtlasPatch> patches) {
  auto const& compositor=scene.compositor;
  const auto size=surface.Size();
  const bool same_size=size.Width==scene.atlas_size.Width && size.Height==scene.atlas_size.Height;
  SharedSparsePlan plan;plan.surface=surface;plan.size=size;
  auto& next=plan.nodes;auto& order=plan.order;auto& created=plan.created;
  for(const auto& patch:patches) {
    SharedSparseScene::Key key{patch.source_x,patch.source_y,patch.width,patch.height};
    if(next.contains(key))throw std::runtime_error("duplicate sparse source rectangle");
    order.push_back(key);
    auto old=scene.nodes.find(key);
    if(old!=scene.nodes.end()) {
      auto node=old->second;
      if(!same_size || node.atlas_x!=patch.x || node.atlas_y!=patch.y)++plan.retargeted;
      // Only candidate metadata changes here; visual properties wait for commit.
      node.atlas_x=patch.x;node.atlas_y=patch.y;
      next.emplace(key,std::move(node));continue;
    }
    SharedSparseScene::Node node;node.atlas_x=patch.x;node.atlas_y=patch.y;
    node.pixels=compositor.CreateSpriteVisual();
    auto const& pixels=node.pixels;
    pixels.Size({size.Width,size.Height});
    pixels.Brush(scene.brush);
    if(scene.flatten_foreground) {
      node.crop=compositor.CreateInsetClip(0,0,size.Width-float(patch.width),size.Height-float(patch.height));
      node.crop.Offset({float(patch.x),float(patch.y)});
      pixels.Clip(node.crop);
      pixels.Offset({float(patch.source_x)-float(patch.x),float(patch.source_y)-float(patch.y),0});
      node.clip=pixels;
    } else {
      auto container=compositor.CreateContainerVisual();
      container.Size({float(patch.width),float(patch.height)});
      container.Offset({float(patch.source_x),float(patch.source_y),0.0f});
      container.Clip(compositor.CreateInsetClip());
      pixels.Offset({-float(patch.x),-float(patch.y),0.0f});
      container.Children().InsertAtTop(pixels);node.clip=container;
    }
    if(scene.backdrop) {
      node.masked=scene.masked_factory.CreateBrush();
      auto const& masked=node.masked;
      masked.Properties().InsertMatrix3x2(L"SparseMaskTransform.TransformMatrix",
          {1,0,0,1,-float(patch.x),-float(patch.y)});
      masked.SetSourceParameter(L"atlas",scene.brush);
      masked.SetSourceParameter(L"backdrop",scene.backdrop);
      node.background=compositor.CreateSpriteVisual();
      node.background.Size({float(patch.width),float(patch.height)});
      node.background.Offset({float(patch.source_x),float(patch.source_y),0.0f});
      node.background.Brush(masked);
    }
    next.emplace(key,std::move(node));++created;
  }
  // Stage allocations before touching the live tree. Keep surviving nodes in place
  // when their relative order is unchanged; arbitrary reordering reattaches them.
  std::vector<SharedSparseScene::Key> old_survivors,new_survivors;
  {
    for(auto const& key:scene.order)if(next.contains(key))old_survivors.push_back(key);
    for(auto const& key:order)if(scene.nodes.contains(key))new_survivors.push_back(key);
  }
  plan.reattach=old_survivors!=new_survivors;
  return plan;
}
inline void commit_shared_sparse_visuals(SharedSparseScene& scene,SharedSparsePlan plan) {
  auto& next=plan.nodes;auto& order=plan.order;
  const bool reattach=plan.reattach;
  auto children=scene.root.Children();
  if(reattach)children.RemoveAll();
  else for(auto const& [key,node]:scene.nodes)if(!next.contains(key)) {
    if(node.background)children.Remove(node.background);
    children.Remove(node.clip);
  }
  Visual previous{nullptr};
  for(auto const& key:order) {
    auto const& node=next.at(key);
    if(auto old=scene.nodes.find(key);old!=scene.nodes.end()) {
      if(plan.size.Width!=scene.atlas_size.Width || plan.size.Height!=scene.atlas_size.Height) {
        node.pixels.Size({plan.size.Width,plan.size.Height});
        if(node.crop) {
          node.crop.RightInset(plan.size.Width-float(std::get<2>(key)));
          node.crop.BottomInset(plan.size.Height-float(std::get<3>(key)));
        }
      }
      if(node.atlas_x!=old->second.atlas_x || node.atlas_y!=old->second.atlas_y) {
        if(node.crop) {
          node.pixels.Offset({float(std::get<0>(key))-float(node.atlas_x),float(std::get<1>(key))-float(node.atlas_y),0});
          node.crop.Offset({float(node.atlas_x),float(node.atlas_y)});
        } else node.pixels.Offset({-float(node.atlas_x),-float(node.atlas_y),0});
        if(node.masked)node.masked.Properties().InsertMatrix3x2(L"SparseMaskTransform.TransformMatrix",
            {1,0,0,1,-float(node.atlas_x),-float(node.atlas_y)});
      }
    }
    if(reattach || !scene.nodes.contains(key)) {
      if(node.background) {
        if(previous)children.InsertAbove(node.background,previous);else children.InsertAtBottom(node.background);
        children.InsertAbove(node.clip,node.background);
      } else if(previous)children.InsertAbove(node.clip,previous);else children.InsertAtBottom(node.clip);
    }
    previous=node.clip;
  }
  scene.brush.Surface(plan.surface);scene.atlas_size=plan.size;
  scene.nodes=std::move(next);scene.order=std::move(order);
}
inline size_t update_shared_sparse_visuals(SharedSparseScene& scene,
    CompositionDrawingSurface const& surface,
    std::span<const viewflow::vfgp::AtlasPatch> patches) {
  auto plan=stage_shared_sparse_visuals(scene,surface,patches);
  const auto created=plan.created;
  commit_shared_sparse_visuals(scene,std::move(plan));
  return created;
}
inline SharedSparseScene make_shared_sparse_scene(
    Compositor const& compositor, CompositionDrawingSurface const& surface,
    std::span<const viewflow::vfgp::AtlasPatch> patches,
    CompositionBrush const& backdrop = nullptr, float blur_sigma = 0,
    bool flatten_foreground = true) {
  SharedSparseScene scene;
  scene.compositor=compositor;scene.backdrop=backdrop;scene.flatten_foreground=flatten_foreground;
  scene.root=compositor.CreateContainerVisual();
  scene.brush=compositor.CreateSurfaceBrush(surface);
  scene.brush.Stretch(CompositionStretch::None);
  scene.brush.HorizontalAlignmentRatio(0.0f);
  scene.brush.VerticalAlignmentRatio(0.0f);
  if(backdrop) {
      auto transform=make_self<SparseMaskTransform>();
      transform->source=CompositionEffectSourceParameter(L"atlas");
      auto composite=make_self<SparseBackdropComposite>();
      composite->sources[0]=transform.as<IGraphicsEffectSource>();
      if(blur_sigma>0) {
        auto blur=make_self<SparsePrototypeBlur>();blur->sigma=blur_sigma;blur->Source(CompositionEffectSourceParameter(L"backdrop"));
        composite->sources[1]=blur.as<IGraphicsEffectSource>();
      } else composite->sources[1]=CompositionEffectSourceParameter(L"backdrop");
      scene.masked_factory=compositor.CreateEffectFactory(composite.as<IGraphicsEffect>(),
          {L"SparseMaskTransform.TransformMatrix"});
  }
  update_shared_sparse_visuals(scene,surface,patches);
  return scene;
}
