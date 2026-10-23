#pragma once
#include <deque>
#include <string>
#include <string_view>
namespace viewflow::windows_preview {
inline std::string_view desktop_field(std::string_view line,std::string_view key) {
  const auto begin=line.find(key);
  if(begin==std::string_view::npos)return {};
  const auto end=line.find(' ',begin);
  return line.substr(begin,end==std::string_view::npos?line.size()-begin:end-begin);
}
inline bool coalescible_desktop_update(std::string_view a,std::string_view b) {
  if(!a.starts_with("desktop-move-v1 ") || !b.starts_with("desktop-move-v1 ") ||
     desktop_field(a,"phase=")!="phase=update" || desktop_field(b,"phase=")!="phase=update")return false;
  for(const auto key:{"stream_hi=","stream_lo=","window_hi=","window_lo=","drag_id=","config_generation=","topology_generation="})
    if(desktop_field(a,key).empty() || desktop_field(a,key)!=desktop_field(b,key))return false;
  return true;
}
inline void queue_desktop_output(std::deque<std::string>& queue,std::string line) {
  if(!queue.empty() && coalescible_desktop_update(queue.back(),line))queue.back()=std::move(line);
  else queue.push_back(std::move(line));
}
}
