// SPDX-License-Identifier: GPL-3.0-only
#include <QApplication>
#include <QPainter>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QTimer>
#include <QWidget>
#include <cstdio>

// Self-contained geometry witness for an explicitly isolated compositor.
// No input injection, clipboard access, activation request or global logging.
class Panel final : public QWidget {
  public:
    Panel(QWidget* parent, Qt::WindowFlags flags, QColor color)
        : QWidget(parent, flags), m_color(color) {
        setAttribute(Qt::WA_ShowWithoutActivating);
        setMouseTracking(true);
    }
  protected:
    void mousePressEvent(QMouseEvent* event) override { reportButton(event, true); }
    void mouseReleaseEvent(QMouseEvent* event) override { reportButton(event, false); }
    void keyPressEvent(QKeyEvent* event) override { reportKey(event, true); }
    void keyReleaseEvent(QKeyEvent* event) override { reportKey(event, false); }
    void mouseMoveEvent(QMouseEvent* event) override {
        std::printf("{\"event\":\"motion\",\"x\":%.3f,\"y\":%.3f}\n",
            event->position().x(), event->position().y());
        std::fflush(stdout);
    }
    void paintEvent(QPaintEvent*) override {
        QPainter paint(this);
        paint.fillRect(rect(), m_color);
        paint.setPen(Qt::white);
        paint.drawText(16, 30, parentWidget() ? "Owned family popup" : "Owned geometry witness");
    }
  private:
    void reportButton(QMouseEvent* event, bool down) {
        std::printf("{\"event\":\"button\",\"down\":%s,\"button\":%d}\n",
            down ? "true" : "false", int(event->button()));
        std::fflush(stdout);
        event->accept();
    }
    void reportKey(QKeyEvent* event, bool down) {
        std::printf("{\"event\":\"key\",\"down\":%s,\"scan\":%u,\"repeat\":%s}\n",
            down ? "true" : "false", event->nativeScanCode(), event->isAutoRepeat() ? "true" : "false");
        std::fflush(stdout);
        event->accept();
    }
    QColor m_color;
};

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    if (argc != 1) return 2;
    Panel main(nullptr, Qt::FramelessWindowHint, QColor(20, 60, 100));
    main.setWindowTitle("Viewflow owned family geometry probe");
    main.setFixedSize(400, 300);
    Panel popup(&main, Qt::ToolTip, QColor(160, 40, 80));
    popup.setFixedSize(240, 140);
    const auto report = [](const char* phase) {
        std::printf("{\"phase\":\"%s\"}\n", phase);
        std::fflush(stdout);
    };
    main.show();
    report("initial");
    QTimer::singleShot(12000, &main, [&] {
        main.setFixedSize(500, 350);
        report("main-resized");
    });
    QTimer::singleShot(18000, &main, [&] {
        popup.move(main.mapToGlobal(QPoint(main.width() - 30, main.height() - 25)));
        popup.show();
        report("popup-shown");
    });
    QTimer::singleShot(24000, &main, [&] { popup.hide(); report("popup-hidden"); });
    QTimer::singleShot(28000, &main, [&] {
        main.setFixedSize(400, 300);
        report("main-restored");
    });
    QTimer::singleShot(34000, &app, &QApplication::quit);
    return app.exec();
}
