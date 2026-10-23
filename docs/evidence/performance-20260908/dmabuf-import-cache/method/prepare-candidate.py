from pathlib import Path
b=Path(__file__).resolve().parent.parent
p=Path('/home/wilf/.cache/viewflow-perf-import-cache-20260908/source/platform/nvenc-encoder/gpu_dmabuf_encoder.cu')
s=(b/'method/identity-only-gpu_dmabuf_encoder.cu').read_text()
needle='  std::shared_ptr<const std::vector<unsigned char>> lastAlpha;'
extra='''  // Cached registrations retain storage identity, never ownership of a live
  // producer read. Every use still waits its native fence, maps, unmaps, and
  // finishes the stream before returning the producer receipt.
  struct CachedImport {
    std::array<uint64_t, 8> key{};
    uint64_t used{};
    int fd = -1;
    GLuint texture{};
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    cudaGraphicsResource_t resource = nullptr;
  };
  std::array<CachedImport, 4> imports{};
  bool cacheImports = false;
  uint64_t importSerial{}, importHits{}, importMisses{}, importEvictions{};
  bool releaseImport(CachedImport& entry, std::string* error, bool deleteTexture = true) {
    const auto destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
    const bool ok = cleanupImportedImage(entry.resource != nullptr, false,
        entry.image != EGL_NO_IMAGE_KHR, [] { return true; },
        [&] { return cudaGraphicsUnregisterResource(entry.resource) == cudaSuccess; },
        [&] { return destroy && destroy(display, entry.image) == EGL_TRUE; }, error);
    if (entry.texture && deleteTexture) glDeleteTextures(1, &entry.texture);
    if (entry.fd >= 0) close(entry.fd);
    entry = {};
    return ok;
  }
'''
assert s.count(needle)==1;s=s.replace(needle,needle+'\n'+extra)
needle='      if (texture && ownCurrent)\n        glDeleteTextures(1, &texture);'
replace='''      // All retained entries were unmapped and synchronized before retention.
      // Release registrations/images before their GL context disappears.
      for (auto& entry : imports) releaseImport(entry, nullptr, ownCurrent);
      if (texture && ownCurrent)
        glDeleteTextures(1, &texture);'''
assert s.count(needle)==1;s=s.replace(needle,replace)
needle='    const char *timings = std::getenv("VIEWFLOW_GPU_TIMINGS");'
replace='''    const char* importCache = std::getenv("VIEWFLOW_GPU_IMPORT_CACHE");
    cacheImports = importCache && std::strcmp(importCache, "1") == 0;
'''+needle
assert s.count(needle)==1;s=s.replace(needle,replace)
a=s.index('  EGLImageKHR image = EGL_NO_IMAGE_KHR;',s.index('bool GpuDmabufEncoder::encode'))
z=s.index('  auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(',a)
s=s[:a]+'''  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  cudaGraphicsResource_t resource = nullptr;
  AVFrame *frame = nullptr;
  bool mapped = false, retainImport = false;
  Impl::CachedImport* cached = nullptr;
  GLuint importTexture = impl_->texture;
  bool cacheHit = false;
  ++impl_->importSerial;
  const auto destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
  auto cleanup = [&] {
    // Only the normal successful preparation path may retain a registration.
    // Every error/expiry path releases the entry; failed cleanup poisons the
    // encoder exactly as in the uncached import path.
    const bool keep = cached && retainImport && !mapped;
    const bool cleaned = cleanupImportedImage(resource != nullptr, mapped,
        !keep && image != EGL_NO_IMAGE_KHR,
        [&] { return cudaGraphicsUnmapResources(1, &resource, impl_->stream) == cudaSuccess; },
        [&] { return keep || cudaGraphicsUnregisterResource(resource) == cudaSuccess; },
        [&] { return destroyImage && destroyImage(impl_->display, image) == EGL_TRUE; }, error);
    if (cached && !keep) {
      if (cached->texture) glDeleteTextures(1, &cached->texture);
      if (cached->fd >= 0) close(cached->fd);
      *cached = {};
    }
    close(fd);
    av_frame_free(&frame);
    if (!cleaned) impl_->poisoned = true;
    return cleaned;
  };
  struct stat storage{};
  if (impl_->cacheImports && fstat(fd, &storage) == 0 && storage.st_ino != 0) {
    const std::array<uint64_t, 8> key{uint64_t(storage.st_dev), uint64_t(storage.st_ino),
        input.imageWidth, input.imageHeight, input.stride, input.offset, input.fourcc, input.modifier};
    for (auto& entry : impl_->imports) {
      if (entry.fd >= 0 && entry.key == key) { cached = &entry; break; }
    }
    cacheHit = cached != nullptr;
    if (cacheHit) {
      ++impl_->importHits;
      image = cached->image; resource = cached->resource; importTexture = cached->texture;
    } else {
      ++impl_->importMisses;
      for (auto& entry : impl_->imports) if (entry.fd < 0) { cached = &entry; break; }
      if (!cached) {
        cached = &*std::min_element(impl_->imports.begin(), impl_->imports.end(),
            [](const auto& a, const auto& b) { return a.used < b.used; });
        ++impl_->importEvictions;
        if (!impl_->releaseImport(*cached, error)) {
          impl_->poisoned = true; close(fd); return false;
        }
      }
      // Holding a duplicate prevents inode reuse while a cached key is alive.
      // Failure to reserve the optional cache falls back to an ordinary import.
      cached->fd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
      if (cached->fd < 0) cached = nullptr;
      else {
        cached->key = key;
        glGenTextures(1, &cached->texture);
        importTexture = cached->texture;
      }
    }
    if (cached) cached->used = impl_->importSerial;
  }
  if (!cacheHit) {
''' +s[z:]
a=s.index('  if (!cacheHit) {',a)
z=s.index('  timingExit.mark("cuda_register");',a)
part=s[a:z].replace('glBindTexture(GL_TEXTURE_2D, impl_->texture);','glBindTexture(GL_TEXTURE_2D, importTexture);').replace('cudaGraphicsGLRegisterImage(&resource, impl_->texture,','cudaGraphicsGLRegisterImage(&resource, importTexture,')
s=s[:a]+part+'''    if (cached) { cached->image = image; cached->resource = resource; }
  } else {
    timingExit.mark("egl_image");
    timingExit.mark("egl_bind");
    timingExit.mark("gl_finish");
  }
'''+s[z:]
needle='  if (!cleanup()) return false;\n  }\n  AVFrame* frame = nullptr;'
replace='''  retainImport = true;
  if (!cleanup()) return false;
  if (logTimings || impl_->importSerial == 1 || impl_->importSerial % 120 == 0) {
    const auto entries = std::count_if(impl_->imports.begin(), impl_->imports.end(),
        [](const auto& entry) { return entry.fd >= 0; });
    std::fprintf(stderr, "GPU import-cache frame=%llu enabled=%u hit=%u imports=%llu hits=%llu misses=%llu evictions=%llu entries=%zu capacity=4\\n",
        (unsigned long long)metadata.frameId, unsigned(impl_->cacheImports), unsigned(cacheHit),
        (unsigned long long)impl_->importSerial, (unsigned long long)impl_->importHits,
        (unsigned long long)impl_->importMisses, (unsigned long long)impl_->importEvictions, size_t(entries));
  }
  }
  AVFrame* frame = nullptr;'''
assert s.count(needle)==1;s=s.replace(needle,replace)
s=s.replace('// Every imported image has been retired before composition/submission.', '// Every imported image has been unmapped and its source reads completed\n  // before composition/submission; optional registrations only retain storage.')
p.write_text(s)
(b/'source').mkdir(exist_ok=True)
(b/'source/gpu_dmabuf_encoder.cu').write_text(s)
print('candidate created',p)
