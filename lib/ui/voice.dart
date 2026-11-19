import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/models.dart';

/// Reads assistant messages aloud. One message speaks at a time.
class Speaker extends ChangeNotifier {
  Speaker._();
  static final instance = Speaker._();

  final _tts = FlutterTts();
  bool _ready = false;

  /// The message being read, if any.
  Message? speaking;

  Future<void> toggle(Message m) async {
    if (speaking == m) return stop();
    await stop();
    if (!_ready) {
      _ready = true;
      _tts.setCompletionHandler(_done);
      _tts.setCancelHandler(_done);
      _tts.setErrorHandler((_) => _done());
    }
    speaking = m;
    notifyListeners();
    try {
      await _tts.speak(plainSpeech(m.content));
    } catch (_) {
      _done();
    }
  }

  Future<void> stop() async {
    if (speaking == null) return;
    try {
      await _tts.stop();
    } catch (_) {}
    _done();
  }

  void _done() {
    if (speaking == null) return;
    speaking = null;
    notifyListeners();
  }
}

/// Strips Markdown so the voice does not read symbols aloud.
String plainSpeech(String md) => md
    .replaceAll(RegExp(r'```[\s\S]*?```'), '（代码略）')
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'[`*_#>|~]'), '')
    .replaceAll(RegExp(r'^\s*[-+]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\n{2,}'), '\n')
    .trim();

/// Dictation into a text field. [onText] receives the full transcript so far.
class Dictation extends ChangeNotifier {
  final _stt = SpeechToText();
  bool _initialised = false;
  bool _disposed = false;
  bool listening = false;

  @override
  void dispose() {
    _disposed = true;
    if (listening) _stt.cancel();
    super.dispose();
  }

  Future<String?> start(void Function(String text) onText) async {
    try {
      if (!_initialised) {
        _initialised = await _stt.initialize(
          onStatus: (s) {
            if (s == 'done' || s == 'notListening') _set(false);
          },
          onError: (_) => _set(false),
        );
      }
      if (!_initialised) return '语音识别不可用，请检查麦克风和语音识别权限';
      await _stt.listen(onResult: (SpeechRecognitionResult r) => onText(r.recognizedWords));
      _set(true);
      return null;
    } catch (e) {
      _set(false);
      return '语音识别失败：$e';
    }
  }

  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
    _set(false);
  }

  void _set(bool v) {
    if (_disposed || listening == v) return;
    listening = v;
    notifyListeners();
  }
}
