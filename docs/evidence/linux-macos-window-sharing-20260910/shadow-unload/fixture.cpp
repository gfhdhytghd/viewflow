#include <QGuiApplication>
#include <QWindow>
#include <QBackingStore>
#include <QPainter>
#include <QTimer>
int main(int argc,char**argv){QGuiApplication app(argc,argv);app.setDesktopFileName("ViewflowReverse-Mac-1");QWindow w;w.setFlags(Qt::Window|Qt::WindowDoesNotAcceptFocus|Qt::WindowTransparentForInput);w.setTitle("Viewflow isolated shadow lifecycle fixture");w.resize(600,400);QBackingStore store(&w);QTimer timer;QObject::connect(&timer,&QTimer::timeout,[&]{if(!w.isExposed())return;store.resize(w.size());store.beginPaint(QRect(QPoint(),w.size()));{QPainter p(store.paintDevice());p.fillRect(0,0,w.width(),w.height(),QColor(80,120,160));}store.endPaint();store.flush(QRect(QPoint(),w.size()));});timer.start(50);w.show();return app.exec();}
