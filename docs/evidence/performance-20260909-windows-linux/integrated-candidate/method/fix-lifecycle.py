from pathlib import Path
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/integrated-candidate');p=b/'source/platform/windows-reverse/main.cpp';s=p.read_text()
s=s.replace('viewflow::windows_capture::CaptureGeometry geometry;', 'viewflow::windows_capture::CaptureGeometry geometry,requested_geometry;')
s=s.replace('Clock::time_point retry_at{};', 'Clock::time_point retry_at{},geometry_seen_at{};')
needle='            callbacks.on_frame=';assert s.count(needle)==1
s=s.replace(needle,'''            callbacks.on_geometry=[weak=std::weak_ptr<Source>(source)](const viewflow::windows_capture::CaptureGeometry& geometry){
                if(auto source=weak.lock()){
                    std::lock_guard lock(source->mutex);
                    if(source->requested_geometry.content_width!=geometry.content_width || source->requested_geometry.content_height!=geometry.content_height)source->geometry_seen_at=Clock::now();
                    source->requested_geometry=geometry;
                    std::fprintf(stderr,"profile_geometry id=%llu at=%lld epoch=%llu width=%u height=%u\\n",static_cast<unsigned long long>(source->id),qpc100ns(),static_cast<unsigned long long>(geometry.epoch),geometry.content_width,geometry.content_height);
                }
            };
'''+needle)
needle='''                bool retry;
                {std::lock_guard lock(existing->mutex);retry=existing->closed && Clock::now()>=existing->retry_at;}
                if(retry){std::fprintf(stderr,"reverse-capture-retry id=%llu hwnd=%p\\n",static_cast<unsigned long long>(existing->id),window);start_capture(existing);}''';assert needle in s
s=s.replace(needle,'''                bool retry,resize_pending;
                {
                    std::lock_guard lock(existing->mutex);const auto now=Clock::now();
                    resize_pending=existing->texture && existing->requested_geometry.content_width &&
                        (existing->geometry.content_width!=existing->requested_geometry.content_width || existing->geometry.content_height!=existing->requested_geometry.content_height) &&
                        now-existing->geometry_seen_at>=std::chrono::milliseconds(500);
                    retry=(existing->closed || resize_pending) && now>=existing->retry_at;
                }
                // A one-shot resize may produce only the discarded transition
                // frame. Restart this capture if no correctly sized frame follows;
                // retain its last texture/proxy while WGC acquires current pixels.
                if(retry){std::fprintf(stderr,"reverse-capture-retry id=%llu hwnd=%p resize_pending=%u\\n",static_cast<unsigned long long>(existing->id),window,unsigned(resize_pending));start_capture(existing);}''')
needle='''                    const auto rect=App::bounds(source->window);
                    GUITHREADINFO gui{};gui.cbSize=sizeof(gui);
                    const bool moving=GetGUIThreadInfo(GetWindowThreadProcessId(source->window,nullptr),&gui) &&''';assert needle in s
s=s.replace(needle,'''                    DWORD window_pid{};const auto window_thread=GetWindowThreadProcessId(source->window,&window_pid);
                    if(!window_thread || window_pid!=source->pid)continue;
                    const auto rect=App::bounds(source->window);
                    if(rect.right<=rect.left || rect.bottom<=rect.top)continue;
                    const auto frame_title=title(source->window);
                    // Destruction can race the inventory interval and the Win32
                    // metadata reads. Do not publish an invalid rectangle/title.
                    DWORD checked_pid{};if(GetWindowThreadProcessId(source->window,&checked_pid)!=window_thread || checked_pid!=source->pid)continue;
                    GUITHREADINFO gui{};gui.cbSize=sizeof(gui);
                    const bool moving=GetGUIThreadInfo(window_thread,&gui) &&''')
needle='row_x,row_y,title(source->window),';assert s.count(needle)==1;s=s.replace(needle,'row_x,row_y,frame_title,');p.write_text(s)
(b/'method/fix-lifecycle.py').write_text(Path(__file__).read_text())
