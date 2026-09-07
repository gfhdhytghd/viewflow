// SPDX-License-Identifier: GPL-3.0-only
#include <QApplication>
#include <QFile>
#include <QEnterEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMouseEvent>
#include <QWheelEvent>
#include <QKeyEvent>
#include <QInputMethodEvent>
#include <QJsonArray>
#include <QLineEdit>
#include <QPainter>
#include <QTimer>
#include <QWidget>
#include <chrono>
#include <cstdio>

// Owned application-side input witness. No grabs, injection, focus requests,
// global keyboard logging or arbitrary commands. Optional --keyboard observes
// only events delivered to this owned widget, for explicit isolated tests.
class Probe final : public QWidget {
 public:
  explicit Probe(QFile& log, QString label, bool keyboard, bool ime = false) : log_(log), label_(std::move(label)), keyboard_(keyboard || ime) {
    setWindowTitle(QStringLiteral("Viewflow owned pointer probe - ") + label_);
    setWindowFlag(Qt::FramelessWindowHint);
    setAttribute(Qt::WA_ShowWithoutActivating);
    setMouseTracking(true);
    if (keyboard_) setFocusPolicy(Qt::StrongFocus);
    setFixedSize(791, 598);
    if (ime) {
      editor_ = new QLineEdit(this);
      editor_->setObjectName(QStringLiteral("owned-ime-witness"));
      editor_->setGeometry(20, 100, 740, 48);
      editor_->setMaxLength(4096);
      editor_->setAcceptDrops(false);
      editor_->setDragEnabled(false);
      editor_->setContextMenuPolicy(Qt::NoContextMenu);
      editor_->setPlaceholderText(QStringLiteral("Isolated source IME witness — no secrets"));
      editor_->installEventFilter(this);
      setFocusProxy(editor_);
      connect(editor_, &QLineEdit::textChanged, this, [this](const QString& text) {
        record("editor_text", {{"text", text}, {"cursor", editor_->cursorPosition()}});
      });
    }
    record("ready", {});
  }
 protected:
  bool eventFilter(QObject* watched, QEvent* event) override {
    if (watched != editor_) return QWidget::eventFilter(watched, event);
    if (event->type() == QEvent::InputMethod) {
      const auto* input = static_cast<QInputMethodEvent*>(event);
      if (input->preeditString().size() > 4096 || input->commitString().size() > 4096 ||
          input->attributes().size() > 256) {
        record("ime_rejected_oversize", {});
        QTimer::singleShot(0, qApp, [] { QApplication::exit(2); });
        return true;
      }
      QJsonArray attributes;
      for (const auto& attribute : input->attributes())
        attributes.append(QJsonObject{{"type", static_cast<int>(attribute.type)},
            {"start", attribute.start}, {"length", attribute.length}});
      record("ime", {{"preedit", input->preeditString()}, {"commit", input->commitString()},
          {"replacement_start", input->replacementStart()}, {"replacement_length", input->replacementLength()},
          {"attributes", attributes}, {"spontaneous", input->spontaneous()}});
      // The real Qt editor, not this logger, applies replacement and preedit.
    } else if (event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease) {
      auto* key = static_cast<QKeyEvent*>(event);
      keyEvent(event->type() == QEvent::KeyPress ? "key_press" : "key_release", key);
      // Block ordinary clipboard shortcuts, including Shift+Insert.
      if (key->matches(QKeySequence::Copy) || key->matches(QKeySequence::Cut) ||
          key->matches(QKeySequence::Paste)) return true;
    } else if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
      if (static_cast<QMouseEvent*>(event)->button() == Qt::MiddleButton) return true;
    } else if (event->type() == QEvent::FocusIn || event->type() == QEvent::FocusOut) {
      record(event->type() == QEvent::FocusIn ? "editor_focus_in" : "editor_focus_out", {});
    }
    return QWidget::eventFilter(watched, event);
  }
  void keyPressEvent(QKeyEvent* event) override { keyEvent("key_press", event); }
  void keyReleaseEvent(QKeyEvent* event) override { keyEvent("key_release", event); }
  void enterEvent(QEnterEvent* event) override {
    record("enter", {{"x", event->position().x()}, {"y", event->position().y()}});
  }
  void leaveEvent(QEvent*) override { record("leave", {}); }
  void mouseMoveEvent(QMouseEvent* event) override {
    point_ = event->position();
    record("motion", {{"x", point_.x()}, {"y", point_.y()},
                      {"qt_buttons", static_cast<int>(event->buttons())},
                      {"spontaneous", event->spontaneous()}});
    update();
  }
  void mousePressEvent(QMouseEvent* event) override { buttonEvent("press", event); }
  void mouseReleaseEvent(QMouseEvent* event) override { buttonEvent("release", event); }
  void wheelEvent(QWheelEvent* event) override {
    record("wheel", {{"x", event->position().x()}, {"y", event->position().y()},
                     {"angle_x", event->angleDelta().x()}, {"angle_y", event->angleDelta().y()},
                     {"pixel_x", event->pixelDelta().x()}, {"pixel_y", event->pixelDelta().y()},
                     {"qt_buttons", static_cast<int>(event->buttons())},
                     {"phase", static_cast<int>(event->phase())},
                     {"inverted", event->inverted()}, {"spontaneous", event->spontaneous()}});
    event->accept(); // Witness only; no application action or synthesized input.
  }
  void paintEvent(QPaintEvent*) override {
    QPainter painter(this);
    painter.fillRect(rect(), QColor(24, 32, 44));
    painter.setPen(QColor(65, 82, 100));
    for (int x = 0; x < width(); x += 50) painter.drawLine(x, 0, x, height());
    for (int y = 0; y < height(); y += 50) painter.drawLine(0, y, width(), y);
    painter.setPen(Qt::white);
    painter.drawText(20, 30, keyboard_ ? QStringLiteral("Owned input witness - no actions") :
        QStringLiteral("Owned pointer witness - no actions or keys"));
    painter.drawText(20, 60, label_);
    painter.setPen(QPen(QColor(80, 230, 190), 2));
    painter.drawEllipse(point_, 7, 7);
  }
 private:
  void keyEvent(const char* kind, QKeyEvent* event) {
    if (!keyboard_) { event->ignore(); return; }
    record(kind, {{"key", event->key()}, {"scan_code", static_cast<qint64>(event->nativeScanCode())},
        {"modifiers", static_cast<int>(event->modifiers())}, {"text", event->text()},
        {"repeat", event->isAutoRepeat()}, {"spontaneous", event->spontaneous()}});
    event->accept();
  }
  void buttonEvent(const char* kind, QMouseEvent* event) {
    point_ = event->position();
    record(kind, {{"x", point_.x()}, {"y", point_.y()},
                  {"qt_button", static_cast<int>(event->button())},
                  {"qt_buttons", static_cast<int>(event->buttons())},
                  {"spontaneous", event->spontaneous()}});
    update();
  }
  void record(const char* kind, QJsonObject fields) {
    if (sequence_ >= 4096) {
      QTimer::singleShot(0, qApp, &QApplication::quit);
      return;
    }
    fields.insert("kind", QString::fromLatin1(kind));
    fields.insert("sequence", static_cast<qint64>(++sequence_));
    fields.insert("width", width());
    fields.insert("height", height());
    fields.insert("monotonic_ns", QString::number(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count()));
    auto bytes = QJsonDocument(fields).toJson(QJsonDocument::Compact);
    bytes.append('\n');
    if (log_.write(bytes) != bytes.size() || !log_.flush())
      QTimer::singleShot(0, qApp, [] { QApplication::exit(2); });
  }
  QFile& log_;
  QString label_;
  QPointF point_{-20, -20};
  quint64 sequence_{};
  bool keyboard_ = false;
  QLineEdit* editor_ = nullptr;
};

#ifndef VIEWFLOW_PROBE_TEST
int main(int argc, char** argv) {
  QApplication app(argc, argv);
  if ((argc != 2 && argc != 3 && argc != 4) || !QString::fromLocal8Bit(argv[1]).startsWith('/') ||
      (argc == 4 && QString::fromLocal8Bit(argv[3]) != QStringLiteral("--keyboard") &&
          QString::fromLocal8Bit(argv[3]) != QStringLiteral("--ime"))) {
    std::fputs("usage: viewflow_linux_pointer_probe /absolute/new-log.jsonl [label [--keyboard|--ime]]\n", stderr);
    return 2;
  }
  QFile log(QString::fromLocal8Bit(argv[1]));
  if (!log.open(QIODevice::WriteOnly | QIODevice::NewOnly)) return 2;
  if (!log.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)) return 2;
  const auto label = argc >= 3 ? QString::fromLocal8Bit(argv[2]).left(80) : QStringLiteral("single");
  Probe probe(log, label, argc == 4, argc == 4 && QString::fromLocal8Bit(argv[3]) == QStringLiteral("--ime"));
  probe.show();
  QTimer::singleShot(90000, &app, &QApplication::quit);
  return app.exec();
}
#endif
