#pragma once
#include <GLES3/gl3.h>
#include <array>
#include <stdexcept>
namespace viewflow::media {
// Render through the sampler (including channel swizzles), rather than reading
// the backing allocation and accidentally bypassing the presentation contract.
inline std::array<unsigned char,4> sampleTexture(GLuint input,float u,float v) {
    struct Objects {
        GLuint vertex{},fragment{},program{},texture{},framebuffer{},vao{};
        ~Objects() {
            glDeleteFramebuffers(1,&framebuffer);glDeleteTextures(1,&texture);glDeleteVertexArrays(1,&vao);
            if(program) glDeleteProgram(program);
            if(vertex) glDeleteShader(vertex);
            if(fragment) glDeleteShader(fragment);
        }
    } o;
    auto shader=[](GLenum type,const char* source) {
        GLuint id=glCreateShader(type);glShaderSource(id,1,&source,nullptr);glCompileShader(id);
        GLint okay{};glGetShaderiv(id,GL_COMPILE_STATUS,&okay);
        if(!okay) {glDeleteShader(id);throw std::runtime_error("probe sampler shader failed");}
        return id;
    };
    o.vertex=shader(GL_VERTEX_SHADER,"#version 300 es\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));gl_Position=vec4(p*2.-1.,0,1);}");
    o.fragment=shader(GL_FRAGMENT_SHADER,"#version 300 es\nprecision highp float;uniform sampler2D tex;uniform vec2 at;out vec4 color;void main(){color=texture(tex,at);}");
    o.program=glCreateProgram();glAttachShader(o.program,o.vertex);glAttachShader(o.program,o.fragment);glLinkProgram(o.program);
    GLint okay{};glGetProgramiv(o.program,GL_LINK_STATUS,&okay);if(!okay) throw std::runtime_error("probe sampler link failed");
    glGenTextures(1,&o.texture);glBindTexture(GL_TEXTURE_2D,o.texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,1,1);
    glGenFramebuffers(1,&o.framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,o.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,o.texture,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("probe sampler framebuffer failed");
    glGenVertexArrays(1,&o.vao);glBindVertexArray(o.vao);glViewport(0,0,1,1);
    glUseProgram(o.program);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,input);
    glUniform1i(glGetUniformLocation(o.program,"tex"),0);glUniform2f(glGetUniformLocation(o.program,"at"),u,v);
    glDrawArrays(GL_TRIANGLES,0,3);
    std::array<unsigned char,4> pixel{};glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel.data());
    if(glGetError()!=GL_NO_ERROR) throw std::runtime_error("probe texture sampling failed");
    return pixel;
}
}
