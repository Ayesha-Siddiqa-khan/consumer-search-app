import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// Quiet speech resets silence immediately; invalid readings are not silence.
class SpeechEndpointDetector {
  double _noiseFloor = -60;
  Duration? _lastSpeech;
  int _speechFrames = 0;
  bool hasSpeech = false;

  bool add(double db, Duration elapsed) {
    if (!db.isFinite || db > 0) return false;
    if (db < _noiseFloor) _noiseFloor = db;
    final threshold = (_noiseFloor + 10).clamp(-55.0, -40.0);
    if (db > threshold) {
      _lastSpeech = elapsed;
      if (++_speechFrames >= 2) hasSpeech = true;
    } else {
      _speechFrames = 0;
    }
    return hasSpeech &&
        elapsed >= const Duration(seconds: 4) &&
        elapsed - _lastSpeech! >= const Duration(milliseconds: 2800);
  }
}

class AudioRecorderService {
  static final instance = AudioRecorderService._internal();
  AudioRecorderService._internal();
  @visibleForTesting
  AudioRecorderService.forTesting(AudioRecorder recorder)
    : _recorder = recorder;

  AudioRecorder? _recorder;
  bool _isRecording = false;
  Timer? _meterTimer;
  Timer? _maxTimer;
  Future<String?>? _stopping;
  String? _lastPath;
  int _session = 0;
  bool get isRecording => _isRecording;
  String get defaultWavPath =>
      p.join(Directory.systemTemp.path, 'search_voice.wav');

  Future<bool> startRecording({
    String? outputPath,
    VoidCallback? onSpeechActive,
    VoidCallback? onAutoStop,
  }) async {
    final session = ++_session;
    await stopRecording();
    if (session != _session) return false;
    _lastPath = null;
    final recorder = _recorder ??= AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        await recorder.dispose();
        _recorder = null;
        return false;
      }
      final target = outputPath ?? defaultWavPath;
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: target,
      );
      if (session != _session) {
        await recorder.stop();
        await recorder.dispose();
        _recorder = null;
        return false;
      }
      _isRecording = true;
      final clock = Stopwatch()..start();
      final detector = SpeechEndpointDetector();
      var polling = false;
      var notified = false;
      Future<void> finish() async {
        if (!_isRecording || session != _session) return;
        await stopRecording();
        if (session == _session) onAutoStop?.call();
      }

      _meterTimer = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) async {
        if (polling || !_isRecording) return;
        polling = true;
        try {
          final amp = await recorder.getAmplitude();
          if (!_isRecording || session != _session) return;
          final done = detector.add(amp.current, clock.elapsed);
          if (detector.hasSpeech && !notified) {
            notified = true;
            onSpeechActive?.call();
          }
          if (done) await finish();
        } catch (e) {
          debugPrint('Microphone level unavailable: $e');
        } finally {
          polling = false;
        }
      });
      _maxTimer = Timer(const Duration(seconds: 30), finish);
      return true;
    } catch (e) {
      debugPrint('Microphone start failed: $e');
      _isRecording = false;
      await recorder.dispose();
      _recorder = null;
      return false;
    }
  }

  /// Auto-stop and the UI receive the same finalized recording.
  Future<String?> stopRecording() async {
    if (_stopping != null) return _stopping!;
    _meterTimer?.cancel();
    _maxTimer?.cancel();
    if (!_isRecording || _recorder == null) return _lastPath;
    _isRecording = false;
    final recorder = _recorder!;
    _stopping = () async {
      try {
        _lastPath = await recorder.stop();
        return _lastPath;
      } catch (e) {
        debugPrint('Microphone stop failed: $e');
        return null;
      } finally {
        await recorder.dispose();
        _recorder = null;
      }
    }();
    try {
      return await _stopping!;
    } finally {
      _stopping = null;
    }
  }

  Future<void> cancelRecording() async {
    ++_session;
    final path = await stopRecording();
    _lastPath = null;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }
}
