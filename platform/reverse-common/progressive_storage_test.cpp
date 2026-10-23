#include "progressive_storage.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <thread>
using namespace viewflow::reverse::shm;
struct Mapping {ProgressiveFrame header;std::array<std::uint8_t,4096> pixels{};};
int main(){
 auto mapping=std::make_shared<Mapping>();std::weak_ptr<Mapping> weak=mapping;
 auto producer=std::make_unique<ProgressiveStorage>(mapping->header,mapping->pixels,mapping);
 auto consumer=std::make_unique<ProgressiveStorage>(mapping->header,mapping->pixels,mapping);
 ProgressiveReference ref{7,1,4096,0,16,16};auto writer=producer->begin(ref);assert(writer);
 auto reader=consumer->acquire(writer->reference());assert(reader && reader->prefix().empty() && !reader->complete());
 std::array<std::uint8_t,80*8> source;source.fill(0xee);for(unsigned y=0;y<8;++y)for(unsigned x=0;x<64;++x)source[y*80+x]=std::uint8_t(y*3+x);
 writer->append(source,80,8);auto prefix=reader->prefix();assert(prefix.size()==512);
 for(unsigned y=0;y<8;++y)for(unsigned x=0;x<64;++x)assert(prefix[y*64+x]==source[y*80+x]);
 assert(!reader->complete());bool rejected=false;try{writer->append(std::span(source).first(40),80,8);}catch(...){rejected=true;}assert(rejected);assert(reader->prefix().size()==512);
 writer->append(source,80,8);assert(reader->prefix().size()==1024);assert(!reader->complete());writer->finish();assert(reader->complete());
 assert(!producer->begin({7,2,4096,0,16,16}));
 // A queued GPU upload can retain the read lease after both views disappear.
 writer.reset();producer.reset();consumer.reset();mapping.reset();assert(!weak.expired());
 assert(reader->prefix().size()==1024);reader.reset();assert(weak.expired());
 auto cancelled=std::make_shared<Mapping>();ProgressiveStorage storage(cancelled->header,cancelled->pixels,cancelled);
 auto partial=storage.begin(ref);auto held=storage.acquire(partial->reference());partial->append(source,80,8);partial.reset();
 assert(held->aborted() && held->prefix().empty() && !held->complete());assert(!storage.begin(ref));held.reset();
 auto next=storage.begin({7,2,4096,0,16,16});assert(next);assert(!storage.acquire(pack_progressive(ref)));next.reset();
 struct BigMapping {ProgressiveFrame header;std::vector<std::uint8_t> pixels;BigMapping():pixels(std::size_t(6144)*3456*4){}};
 for(unsigned mode=0;mode<3;++mode){
 auto big=std::make_shared<BigMapping>();
 auto workers=mode==2?std::make_shared<ParallelCopy>(2,true):std::shared_ptr<ParallelCopy>{};
 ProgressiveStorage output(big->header,big->pixels,big,mode!=0,workers),input(big->header,big->pixels,big);
 auto full=output.begin({9,1,big->pixels.size(),0,6144,3456});auto upload=input.acquire(full->reference());assert(upload);
 constexpr std::size_t row_bytes=6144*4,band_bytes=row_bytes*1728;
 std::thread copy([&]{std::vector<std::uint8_t> band(band_bytes);for(unsigned y=0;y<3456;y+=1728){
   const auto base=std::size_t(y)*row_bytes;
   for(std::size_t i=0;i<band.size();++i)band[i]=std::uint8_t(((base+i)>>12)^(base+i));
   full->append_chunked(band,row_bytes,1728,1024);
 }full->finish();});
 std::size_t checked=0;
 do {const auto committed=upload->prefix();for(;checked<committed.size();++checked)assert(committed[checked]==std::uint8_t((checked>>12)^checked));std::this_thread::yield();}while(!upload->complete());
 const auto all=upload->prefix();for(;checked<all.size();++checked)assert(all[checked]==std::uint8_t((checked>>12)^checked));
 copy.join();assert(checked==84934656);
 std::printf("chunked6K mode=%u bytes=%zu integrity=passed\n",mode,checked);
 }
 // Exercise the production chunk helper with padded rows and a short tail.
 for(unsigned chunk: {0u,1u,3u,1024u}){
  auto m=std::make_shared<Mapping>();ProgressiveStorage store(m->header,m->pixels,m);
  auto w=store.begin(ref);auto r=store.acquire(w->reference());
  bool invalid=false;try{w->append_chunked(std::span(source).first(source.size()-17),80,8,chunk);}catch(...){invalid=true;}
  assert(invalid && r->prefix().empty());
  w->append_chunked(source,80,8,chunk);
  auto saved=std::vector<std::uint8_t>(r->prefix().begin(),r->prefix().end());
  w->append_chunked(source,80,8,chunk);w->finish();
  assert(r->complete() && std::equal(saved.begin(),saved.end(),r->prefix().begin()));
  for(unsigned y=0;y<16;++y)for(unsigned x=0;x<64;++x)assert(r->prefix()[y*64+x]==source[(y%8)*80+x]);
 }
 std::puts("progressive storage: pitched bands, committed prefix, incomplete visibility, mapping leases, abort and6K concurrent full-byte integrity passed");
}
