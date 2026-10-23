// Owned 4K motion/interaction witness. Frame swaps are not physical receipts.
#include <QGuiApplication>
#include <QWindow>
#include <QExposeEvent>
#include <QOpenGLExtraFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLContext>
#include <QScreen>
#include <QSurfaceFormat>
#include <QTimer>
#include <QMouseEvent>
#include <QKeyEvent>
#include <cstdio>
#include <ctime>

static unsigned long long monotonic_ns() {
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  return static_cast<unsigned long long>(now.tv_sec) * 1'000'000'000ULL + now.tv_nsec;
}

class Fixture final : public QWindow, protected QOpenGLExtraFunctions {
public:
  Fixture() {
    setTitle(QStringLiteral("Viewflow isolated 4K frame fixture"));
    setFlags(Qt::Window | Qt::FramelessWindowHint | Qt::WindowDoesNotAcceptFocus);
    setSurfaceType(QSurface::OpenGLSurface);
    frame_timer_.setSingleShot(true);
    frame_timer_.setTimerType(Qt::PreciseTimer);
    connect(&frame_timer_, &QTimer::timeout, this, [this] { render(); });
  }
  ~Fixture() override {
    if (initialized_ && context_.makeCurrent(this)) {
      program_.removeAllShaders();
      glDeleteVertexArrays(1, &vao_);
      context_.doneCurrent();
    }
  }
protected:
  void exposeEvent(QExposeEvent*) override {
    if (isExposed()) render();
  }
  bool event(QEvent* event) override {
    if (event->type() == QEvent::UpdateRequest) { render(); return true; }
    return QWindow::event(event);
  }
  void initializeGL() {
    context_.setFormat(requestedFormat());
    if (!context_.create() || !context_.makeCurrent(this)) qFatal("fixture OpenGL context unavailable");
    initializeOpenGLFunctions();
    std::printf("fixture-gpu renderer=%s version=%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    glGenVertexArrays(1, &vao_);
    const char* vertex = R"GLSL(#version 300 es
precision highp float;
precision highp int;
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})GLSL";
    const char* fragment = R"GLSL(#version 300 es
precision highp float;
precision highp int;
uniform uint frame_id;
uniform uint input_id;
uniform vec2 extent;
out vec4 color;
void main() {
  vec2 p = vec2(gl_FragCoord.x, extent.y - gl_FragCoord.y);
  // Smooth motion plus sharp edges across the whole canvas; not a static ID-only load.
  float x = p.x + float(frame_id % 4096u) * 5.0;
  float y = p.y + float(frame_id % 4096u) * 2.0;
  float checker = mod(floor(x / 96.0) + floor(y / 96.0), 2.0);
  vec3 bg = mix(vec3(0.09, 0.18, 0.3), vec3(0.72, 0.83, 0.93), checker);
  bg *= 0.65 + 0.35 * p.x / extent.x;
  if (mod(p.y + float(frame_id % 512u) * 7.0, 512.0) < 24.0) bg = vec3(0.9, 0.24, 0.08);
  // Top-left marker: 32 frame bits, 16 input bits, 16 check bits, MSB first.
  // Each bit occupies 32x64 physical pixels. Read cell centers after lossy H.264.
  if (p.x >= 32.0 && p.x < 2080.0 && p.y >= 32.0 && p.y < 96.0) {
    uint cell = uint((p.x - 32.0) / 32.0);
    uint check_bits = (frame_id ^ (frame_id >> 16u) ^ input_id ^ 0xA65Cu) & 65535u;
    uint bit;
    if (cell < 32u) bit = (frame_id >> (31u - cell)) & 1u;
    else if (cell < 48u) bit = (input_id >> (47u - cell)) & 1u;
    else bit = (check_bits >> (63u - cell)) & 1u;
    bg = vec3(bit == 0u ? 0.04 : 0.96);
  }
  bool marker = p.x >= 32.0 && p.x < 2080.0 && p.y >= 32.0 && p.y < 96.0;
  bool edge = p.x < 128.0 || p.y < 128.0 || p.x >= extent.x-128.0 || p.y >= extent.y-128.0;
  float alpha = edge && !marker ? 128.0/255.0 : 1.0;
  color = vec4(bg * alpha, alpha);
})GLSL";
    if (!program_.addShaderFromSourceCode(QOpenGLShader::Vertex, vertex) ||
        !program_.addShaderFromSourceCode(QOpenGLShader::Fragment, fragment) || !program_.link())
      qFatal("fixture shader failed: %s", qPrintable(program_.log()));
    std::printf("fixture-ready logical=%dx%d dpr=%.2f screen=%s\n", width(), height(),
                devicePixelRatio(), qPrintable(screen()->name()));
  }
  void render() {
    if (!isExposed()) return;
    const auto now = monotonic_ns();
    if (next_paint_ns_ && now < next_paint_ns_) {
      scheduleFrame();
      return;
    }
    if (!next_paint_ns_) next_paint_ns_ = now;
    if (!initialized_) { initializeGL(); initialized_ = true; }
    if (!context_.makeCurrent(this)) qFatal("fixture context activation failed");
    paintGL();
    context_.swapBuffers(this);
    std::printf("fixture-swap frame=%u input=%u time_ns=%llu physical_receipt=false\n",
                frame_, input_, monotonic_ns());
    next_paint_ns_ += 16'666'667ULL;
    // Do not burst obsolete producer frames after a stall.
    const auto finished = monotonic_ns();
    if (finished > next_paint_ns_ + 16'666'667ULL) next_paint_ns_ = finished;
    scheduleFrame();
  }
  void paintGL() {
    ++frame_;
    const auto started = monotonic_ns();
    const int w = qRound(width() * devicePixelRatio()), h = qRound(height() * devicePixelRatio());
    glViewport(0, 0, w, h);
    program_.bind();
    glUniform1ui(program_.uniformLocation("frame_id"), frame_);
    glUniform1ui(program_.uniformLocation("input_id"), input_);
    program_.setUniformValue("extent", QVector2D(float(w), float(h)));
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    program_.release();
    std::printf("fixture-render frame=%u input=%u time_ns=%llu pixels=%dx%d\n", frame_, input_, started, w, h);
  }
  void mousePressEvent(QMouseEvent* event) override {
    recordInput("mouse-press", int(event->button()));
  }
  void keyPressEvent(QKeyEvent* event) override {
    if (!event->isAutoRepeat()) recordInput("key-press", event->key());
  }
private:
  void scheduleFrame() {
    const auto now = monotonic_ns();
    const auto wait_ns = next_paint_ns_ > now ? next_paint_ns_ - now : 0;
    frame_timer_.start(int((wait_ns + 999'999ULL) / 1'000'000ULL));
  }
  void recordInput(const char* kind, int code) {
    ++input_;
    std::printf("fixture-input sequence=%u kind=%s code=%d time_ns=%llu\n", input_, kind, code, monotonic_ns());
    requestUpdate();
  }
  QOpenGLContext context_;
  QTimer frame_timer_;
  unsigned long long next_paint_ns_{};
  bool initialized_{};
  QOpenGLShaderProgram program_;
  GLuint vao_{};
  unsigned frame_{}, input_{};
};

int main(int argc, char** argv) {
  qInstallMessageHandler([](QtMsgType, const QMessageLogContext&, const QString& message) {
    std::fprintf(stderr, "%s\n", qPrintable(message));
  });
  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGLES);
  format.setVersion(3, 0);
  format.setSwapInterval(1);
  format.setAlphaBufferSize(8);
  QSurfaceFormat::setDefaultFormat(format);
  QGuiApplication app(argc, argv);
  app.setDesktopFileName(QStringLiteral("viewflow-full-glass-fixture"));
  const auto args = app.arguments();
  if (args.size() != 3) qFatal("usage: fixture SCREEN DURATION_MS");
  bool ok{};
  const int duration = args[2].toInt(&ok);
  if (!ok || duration < 1000 || duration > 300000) qFatal("duration must be 1000..300000 ms");
  QScreen* target{};
  for (auto* screen : app.screens()) if (screen->name() == args[1]) target = screen;
  if (!target) qFatal("requested screen unavailable");
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  Fixture fixture;
  fixture.setScreen(target);
  fixture.resize(qRound(3840 / target->devicePixelRatio()), qRound(2400 / target->devicePixelRatio()));
  fixture.setPosition(target->geometry().topLeft());
  QTimer::singleShot(duration, &app, &QCoreApplication::quit);
  fixture.show();
  return app.exec();
}
