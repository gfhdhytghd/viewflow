from pathlib import Path
import shutil
base=Path('docs/evidence/performance-20260909-windows-linux');b=base/'quality';(b/'source').mkdir(parents=True,exist_ok=True);(b/'method').mkdir(exist_ok=True)
shutil.copytree(base/'source-profile/source/platform',b/'source/platform',dirs_exist_ok=True)
s=b/'source/platform/linux-reverse';t=(s/'record_probe.cpp').read_text();t=t.replace('#include <algorithm>','#include <algorithm>\n#include <set>\n#include <cmath>');t=t.replace('argc!=5','argc!=5 && argc!=6').replace('argc==5?','argc>=5?')
needle='            std::vector<std::uint8_t> last_alpha;';assert needle in t
t=t.replace(needle,'''            std::set<unsigned> selected;if(argc==6){std::ifstream list(argv[5]);unsigned n;while(list>>n)selected.insert(n);if(selected.empty())throw std::runtime_error("quality marker list empty");}
            const char* vs_source=R"(#version 300 es
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);})";
            const char* fs_source=R"(#version 300 es
precision highp float;precision highp int;
uniform sampler2D luma;uniform sampler2D chroma;uniform uint marker;out vec4 result;
vec3 reference(ivec2 p){if(p.y<128){uint bit=uint(p.x/128)%24u;uint v=(marker>>bit)&1u;if(p.y>=64)v=1u-v;return vec3(float(v));}vec3 c=vec3(float((uint(p.x/96)+marker/4u)%17u)/16.0,float((p.y/96)%13)/12.0,0.3);if(abs(p.x-int((marker*21u)%6144u))<24)c=vec3(1);return floor(c*255.0+0.5)/255.0;}
void main(){ivec2 base=ivec2(gl_FragCoord.xy)*16;vec3 total=vec3(0);float maximum=0.0;for(int y=0;y<16;y++)for(int x=0;x<16;x++){ivec2 q=base+ivec2(x,y);vec2 p=(vec2(q)+vec2(0.5))/vec2(6144,3456);float l=(texture(luma,p).r-16.0/255.0)*255.0/219.0;vec2 c=(texture(chroma,p).rg-vec2(128.0/255.0))*255.0/224.0;vec3 rgb=clamp(vec3(l+1.5748*c.y,l-0.187324*c.x-0.468124*c.y,l+1.8556*c.x),0.0,1.0);vec3 delta=rgb-reference(q);total+=delta*delta;maximum=max(maximum,max(abs(delta.r),max(abs(delta.g),abs(delta.b))));}result=vec4(total,maximum);})";
            const auto compile=[](GLenum type,const char* text){GLuint s=glCreateShader(type);glShaderSource(s,1,&text,nullptr);glCompileShader(s);GLint okay;glGetShaderiv(s,GL_COMPILE_STATUS,&okay);if(!okay){char error[2048];glGetShaderInfoLog(s,2048,nullptr,error);throw std::runtime_error(error);}return s;};
            GLuint program=glCreateProgram(),vs=compile(GL_VERTEX_SHADER,vs_source),fs=compile(GL_FRAGMENT_SHADER,fs_source);glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);GLint linked;glGetProgramiv(program,GL_LINK_STATUS,&linked);if(!linked)throw std::runtime_error("quality program link failed");glDeleteShader(vs);glDeleteShader(fs);
            GLuint quality_texture{},quality_fbo{};glGenTextures(1,&quality_texture);glBindTexture(GL_TEXTURE_2D,quality_texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA32F,384,216);glGenFramebuffers(1,&quality_fbo);glBindFramebuffer(GL_FRAMEBUFFER,quality_fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,quality_texture,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("quality float framebuffer incomplete");glBindFramebuffer(GL_FRAMEBUFFER,0);
            std::vector<float> sums(384*216*4);unsigned compared=0;
            std::vector<std::uint8_t> last_alpha;''')
needle='                    glBindFramebuffer(GL_FRAMEBUFFER,0);';assert needle in t
t=t.replace(needle,'''                    if(selected.contains(marker)){
                        glBindFramebuffer(GL_FRAMEBUFFER,quality_fbo);glViewport(0,0,384,216);glUseProgram(program);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,decoder.y_texture());glUniform1i(glGetUniformLocation(program,"luma"),0);glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,decoder.uv_texture());glUniform1i(glGetUniformLocation(program,"chroma"),1);glUniform1ui(glGetUniformLocation(program,"marker"),marker);glDrawArrays(GL_TRIANGLES,0,3);glReadPixels(0,0,384,216,GL_RGBA,GL_FLOAT,sums.data());if(glGetError())throw std::runtime_error("quality rendering GL error");double sum=0,peak=0;for(size_t i=0;i<sums.size();i+=4){sum+=sums[i]+sums[i+1]+sums[i+2];peak=std::max(peak,double(sums[i+3]));}const double mse=sum/(6144.0*3456.0*3.0);std::fprintf(stderr,"quality_frame marker=%u mse=%.12g psnr=%.9g max_error=%.9g\\n",marker,mse,-10*std::log10(std::max(mse,1e-20)),peak);++compared;
                    }
                    glBindFramebuffer(GL_FRAMEBUFFER,0);''')
t=t.replace('            glDeleteFramebuffers(1,&fbo);','''            if(compared!=selected.size())throw std::runtime_error("quality marker coverage mismatch");std::fprintf(stderr,"quality_complete frames=%u full_pixels_per_frame=21233664\\n",compared);glDeleteFramebuffers(1,&quality_fbo);glDeleteTextures(1,&quality_texture);glDeleteProgram(program);glDeleteFramebuffers(1,&fbo);''')
(s/'quality_probe.cpp').write_text(t);p=s/'CMakeLists.txt';p.write_text(p.read_text()+'''\nadd_executable(viewflow_reverse_quality_probe quality_probe.cpp)
target_link_libraries(viewflow_reverse_quality_probe PRIVATE viewflow_reverse_decoder)
''');shutil.copy2('/tmp/viewflow-prepare-reverse-quality.py',b/'method/prepare.py')
