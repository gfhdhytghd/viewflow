// SPDX-License-Identifier: GPL-3.0-only
#define VIEWFLOW_PROBE_TEST
#include "main.cpp"
#include <QTemporaryDir>
#include <cstdlib>

static void require(bool condition) {
  if (!condition) std::abort();
}

int main(int argc, char** argv) {
  QApplication app(argc, argv);
  QTemporaryDir directory;
  require(directory.isValid());
  QFile log(directory.filePath(QStringLiteral("ime.jsonl")));
  require(log.open(QIODevice::ReadWrite | QIODevice::NewOnly));
  Probe probe(log, QStringLiteral("ime-test"), true, true);
  auto* editor = probe.findChild<QLineEdit*>(QStringLiteral("owned-ime-witness"));
  require(editor && editor->testAttribute(Qt::WA_InputMethodEnabled));
  QInputMethodEvent preedit(QStringLiteral("ni"), {
      QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, 2, 1, {})});
  QApplication::sendEvent(editor, &preedit);
  require(editor->text().isEmpty());
  QInputMethodEvent commit;
  commit.setCommitString(QString::fromUtf8("你"));
  QApplication::sendEvent(editor, &commit);
  require(editor->text() == QString::fromUtf8("你"));
  QInputMethodEvent replacement;
  replacement.setCommitString(QString::fromUtf8("好"), -1, 1);
  QApplication::sendEvent(editor, &replacement);
  require(editor->text() == QString::fromUtf8("好"));
  QInputMethodEvent second(QStringLiteral("hao"), {});
  QApplication::sendEvent(editor, &second);
  QInputMethodEvent cancel;
  QApplication::sendEvent(editor, &cancel);
  require(editor->text() == QString::fromUtf8("好"));
  // Validate actual serialized witness output, not only editor state.
  require(log.seek(0));
  int ime = 0, text = 0;
  while (!log.atEnd()) {
    const auto object = QJsonDocument::fromJson(log.readLine()).object();
    require(!object.isEmpty());
    if (object.value("kind") == "ime") {
      ++ime;
      require(!object.value("spontaneous").toBool());
      if (ime == 1) {
        require(object.value("preedit") == "ni");
        require(object.value("attributes").toArray().size() == 1);
      }
      if (ime == 3) require(object.value("replacement_start").toInt() == -1);
      if (ime == 5) require(object.value("preedit").toString().isEmpty());
    }
    if (object.value("kind") == "editor_text") ++text;
  }
  require(ime == 5 && text == 2);
  QFile directLog(directory.filePath(QStringLiteral("direct.jsonl")));
  require(directLog.open(QIODevice::WriteOnly | QIODevice::NewOnly));
  Probe direct(directLog, QStringLiteral("direct-test"), true);
  require(!direct.findChild<QLineEdit*>());
}
