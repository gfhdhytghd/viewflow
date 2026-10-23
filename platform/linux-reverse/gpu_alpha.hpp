#pragma once
#include <GLES3/gl3.h>
#include <algorithm>
#include <cstdint>
#include <span>
#include <optional>
#include <memory>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewflow::reverse {
// Packs four source alpha bytes into one RGBA8 pixel, then downloads only the
// alpha plane. Caller owns a current GLES3 context and rebinds render state.
// The final partial row is read through scratch storage, never beyond target.
class GpuAlphaAsync;
class GpuAlpha {
    friend class GpuAlphaAsync;
    GLuint program_{},texture_{},previous_{},framebuffer_{},query_{};bool previous_valid_{};
    unsigned width_{},height_{},source_width_{},source_height_{};
    std::vector<std::uint8_t> tail_;
    static GLuint shader(GLenum kind,const char* text) {
        const auto s=glCreateShader(kind);glShaderSource(s,1,&text,nullptr);glCompileShader(s);
        GLint ok{};glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
        if(!ok){glDeleteShader(s);throw std::runtime_error("GPU alpha shader compile");}
        return s;
    }
    void initialize() {
        if(program_)return;
        static constexpr auto vertex=R"(#version 300 es
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);})";
        static constexpr auto fragment=R"(#version 300 es
precision highp float;precision highp int;
uniform highp sampler2D source;uniform highp sampler2D previous;uniform bool compare_previous;uniform int source_width;uniform int source_count;uniform int packed_width;
out vec4 color;
float alpha_at(int i){if(i>=source_count)return 0.0;return texelFetch(source,ivec2(i%source_width,i/source_width),0).a;}
void main(){int i=(int(gl_FragCoord.y)*packed_width+int(gl_FragCoord.x))*4;color=vec4(alpha_at(i),alpha_at(i+1),alpha_at(i+2),alpha_at(i+3));if(compare_previous && all(equal(color,texelFetch(previous,ivec2(gl_FragCoord.xy),0))))discard;})";
        const auto vs=shader(GL_VERTEX_SHADER,vertex);
        GLuint fs{};try {fs=shader(GL_FRAGMENT_SHADER,fragment);}catch(...){glDeleteShader(vs);throw;}
        program_=glCreateProgram();glAttachShader(program_,vs);glAttachShader(program_,fs);glLinkProgram(program_);
        glDeleteShader(vs);glDeleteShader(fs);
        GLint ok{};glGetProgramiv(program_,GL_LINK_STATUS,&ok);
        if(!ok){reset();throw std::runtime_error("GPU alpha program link");}
    }
    void begin(GLuint source,unsigned width,unsigned height,std::size_t size,bool skip_unchanged) {
        if(!source || !width || !height || width>16384 || height>16384 || size!=std::size_t(width)*height)throw std::runtime_error("GPU alpha extent");
        initialize();
        const unsigned packed_width=(width+3)/4;
        const auto row_bytes=std::size_t(packed_width)*4;
        const auto rows=size/row_bytes,remainder=size%row_bytes;
        const unsigned packed_height=rows+(remainder?1:0);
        glActiveTexture(GL_TEXTURE0);
        if(width_!=packed_width || height_!=packed_height) {
            if(texture_)glDeleteTextures(1,&texture_);
            glGenTextures(1,&texture_);glBindTexture(GL_TEXTURE_2D,texture_);
            glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,packed_width,packed_height);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            if(!framebuffer_)glGenFramebuffers(1,&framebuffer_);
            glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture_,0);
            if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("GPU alpha framebuffer");
            if(previous_)glDeleteTextures(1,&previous_);
            glGenTextures(1,&previous_);glBindTexture(GL_TEXTURE_2D,previous_);
            glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,packed_width,packed_height);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            width_=packed_width;height_=packed_height;previous_valid_=false;
        }else glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);
        const bool compare=skip_unchanged && previous_valid_ && source_width_==width && source_height_==height;
        glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_CULL_FACE);glDisable(GL_RASTERIZER_DISCARD);
        glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);glDisable(GL_SAMPLE_COVERAGE);
        glDisable(GL_BLEND);glDisable(GL_SCISSOR_TEST);glDisable(GL_DITHER);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        glViewport(0,0,packed_width,packed_height);glUseProgram(program_);
        glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,previous_);glUniform1i(glGetUniformLocation(program_,"previous"),1);
        glUniform1i(glGetUniformLocation(program_,"compare_previous"),compare);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,source);glUniform1i(glGetUniformLocation(program_,"source"),0);
        glUniform1i(glGetUniformLocation(program_,"source_width"),width);glUniform1i(glGetUniformLocation(program_,"source_count"),size);
        glUniform1i(glGetUniformLocation(program_,"packed_width"),packed_width);
        if(!query_)glGenQueries(1,&query_);
        glBeginQuery(GL_ANY_SAMPLES_PASSED,query_);glDrawArrays(GL_TRIANGLES,0,3);glEndQuery(GL_ANY_SAMPLES_PASSED);
    }

public:
    GpuAlpha()=default;
    GpuAlpha(const GpuAlpha&)=delete;
    GpuAlpha& operator=(const GpuAlpha&)=delete;
    // Explicit cleanup before the owner's EGL context is destroyed.
    void reset() {
        if(framebuffer_)glDeleteFramebuffers(1,&framebuffer_);
        if(texture_)glDeleteTextures(1,&texture_);
        if(previous_)glDeleteTextures(1,&previous_);
        if(query_)glDeleteQueries(1,&query_);
        if(program_)glDeleteProgram(program_);
        framebuffer_=texture_=previous_=query_=program_=width_=height_=source_width_=source_height_=0;previous_valid_=false;tail_.clear();
    }
    // With skip_unchanged, false means target was not written and the caller
    // must retain the last successful alpha plane. Comparison is exact on GPU;
    // no hash, timing heuristic or alpha-content assumption is involved.
    bool extract(GLuint source,unsigned width,unsigned height,std::span<std::uint8_t> target,bool skip_unchanged=false) {
        begin(source,width,height,target.size(),skip_unchanged);
        const auto rows=target.size()/(std::size_t(width_)*4),remainder=target.size()%(std::size_t(width_)*4);
        const auto row_bytes=std::size_t(width_)*4;const auto packed_width=width_,packed_height=height_;
        const bool compare=skip_unchanged && previous_valid_ && source_width_==width && source_height_==height;
        GLuint changed{};glGetQueryObjectuiv(query_,GL_QUERY_RESULT,&changed);
        if(!changed && compare) {
            glBindFramebuffer(GL_FRAMEBUFFER,0);
            if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("GPU alpha comparison failed");
            return false;
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER,0);glPixelStorei(GL_PACK_ALIGNMENT,1);glPixelStorei(GL_PACK_ROW_LENGTH,0);
        glPixelStorei(GL_PACK_SKIP_PIXELS,0);glPixelStorei(GL_PACK_SKIP_ROWS,0);
        if(rows)glReadPixels(0,0,packed_width,rows,GL_RGBA,GL_UNSIGNED_BYTE,target.data());
        if(remainder){tail_.resize(row_bytes);glReadPixels(0,rows,packed_width,1,GL_RGBA,GL_UNSIGNED_BYTE,tail_.data());std::copy_n(tail_.data(),remainder,target.data()+rows*row_bytes);}
        glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,previous_);
        glCopyTexSubImage2D(GL_TEXTURE_2D,0,0,0,0,0,packed_width,packed_height);
        glActiveTexture(GL_TEXTURE0);glBindFramebuffer(GL_FRAMEBUFFER,0);
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("GPU alpha extraction failed");
        previous_valid_=true;source_width_=width;source_height_=height;return true;
    }
};
// One bounded in-flight extraction. submit never waits for a previous job;
// callers keep their newest pending version and continue using completed alpha.
// Results are tagged so callers can reject obsolete window-layout generations.
class GpuAlphaAsync {
public:
    struct Result { std::uint64_t version{};unsigned width{},height{};bool changed{};std::shared_ptr<const std::vector<std::uint8_t>> pixels; };
private:
    GpuAlpha gpu_;
    GLuint pbo_{};GLsync fence_{};
    enum class Stage {idle,compare,readback};Stage stage_{Stage::idle};
    std::uint64_t newest_{};bool submitted_{};Result job_;
    bool compare_{};
    std::shared_ptr<const std::vector<std::uint8_t>> completed_pixels_;
    bool signaled() {
        const auto status=glClientWaitSync(fence_,0,0);
        if(status==GL_TIMEOUT_EXPIRED)return false;
        if(status==GL_WAIT_FAILED)throw std::runtime_error("GPU async alpha fence wait");
        glDeleteSync(fence_);fence_=nullptr;return true;
    }
    void fence() {
        fence_=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
        if(!fence_)throw std::runtime_error("GPU async alpha fence");
        glFlush();
    }
public:
    GpuAlphaAsync()=default;
    GpuAlphaAsync(const GpuAlphaAsync&)=delete;
    GpuAlphaAsync& operator=(const GpuAlphaAsync&)=delete;
    bool pending() const{return stage_!=Stage::idle;}
    // Explicit reset while the owning GL context is current. GL deletion keeps
    // queued object references alive; no CPU wait or global glFinish is needed.
    void reset() {
        if(fence_)glDeleteSync(fence_);
        fence_=nullptr;
        if(pbo_)glDeleteBuffers(1,&pbo_);
        pbo_=0;
        gpu_.reset();stage_=Stage::idle;job_={};newest_=0;submitted_=false;completed_pixels_.reset();
    }
    bool submit(GLuint source,unsigned width,unsigned height,std::uint64_t version) {
        if(pending() || (submitted_ && version<=newest_))return false;
        compare_=gpu_.previous_valid_ && gpu_.source_width_==width && gpu_.source_height_==height;
        gpu_.begin(source,width,height,std::size_t(width)*height,true);
        job_={version,width,height,false,{}};newest_=version;submitted_=true;
        stage_=Stage::compare;fence();glBindFramebuffer(GL_FRAMEBUFFER,0);return true;
    }
    std::optional<Result> poll() {
        if(!pending() || !signaled())return {};
        if(stage_==Stage::compare) {
            GLuint changed{};
            // The fence follows EndQuery, so QUERY_RESULT cannot wait on GPU.
            glGetQueryObjectuiv(gpu_.query_,GL_QUERY_RESULT,&changed);
            if(!changed && compare_){job_.pixels=completed_pixels_;stage_=Stage::idle;return std::move(job_);}
            job_.changed=true;
            const auto bytes=std::size_t(gpu_.width_)*gpu_.height_*4;
            if(!pbo_)glGenBuffers(1,&pbo_);
            glBindBuffer(GL_PIXEL_PACK_BUFFER,pbo_);glBufferData(GL_PIXEL_PACK_BUFFER,bytes,nullptr,GL_STREAM_READ);
            glPixelStorei(GL_PACK_ALIGNMENT,1);glPixelStorei(GL_PACK_ROW_LENGTH,0);
            glPixelStorei(GL_PACK_SKIP_PIXELS,0);glPixelStorei(GL_PACK_SKIP_ROWS,0);
            glBindFramebuffer(GL_FRAMEBUFFER,gpu_.framebuffer_);
            glReadPixels(0,0,gpu_.width_,gpu_.height_,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
            glBindBuffer(GL_PIXEL_PACK_BUFFER,0);
            glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,gpu_.previous_);
            glCopyTexSubImage2D(GL_TEXTURE_2D,0,0,0,0,0,gpu_.width_,gpu_.height_);
            glActiveTexture(GL_TEXTURE0);glBindFramebuffer(GL_FRAMEBUFFER,0);
            if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("GPU async alpha readback submit");
            stage_=Stage::readback;fence();return {};
        }
        const auto size=std::size_t(job_.width)*job_.height;
        auto pixels=std::make_shared<std::vector<std::uint8_t>>(size);
        glBindBuffer(GL_PIXEL_PACK_BUFFER,pbo_);
        const auto* data=glMapBufferRange(GL_PIXEL_PACK_BUFFER,0,size,GL_MAP_READ_BIT);
        if(!data){glBindBuffer(GL_PIXEL_PACK_BUFFER,0);throw std::runtime_error("GPU async alpha map");}
        std::memcpy(pixels->data(),data,size);
        const bool valid=glUnmapBuffer(GL_PIXEL_PACK_BUFFER);glBindBuffer(GL_PIXEL_PACK_BUFFER,0);
        if(!valid)throw std::runtime_error("GPU async alpha corrupt readback");
        completed_pixels_=pixels;job_.pixels=std::move(pixels);
        gpu_.previous_valid_=true;gpu_.source_width_=job_.width;gpu_.source_height_=job_.height;
        stage_=Stage::idle;return std::move(job_);
    }
};

}
