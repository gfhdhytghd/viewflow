#pragma once
// Frozen pre-integration per-patch binding algorithm for isolated comparisons.
// Keep independent of changes to the production stage/commit implementations.
struct ReferenceSparseGpuCandidate {
  CompositionDrawingSurface surface{nullptr};
  ContainerVisual root{nullptr};
  std::vector<SparseVisual> visuals;
  uint32_t width{},height{};
  bool reuse{};
};
ReferenceSparseGpuCandidate reference_stage_sparse_visuals(Foreground const& foreground,
    Compositor const& compositor, CompositionDrawingSurface const& surface,
    std::span<const viewflow::vfgp::AtlasPatch> patches, uint32_t tile_index,
    uint32_t width,uint32_t height,CompositionBrush const& backdrop) {
  const auto selected = viewflow::vfgp::PatchesForTile(patches, tile_index);
  ReferenceSparseGpuCandidate next;
  next.surface=surface; next.width=width; next.height=height;
  next.reuse=foreground.sparse_root && foreground.sparse_visuals.size()==selected.size();
  for(size_t i=0;next.reuse && i<selected.size();++i)
    next.reuse=foreground.sparse_visuals[i].patch==selected[i];
  if(next.reuse) return next;
  next.root=compositor.CreateContainerVisual();
  next.root.Size({float(width),float(height)});
  for(const auto& p:selected) {
    SparseVisual item;
    item.patch=p;
    item.brush=compositor.CreateSurfaceBrush(surface);
    item.brush.Stretch(CompositionStretch::None);
    item.brush.HorizontalAlignmentRatio(0.0f);
    item.brush.VerticalAlignmentRatio(0.0f);
    item.brush.Offset({-float(p.x),-float(p.y)});
    item.visual=compositor.CreateSpriteVisual();
    item.visual.Size({float(p.width),float(p.height)});
    item.visual.Offset({float(p.source_x),float(p.source_y),0.0f});
    item.visual.Brush(item.brush);
    if(backdrop) {
      item.mask=compositor.CreateMaskBrush();
      item.mask.Source(backdrop);
      item.mask.Mask(item.brush);
      item.backdrop=compositor.CreateSpriteVisual();
      item.backdrop.Size(item.visual.Size());
      item.backdrop.Offset(item.visual.Offset());
      item.backdrop.Brush(item.mask);
      next.root.Children().InsertAtTop(item.backdrop);
    }
    next.root.Children().InsertAtTop(item.visual);
    next.visuals.push_back(std::move(item));
  }
  return next;
}
void reference_commit_sparse_visuals(Foreground& foreground,ReferenceSparseGpuCandidate next,
                          float target_width,float target_height) {
  if(next.reuse) {
    for(auto& item:foreground.sparse_visuals) item.brush.Surface(next.surface);
  } else {
    foreground.visual.Children().RemoveAll();
    foreground.visual.Children().InsertAtTop(next.root);
    foreground.sparse_root=std::move(next.root);
    foreground.sparse_visuals=std::move(next.visuals);
  }
  foreground.sparse_root.Scale({target_width/float(next.width),target_height/float(next.height),1.0f});
  foreground.visual.Brush(nullptr);
  foreground.gpu_brush=nullptr; foreground.spare_brush=nullptr;
  foreground.surface=nullptr; foreground.spare_surface=nullptr;
  foreground.width=next.width; foreground.height=next.height;
}

