from pathlib import Path
p=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/alpha-summary/source/platform/windows-reverse/alpha_async_probe.cpp');s=p.read_text();s=s.replace('std::pair{64u,32u},std::pair{6144u,3456u}','std::pair{64u,32u},std::pair{67u,35u},std::pair{6144u,3456u}')
needle='''  }
 }
 return 0;''';assert s.count(needle)==1
replacement='''  }
  // Exercise every byte value, partial edge groups, and the one-pixel case
  // that must never be mistaken for a completely opaque frame.
  for(unsigned pattern=0;pattern<3;++pattern) {
   std::vector<std::uint8_t> rgba(std::size_t(w)*h*4,255);
   for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
    const auto a=pattern==0?std::uint8_t((x+17*y)%256):std::uint8_t(pattern==1 && x==w-1 && y==h-1?254:255);
    rgba[(std::size_t(y)*w+x)*4+3]=a;
   }
   ctx->UpdateSubresource(tex.Get(),0,nullptr,rgba.data(),w*4,0);
   const auto expected_tag=1000+pattern;if(alpha.enqueue(view.Get(),expected_tag)!=S_OK)throw std::runtime_error("pattern enqueue failed");
   const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);bool complete=false,opaque=false;std::int64_t tag=-1;std::vector<std::uint8_t> bytes;
   while(std::chrono::steady_clock::now()<deadline) {
    const auto result=alpha.poll(tag,bytes,&opaque);check(result);if(result==S_FALSE){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}complete=true;break;
   }
   if(!complete || tag!=expected_tag || opaque!=(pattern==2))throw std::runtime_error("pattern tag or opaque classification mismatch");
   if(opaque){if(!bytes.empty())throw std::runtime_error("opaque fast path returned full plane");}
   else {
    if(bytes.size()!=std::size_t(w)*h)throw std::runtime_error("pattern alpha size mismatch");
    for(std::size_t i=0;i<bytes.size();++i)if(bytes[i]!=rgba[i*4+3])throw std::runtime_error("pattern exact pixel mismatch");
   }
   std::fprintf(stderr,"alpha_summary_exact width=%u height=%u pattern=%u opaque=%u bytes=%zu\\n",w,h,pattern,unsigned(opaque),bytes.size());
  }
 }
 return 0;''';s=s.replace(needle,replacement);p.write_text(s)
b=p.parents[3];(b/'method/extend-alpha-probe.py').write_text(Path(__file__).read_text())
