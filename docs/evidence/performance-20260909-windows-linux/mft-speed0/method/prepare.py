from pathlib import Path
import shutil
base=Path('docs/evidence/performance-20260909-windows-linux');a=base/'mft-inspection';b=base/'mft-speed0';shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/hardware_encoder.cpp';t=p.read_text();needle='    if(s.codec){report_property(s.codec.Get(),"quality_vs_speed"';assert needle in t;t=t.replace(needle,'''    if(s.codec){VARIANT speed;VariantInit(&speed);speed.vt=VT_UI4;speed.ulVal=0;const auto hr=s.codec->SetValue(&CODECAPI_AVEncCommonQualityVsSpeed,&speed);std::fprintf(stderr,"encoder_set name=quality_vs_speed hr=%08lx\\n",static_cast<unsigned long>(hr));}
    if(s.codec){report_property(s.codec.Get(),"quality_vs_speed"''');p.write_text(t)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 t=(a/'method'/name).read_text().replace('reverse-mft-inspection-20260909','reverse-mft-speed0-20260909').replace('Reverse6KMftInspect-20260909','Reverse6KMftSpeed0-20260909');(b/'method'/name).write_text(t)
shutil.copy2('/tmp/viewflow-prepare-mft-speed.py',b/'method/prepare.py')
