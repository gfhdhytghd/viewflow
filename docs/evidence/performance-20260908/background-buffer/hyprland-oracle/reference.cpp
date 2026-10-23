#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <iostream>
#include <stdexcept>
constexpr int W=1024,H=1024;
std::string read(std::string p){std::ifstream f(p);if(!f)throw std::runtime_error(p);std::ostringstream s;s<<f.rdbuf();return s.str();}
GLuint shader(GLenum kind,std::string s){GLuint id=glCreateShader(kind);const char* p=s.c_str();glShaderSource(id,1,&p,nullptr);glCompileShader(id);GLint ok;glGetShaderiv(id,GL_COMPILE_STATUS,&ok);if(!ok){char m[8192];glGetShaderInfoLog(id,sizeof(m),nullptr,m);throw std::runtime_error(m);}return id;}
GLuint program(std::string body){const auto v=shader(GL_VERTEX_SHADER,"#version 300 es\nprecision highp float;out vec2 uv;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2.-1.,0,1);}");const auto f=shader(GL_FRAGMENT_SHADER,"#version 300 es\nprecision highp float;precision highp int;in vec2 uv;out vec4 frag;uniform sampler2D tex;\n"+body);auto p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);GLint ok;glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok)throw std::runtime_error("link");return p;}
int main(int n,char** a){try{
 if(n!=3)return 2;std::string src=a[1],out=a[2];
 auto getDisplay=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");auto d=getDisplay(EGL_PLATFORM_SURFACELESS_MESA,EGL_DEFAULT_DISPLAY,nullptr);EGLint major,minor;if(!eglInitialize(d,&major,&minor))throw std::runtime_error("eglInitialize");eglBindAPI(EGL_OPENGL_ES_API);
 const EGLint ca[]={EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};EGLConfig config;EGLint count;eglChooseConfig(d,ca,&config,1,&count);if(!count)throw std::runtime_error("eglConfig");const EGLint ctxa[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};auto ctx=eglCreateContext(d,config,EGL_NO_CONTEXT,ctxa);const EGLint sa[]={EGL_WIDTH,W,EGL_HEIGHT,H,EGL_NONE};auto surf=eglCreatePbufferSurface(d,config,sa);if(!eglMakeCurrent(d,surf,surf,ctx))throw std::runtime_error("eglMakeCurrent");
 std::cout<<"renderer="<<glGetString(GL_RENDERER)<<" version="<<glGetString(GL_VERSION)<<"\n";
 std::vector<unsigned char> pixels(W*H*4);for(int y=0;y<H;++y)for(int x=0;x<W;++x){auto p=&pixels[(y*W+x)*4];p[0]=(x/4+y/9)%256;p[1]=(x*3/8+y/3)%256;p[2]=((x/37+y/53)%2)?220:30;p[3]=255;}
 GLuint textures[3],fbs[2];glGenTextures(3,textures);for(int i=0;i<3;++i){glBindTexture(GL_TEXTURE_2D,textures[i]);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,W,H,0,GL_RGBA,GL_UNSIGNED_BYTE,i==0?pixels.data():nullptr);}glGenFramebuffers(2,fbs);for(int i=0;i<2;++i){glBindFramebuffer(GL_FRAMEBUFFER,fbs[i]);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,textures[i+1],0);glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);}
 const auto down=program(read(src+"/blur1.glsl")+"\nvoid main(){frag=blur1(uv,tex,5.0,vec2(1.0/1024.0),4,.1696,0.0);}");
 const auto up=program(read(src+"/blur2.glsl")+"\nvoid main(){frag=blur2(uv,tex,5.0,vec2(.25/1024.0));}");
 const auto prepare=program(read(src+"/gain.glsl")+"\nvoid main(){vec4 p=texture(tex,uv);p.rgb=gain(p.rgb,.8916);frag=p;}");
 const auto finish=program("void main(){frag=texture(tex,uv);}"); // noise disabled in both implementations for deterministic comparison
 GLuint vao;glGenVertexArrays(1,&vao);glBindVertexArray(vao);glViewport(0,0,W,H);glDisable(GL_BLEND);glEnable(GL_SCISSOR_TEST);
 unsigned current=0;auto pass=[&](GLuint p,int size){unsigned dest=current==1?2:1;glBindFramebuffer(GL_FRAMEBUFFER,fbs[dest-1]);glBindTexture(GL_TEXTURE_2D,textures[current]);glUseProgram(p);glUniform1i(glGetUniformLocation(p,"tex"),0);glScissor(0,0,size,size);glDrawArrays(GL_TRIANGLES,0,3);current=dest;};
 pass(prepare,W);for(int i=1;i<=4;++i)pass(down,W>>i);for(int i=3;i>=0;--i)pass(up,W>>i);pass(finish,W);
 glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());if(auto e=glGetError();e)throw std::runtime_error("glError "+std::to_string(e));
 std::ofstream f(out,std::ios::binary);f.write((char*)pixels.data(),pixels.size());std::cout<<"PASS source=installed-Hyprland-0.56.2 width=1024 height=1024 noise=0 hdr=0 rgba=1 input_injected=0\n";
 eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroySurface(d,surf);eglDestroyContext(d,ctx);eglTerminate(d);
 }catch(std::exception const& e){std::cerr<<e.what()<<"\n";return 1;}}
