import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'name_normalizer.dart';
import 'whisper_service.dart';
import 'audio_recorder_service.dart';

/// Service for real-time streaming speech-to-text directly into the search bar.
/// Uses bundled 'whisper-stream.exe' with fallback to 'AudioRecorderService' + 'whisper-cli.exe'.
class WhisperStreamService {
  static final WhisperStreamService instance = WhisperStreamService._internal();
  WhisperStreamService._internal();

  Process? _process;
  bool _isStreaming = false;
  bool _usingFallbackRecorder = false;
  String _cumulativeText = '';
  String _currentChunk = '';
  int _consecutiveBlanks = 0;
  bool _hasDetectedSpeech = false;

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  bool get isStreaming => _isStreaming;
  bool get usingFallbackRecorder => _usingFallbackRecorder;

  /// Start live streaming speech-to-text.
  /// Text chunks are emitted live via [onLiveText].
  /// When silence is detected after speech, [onAutoStop] is triggered.
  Future<bool> startStreaming({
    required ValueChanged<String> onLiveText,
    required VoidCallback onAutoStop,
  }) async {
    if (_isStreaming) {
      await stopStreaming();
    }

    _isStreaming = true;
    _usingFallbackRecorder = false;
    _cumulativeText = '';
    _currentChunk = '';
    _consecutiveBlanks = 0;
    _hasDetectedSpeech = false;

    // 1. Check if whisper-stream.exe and ggml-base.bin are available
    final streamExePath = await WhisperService.instance.getWhisperStreamExePath();
    final modelPath = await WhisperService.instance.getModelPath();

    if (streamExePath != null &&
        modelPath != null &&
        File(streamExePath).existsSync() &&
        File(modelPath).existsSync()) {
      try {
        final exeDir = p.dirname(streamExePath);

        debugPrint('WhisperStreamService: Launching whisper-stream.exe...');
        _process = await Process.start(
          streamExePath,
          [
            '-m', File(modelPath).absolute.path,
            '--step', '1000',
            '--length', '3500',
            '--keep', '200',
            '-t', '4',
            '-l', 'en',
            '-vth', '0.5',
          ],
          workingDirectory: exeDir,
        );

        // Listen to stdout for decoded speech
        _stdoutSub = _process!.stdout
            .transform(utf8.decoder)
            .listen((chunk) {
          _handleStdoutChunk(chunk, onLiveText, onAutoStop);
        });

        // Listen to stderr for initialization check
        _stderrSub = _process!.stderr
            .transform(utf8.decoder)
            .listen((err) {
          if (kDebugMode && err.contains('error')) {
            debugPrint('WhisperStream stderr: $err');
          }
        });

        _process!.exitCode.then((code) {
          debugPrint('WhisperStreamService process exited with code $code');
          if (_isStreaming) {
            _isStreaming = false;
          }
        });

        return true;
      } catch (e) {
        debugPrint('WhisperStreamService failed to start whisper-stream.exe: $e. Falling back to recorder...');
      }
    }

    // 2. Fallback to AudioRecorderService if stream executable fails
    debugPrint('WhisperStreamService: Using AudioRecorderService fallback.');
    _usingFallbackRecorder = true;
    final ok = await AudioRecorderService.instance.startRecording(
      onAutoStop: onAutoStop,
    );

    if (!ok) {
      _isStreaming = false;
      return false;
    }

    return true;
  }

  void _handleStdoutChunk(
    String raw,
    ValueChanged<String> onLiveText,
    VoidCallback onAutoStop,
  ) {
    // Split by carriage return or newline
    final parts = raw.split(RegExp(r'[\r\n]+'));

    for (final part in parts) {
      // Strip ANSI escape codes (e.g. \x1b[2K)
      final clean = part
          .replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '')
          .trim();

      if (clean.isEmpty) continue;

      if (clean.contains('[Start speaking]')) {
        continue;
      }

      if (clean.contains('[BLANK_AUDIO]')) {
        if (_hasDetectedSpeech) {
          _consecutiveBlanks++;
          // 2 consecutive blank chunks after speech ~= 2.5 - 3s of silence
          if (_consecutiveBlanks >= 2) {
            debugPrint('WhisperStreamService: Silence detected after speech, triggering auto-stop.');
            onAutoStop();
            return;
          }
        }
        continue;
      }

      // Filter other tags like [Music]
      final speechText = clean.replaceAll(RegExp(r'\[.*?\]'), '').trim();
      if (speechText.isNotEmpty) {
        _consecutiveBlanks = 0;
        _hasDetectedSpeech = true;
        _currentChunk = speechText;

        final full = _formatCombinedText(_cumulativeText, _currentChunk);
        debugPrint('WhisperStream live text: "$full"');
        onLiveText(full);
      }
    }
  }

  String _formatCombinedText(String cumulative, String current) {
    if (cumulative.isEmpty) return current;
    if (current.isEmpty) return cumulative;
    return '$cumulative $current';
  }

  /// Stop streaming and return the final processed text
  Future<String> stopStreaming({List<String> availableSectors = const []}) async {
    _isStreaming = false;

    // 1. If using whisper-stream.exe
    if (_process != null) {
      try {
        await _stdoutSub?.cancel();
        await _stderrSub?.cancel();
        _process?.kill();
        await _process?.exitCode;
      } catch (_) {}
      _process = null;

      final rawFinal = _formatCombinedText(_cumulativeText, _currentChunk).trim();
      if (rawFinal.isEmpty) return '';

      // Normalize Pakistani transliterations
      final normalized = NameNormalizer.normalize(rawFinal);
      return normalized;
    }

    // 2. If using fallback recorder
    if (_usingFallbackRecorder) {
      _usingFallbackRecorder = false;
      final wavPath = await AudioRecorderService.instance.stopRecording();
      if (wavPath != null && File(wavPath).existsSync()) {
        final result = await WhisperService.instance.transcribe(
          wavPath: wavPath,
          availableSectors: availableSectors,
        );
        if (result != null) {
          return result.normalizedText;
        }
      }
    }

    return '';
  }

  /// Force kill any running process
  void dispose() {
    _isStreaming = false;
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _process?.kill();
    _process = null;
  }
}
