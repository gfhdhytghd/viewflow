"""Local-only window recall control; never sends keyboard events to a peer."""
import json
import os
from pathlib import Path
import re
import subprocess
import time

DEFAULT_SHORTCUT = 'Ctrl+Alt+Shift+H'


def canonical_shortcut(value):
    names = {'CTRL': 'Ctrl', 'CONTROL': 'Ctrl', 'ALT': 'Alt', 'OPTION': 'Alt',
             'SHIFT': 'Shift', 'SUPER': 'Super', 'WIN': 'Super', 'CMD': 'Super', 'COMMAND': 'Super'}
    modifiers = set()
    letter = None
    for token in value.upper().split('+'):
        token = token.strip()
        if token in names:
            name = names[token]
            if name in modifiers: raise ValueError('快捷键修饰键重复')
            modifiers.add(name)
        elif re.fullmatch('[A-Z]', token) and letter is None: letter = token
        else: raise ValueError('请输入修饰键和一个字母，例如 Ctrl+Alt+Shift+H')
    if not modifiers or letter is None: raise ValueError('快捷键需要修饰键和一个字母')
    return '+'.join([name for name in ('Ctrl', 'Alt', 'Shift', 'Super') if name in modifiers] + [letter])


class RecallController:
    def __init__(self, platform, binary, data, shortcut=DEFAULT_SHORTCUT):
        self.platform, self.binary, self.data = platform, binary, Path(data)
        try: self.shortcut = canonical_shortcut(shortcut)
        except (ValueError, AttributeError): self.shortcut = DEFAULT_SHORTCUT
        self.process = None
        self.log = None
        self.status = ''
        self.retry_at = 0
        self.previous = None

    def _run(self, args):
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if self.platform == 'windows' else {}
        result = subprocess.run(args, capture_output=True, text=True, errors='replace', timeout=4, **options)
        if result.returncode: raise RuntimeError(result.stderr.strip() or result.stdout.strip() or '收回窗口组件执行失败')
        return result.stdout.strip()

    def _linux(self, expression):
        output = self._run(['hyprctl', 'eval', expression])
        # Hyprctl may return a compositor error with a zero process exit code.
        if 'error' in output.lower() or 'nil value' in output.lower(): raise RuntimeError(output)
        return output

    def configure(self, value):
        value = canonical_shortcut(value)
        if self.platform == 'linux':
            self._linux('return viewflow.set_recall_shortcut(' + json.dumps(value) + ')')
            self.shortcut = value
            self.status = '收回本机窗口：' + value
            self.retry_at = time.monotonic() + 5
        else:
            self._run([str(self.binary), '--validate-shortcut', '--shortcut', value])
            self.previous = self.shortcut if self.process else None
            self.stop()
            self.shortcut = value
            self._start()

    def _start(self):
        self.data.mkdir(parents=True, exist_ok=True)
        self.log = (self.data / 'window-recall.log').open('wb')
        try:
            self.process = subprocess.Popen([str(self.binary), '--watch', '--shortcut', self.shortcut, '--parent', str(os.getpid())],
                                            stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
            self.status = '正在注册收回窗口快捷键'
        except Exception:
            self.log.close(); self.log = None
            raise

    def poll(self):
        try:
            if self.platform == 'linux':
                if time.monotonic() >= self.retry_at:
                    self.retry_at = time.monotonic() + 5
                    self.configure(self.shortcut)
            elif self.process is None and time.monotonic() >= self.retry_at:
                self._start()
            elif self.process is not None:
                if self.process.poll() is not None:
                    message = (self.data / 'window-recall.log').read_text(errors='replace').strip()
                    previous = self.previous
                    self.stop(); self.previous = None; self.retry_at = time.monotonic() + 5
                    if previous and previous != self.shortcut:
                        self.shortcut = previous
                        self._start()
                    raise RuntimeError(message or '收回窗口快捷键未注册')
                elif 'recall ready' in (self.data / 'window-recall.log').read_text(errors='replace'):
                    self.previous = None
                    self.status = '收回本机窗口：' + self.shortcut
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            self.status = str(error)
            self.retry_at = time.monotonic() + 5
        return self.status

    def recall(self):
        if self.platform == 'linux':
            return self._linux('return viewflow.recall_windows(false)')
        return self._run([str(self.binary), '--once'])

    def stop(self):
        if self.process:
            self.process.terminate()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait(timeout=2)
            self.process = None
        if self.log: self.log.close(); self.log = None
