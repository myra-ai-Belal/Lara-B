import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice pipeline for Lara's call mode: speech-to-text (listens for the
/// user's command) and text-to-speech (speaks Lara's reply back).
/// Supports Bengali (bn-BD) alongside English, and exposes a continuous
/// "call style" listening mode used by CallScreen.
class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isListening = false;
  bool _isSpeaking = false;

  /// 'bn-BD' for Bangla, 'en-US' for English. Persisted across sessions.
  String _languageCode = 'bn-BD';

  bool get isListening => _isListening;
  bool get isSpeaking => _isSpeaking;
  String get languageCode => _languageCode;
  bool get isBangla => _languageCode.startsWith('bn');

  /// speech_to_text locale ids use underscores, flutter_tts uses hyphens.
  String get _sttLocaleId => _languageCode.replaceAll('-', '_');

  Future<void> init() async {
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    _languageCode = prefs.getString('voice_language') ?? 'bn-BD';

    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _isListening = false;
        }
      },
    );

    await _configureTts();
  }

  Future<void> _configureTts() async {
    // Try the selected language; if the device has no voice data for it
    // (common for Bangla on some phones), fall back to English rather
    // than silently failing to speak at all.
    try {
      final setResult = await _tts.setLanguage(_languageCode);
      if (setResult != 1) {
        await _tts.setLanguage('en-US');
      }
    } catch (_) {
      await _tts.setLanguage('en-US');
    }
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.05);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() => _isSpeaking = false);
    _tts.setCancelHandler(() => _isSpeaking = false);
    _tts.setErrorHandler((_) => _isSpeaking = false);
  }

  Future<void> setLanguage(String code) async {
    _languageCode = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice_language', code);
    await _configureTts();
  }

  /// Returns true if the device appears to support Bangla speech recognition.
  Future<bool> isBanglaSttAvailable() async {
    if (!_isInitialized) await init();
    try {
      final locales = await _speech.locales();
      return locales.any((l) => l.localeId.toLowerCase().startsWith('bn'));
    } catch (_) {
      return false;
    }
  }

  /// Listen for ONE utterance (used by the older chat-box mic button).
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return;

    _isListening = true;
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          onResult(result.recognizedWords);
          onDone();
        }
      },
      localeId: _sttLocaleId,
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: false,
      ),
    );
  }

  /// Call-mode listening: reports partial results live (for the animated
  /// waveform/caption) and calls [onFinal] once the user stops talking.
  Future<void> listenForCall({
    required Function(String partialText) onPartial,
    required Function(String finalText) onFinal,
    required Function() onTimeout,
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) {
      onTimeout();
      return;
    }

    _isListening = true;
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          if (result.recognizedWords.trim().isEmpty) {
            onTimeout();
          } else {
            onFinal(result.recognizedWords);
          }
        } else {
          onPartial(result.recognizedWords);
        }
      },
      localeId: _sttLocaleId,
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  Future<void> stopListening() async {
    _isListening = false;
    await _speech.stop();
  }

  /// Speak text aloud and wait for it to finish (so the call flow can
  /// move on to listening again right after, instead of talking over itself).
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _isSpeaking = true;
    final completer = Completer<void>();
    void onDone() {
      if (!completer.isCompleted) completer.complete();
    }

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      onDone();
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
      onDone();
    });
    _tts.setErrorHandler((_) {
      _isSpeaking = false;
      onDone();
    });

    await _tts.speak(text);
    // Safety timeout so a stuck TTS engine never freezes the call loop.
    await completer.future.timeout(
      Duration(seconds: 6 + (text.length ~/ 8)),
      onTimeout: () {
        _isSpeaking = false;
      },
    );
  }

  Future<void> stopSpeaking() async {
    _isSpeaking = false;
    await _tts.stop();
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
