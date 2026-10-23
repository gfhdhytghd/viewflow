from pathlib import Path
import shutil
base=Path('docs/evidence/performance-20260909-windows-linux');a=base/'async-alpha-reuse';b=base/'mft-inspection';shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/hardware_encoder.cpp';t=p.read_text().replace('#include <cstring>','#include <cstring>\n#include <dxgi.h>')
t=t.replace('struct HardwareEncoder::Impl {','''static long long encoder_clock(){LARGE_INTEGER t{},f{};QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return t.QuadPart/f.QuadPart*10000000+(t.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
static void report_property(ICodecAPI* codec,const char* name,const GUID& key){VARIANT value;VariantInit(&value);const auto hr=codec->GetValue(&key,&value);std::fprintf(stderr,"encoder_property name=%s hr=%08lx vt=%u value=%lu\\n",name,static_cast<unsigned long>(hr),value.vt,value.vt==VT_BOOL?static_cast<unsigned long>(value.boolVal!=VARIANT_FALSE):value.ulVal);VariantClear(&value);}
struct HardwareEncoder::Impl {''')
t=t.replace('if (type == METransformHaveOutput) ++output_ready;', '''if (type == METransformHaveOutput) ++output_ready;
            std::fprintf(stderr,"encoder_event type=%u at=%lld input_ready=%u output_ready=%u\\n",static_cast<unsigned>(type),encoder_clock(),input_ready,output_ready);''')
t=t.replace('s.device = device; device->GetImmediateContext(&s.context);','''s.device = device; device->GetImmediateContext(&s.context);
    ComPtr<IDXGIDevice> dxgi;VF_HR(device->QueryInterface(IID_PPV_ARGS(&dxgi)));ComPtr<IDXGIAdapter> adapter;VF_HR(dxgi->GetAdapter(&adapter));DXGI_ADAPTER_DESC adapter_desc{};VF_HR(adapter->GetDesc(&adapter_desc));
    std::fprintf(stderr,"encoder_adapter name=%ls vendor=%u device=%u dedicated=%llu shared=%llu luid_high=%ld luid_low=%lu\\n",adapter_desc.Description,adapter_desc.VendorId,adapter_desc.DeviceId,static_cast<unsigned long long>(adapter_desc.DedicatedVideoMemory),static_cast<unsigned long long>(adapter_desc.SharedSystemMemory),adapter_desc.AdapterLuid.HighPart,adapter_desc.AdapterLuid.LowPart);''')
t=t.replace('if (!s.encoder) activated = activations[i]->ActivateObject(IID_PPV_ARGS(&s.encoder));','''if (!s.encoder) {
            wchar_t* name{};UINT length{};activations[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute,&name,&length);GUID clsid{};activations[i]->GetGUID(MFT_TRANSFORM_CLSID_Attribute,&clsid);wchar_t id[64]{};StringFromGUID2(clsid,id,64);
            activated = activations[i]->ActivateObject(IID_PPV_ARGS(&s.encoder));
            std::fprintf(stderr,"encoder_activation index=%u count=%u name=%ls clsid=%ls hr=%08lx selected=%u\\n",i,count,name?name:L"unknown",id,static_cast<unsigned long>(activated),unsigned(bool(s.encoder)));CoTaskMemFree(name);
        }''')
t=t.replace('attrs->SetUINT32(MF_LOW_LATENCY, TRUE);','''const auto attr_low_hr=attrs->SetUINT32(MF_LOW_LATENCY, TRUE);UINT32 attr_low{};const auto attr_get_hr=attrs->GetUINT32(MF_LOW_LATENCY,&attr_low);
    std::fprintf(stderr,"encoder_attribute low_latency_set=%08lx get=%08lx value=%u\\n",static_cast<unsigned long>(attr_low_hr),static_cast<unsigned long>(attr_get_hr),attr_low);''')
for key,name in [('CODECAPI_AVLowLatencyMode','low_latency'),('CODECAPI_AVEncMPVDefaultBPictureCount','b_frames'),('CODECAPI_AVEncMPVGOPSize','gop')]:
 t=t.replace('s.codec->SetValue(&'+key+', &value);','''{const auto hr=s.codec->SetValue(&'''+key+''', &value);std::fprintf(stderr,"encoder_set name='''+name+''' hr=%08lx\\n",static_cast<unsigned long>(hr));report_property(s.codec.Get(),"'''+name+'",'+key+');}')
t=t.replace('    VF_HR(s.encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));','''    if(s.codec){report_property(s.codec.Get(),"quality_vs_speed",CODECAPI_AVEncCommonQualityVsSpeed);report_property(s.codec.Get(),"rate_control",CODECAPI_AVEncCommonRateControlMode);report_property(s.codec.Get(),"mean_bitrate",CODECAPI_AVEncCommonMeanBitRate);report_property(s.codec.Get(),"common_low_latency",CODECAPI_AVEncCommonLowLatency);}
    VF_HR(s.encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));''')
t=t.replace('const HRESULT result=s.encoder->ProcessInput(s.input_id, sample.Get(), 0);','''const auto input_begin=encoder_clock();const HRESULT result=s.encoder->ProcessInput(s.input_id, sample.Get(), 0);
    std::fprintf(stderr,"encoder_input pts=%lld begin=%lld end=%lld hr=%08lx input_ready=%u\\n",timestamp,input_begin,encoder_clock(),static_cast<unsigned long>(result),s.input_ready);''')
t=t.replace('DWORD status{}; const HRESULT result=s.encoder->ProcessOutput(0, 1, &output, &status);','''DWORD status{};const auto output_begin=encoder_clock(); const HRESULT result=s.encoder->ProcessOutput(0, 1, &output, &status);const auto output_end=encoder_clock();''')
t=t.replace('frames.push_back(std::move(frame));','''std::fprintf(stderr,"encoder_output pts=%lld begin=%lld end=%lld copied=%lld hr=%08lx\\n",frame.timestamp,output_begin,output_end,encoder_clock(),static_cast<unsigned long>(result));
        frames.push_back(std::move(frame));''');p.write_text(t)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 t=(a/'method'/name).read_text().replace('reverse-async-alpha-reuse-20260909','reverse-mft-inspection-20260909').replace('Reverse6KAsyncAlphaReuse-20260909','Reverse6KMftInspect-20260909');(b/'method'/name).write_text(t)
shutil.copy2('/tmp/viewflow-prepare-mft-inspection.py',b/'method/prepare.py')
