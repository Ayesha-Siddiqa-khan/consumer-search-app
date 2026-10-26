import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'name_normalizer.dart';
import 'smart_search_parser.dart';
import 'wav_audio.dart';

class WhisperTranscribeResult {
  final String rawText;
  final String normalizedText;
  final SmartSearchResult smartResult;

  const WhisperTranscribeResult({
    required this.rawText,
    required this.normalizedText,
    required this.smartResult,
  });
}

class WhisperService {
  static final WhisperService instance = WhisperService._internal();
  WhisperService._internal();
  String? lastError;

  /// English context for Pakistani proper names; this is not a translation task.
  static const String defaultPakistaniPrompt =
      'Consumer names and sectors: Asif, Ali, Aslam, Muhammad, Ghafoor, '
      'Riaz, Ismail, Farooq Colony, Ali Town.';

  static const List<String> _hallucinations = [
    'THANK YOU',
    'THANK YOU.',
    'THANK YOU VERY MUCH',
    'THANKS FOR WATCHING',
    'THANKS FOR WATCHING.',
    'PLEASE SUBSCRIBE',
    'SUBSCRIBE',
    'YOU',
    'BYE',
    'GOODBYE',
    'THE END',
    'BLANK_AUDIO',
    'NO AUDIO',
  ];

  /// Candidate directories where whisper-cli.exe and ggml-base.bin reside
  List<String> _getCandidateDirectories() {
    final dirs = <String>[];

    // 1. Next to running executable (Flutter Windows desktop app bundle)
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      dirs.add(p.join(exeDir, 'data', 'flutter_assets', 'assets', 'bin'));
      dirs.add(p.join(exeDir, 'assets', 'bin'));
      dirs.add(exeDir);
    } catch (_) {}

    // 2. Current working directory
    try {
      dirs.add(p.join(Directory.current.path, 'assets', 'bin'));
      dirs.add(
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'data',
          'flutter_assets',
          'assets',
          'bin',
        ),
      );
    } catch (_) {}

    return dirs;
  }

  /// Locate or extract the whisper-cli.exe executable
  Future<String?> getWhisperExePath() async {
    for (final dir in _getCandidateDirectories()) {
      final localPath = p.join(dir, 'whisper-cli.exe');
      if (await File(localPath).exists()) {
        debugPrint('WhisperService: Found whisper-cli.exe at $localPath');
        return localPath;
      }
    }

    // App support directory fallback
    try {
      final appDir = await getApplicationSupportDirectory();
      final appExePath = p.join(appDir.path, 'bin', 'whisper-cli.exe');
      if (await File(appExePath).exists()) {
        return appExePath;
      }
    } catch (_) {}

    return null;
  }

  /// Locate the whisper-stream.exe executable for real-time live streaming dictation
  Future<String?> getWhisperStreamExePath() async {
    for (final dir in _getCandidateDirectories()) {
      final localPath = p.join(dir, 'whisper-stream.exe');
      if (await File(localPath).exists()) {
        debugPrint('WhisperService: Found whisper-stream.exe at $localPath');
        return localPath;
      }
    }
    return null;
  }

  /// English recognition works with English-only or multilingual models.
  Future<String?> getModelPath() async {
    final candidateNames = [
      'ggml-base.en.bin',
      'ggml-base.bin',
      'ggml-small.en.bin',
      'ggml-small.bin',
      'ggml-tiny.en.bin',
      'ggml-tiny.bin',
    ];

    for (final name in candidateNames) {
      for (final dir in _getCandidateDirectories()) {
        final localModel = p.join(dir, name);
        if (await File(localModel).exists() &&
            (await File(localModel).length()) > 1000000) {
          debugPrint('WhisperService: Found model $name at $localModel');
          return localModel;
        }
      }
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      for (final name in candidateNames) {
        final appModel = p.join(appDir.path, 'bin', name);
        if (await File(appModel).exists()) {
          return appModel;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Transcribe a 16kHz mono WAV file using whisper-cli.exe
  Future<WhisperTranscribeResult?> transcribe({
    required String wavPath,
    String? prompt,
    List<String>? availableSectors,
  }) async {
    lastError = null;
    final wavFile = File(wavPath);
    if (!await wavFile.exists()) {
      debugPrint('WhisperService: WAV file does not exist: $wavPath');
      lastError = 'No recording was saved. Check the microphone and try again.';
      return null;
    }

    final whisperExe = await getWhisperExePath();
    final modelPath = await getModelPath();

    if (whisperExe == null || modelPath == null) {
      lastError =
          'Offline speech files are missing. Restore whisper-cli.exe and ggml-base.bin or ggml-base.en.bin in assets/bin.';
      debugPrint(
        'WhisperService: Missing whisper executable or model path (exe: $whisperExe, model: $modelPath)',
      );
      return null;
    }

    final absoluteWav = wavFile.absolute.path;
    final absoluteModel = File(modelPath).absolute.path;
    final whisperDir = p.dirname(whisperExe);
    final effectivePrompt = prompt ?? defaultPakistaniPrompt;
    final threads = Platform.numberOfProcessors.clamp(4, 8);

    debugPrint(
      'WhisperService: Running $whisperExe on $absoluteWav with model $absoluteModel (threads: $threads)',
    );

    Directory? outputDir;
    Process? process;
    try {
      if (await wavFile.length() <= 44) {
        lastError =
            'The recording is empty. Check the microphone and try again.';
        return null;
      }
      outputDir = await Directory.systemTemp.createTemp('consumer_whisper_');
      var inputPath = absoluteWav;
      if (p.extension(wavPath).toLowerCase() == '.wav') {
        final audio = await wavFile.readAsBytes();
        if (!WavAudio.prepare(audio)) {
          lastError =
              'The recording is silent. Check your microphone input and try again.';
          return null;
        }
        inputPath = p.join(outputDir.path, 'input.wav');
        await File(inputPath).writeAsBytes(audio, flush: true);
      }
      final outputBase = p.join(outputDir.path, 'transcript');
      process = await Process.start(whisperExe, [
        '-m', absoluteModel,
        '-f', inputPath,
        '--language', 'en',
        if (effectivePrompt.isNotEmpty) ...[
          '--prompt',
          effectivePrompt,
        ],
        '-nt', // no timestamps
        '-t', threads.toString(),
        '-otxt', // output text file
        '-of', outputBase,
      ], workingDirectory: whisperDir);
      // Drain both pipes before reading the final UTF-8 file. Bound hangs and
      // kill the actual child process on timeout instead of abandoning it.
      final stdoutFuture = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderrFuture = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 90),
      );
      await stdoutFuture;
      final stderr = await stderrFuture;
      if (exitCode != 0) {
        debugPrint('Whisper failed ($exitCode): $stderr');
        lastError =
            'Offline recognition failed (code $exitCode). Check the bundled model and Whisper files.';
        return null;
      }

      // Read output from generated .txt file or stdout
      String recognizedText = '';
      final expectedTxtFile = File('$outputBase.txt');
      if (await expectedTxtFile.exists()) {
        recognizedText = await expectedTxtFile.readAsString();
        try {
          await expectedTxtFile.delete();
        } catch (_) {}
      }

      // Clean brackets, timestamps, or whisper special tokens
      recognizedText = recognizedText
          .replaceAll(RegExp(r'\[.*?\]'), ' ')
          .trim();

      if (recognizedText.isEmpty) {
        lastError =
            'No clear speech was recognized. Move closer to the microphone and try again.';
        return null;
      }

      // Check and suppress hallucinated phrases like "Thank you", "Please subscribe", etc.
      final upperClean = recognizedText
          .toUpperCase()
          .replaceAll(RegExp(r'[.!?]'), '')
          .trim();
      for (final h in _hallucinations) {
        if (upperClean == h ||
            upperClean == h.replaceAll(RegExp(r'[^\w\s]'), '')) {
          debugPrint(
            'WhisperService: Suppressed Whisper hallucination: "$recognizedText"',
          );
          lastError =
              'No search name was recognized. Please say the name and sector again.';
          return null;
        }
      }

      debugPrint('WhisperService raw recognized: "$recognizedText"');

      // Normalize English spellings of Pakistani names
      final normalized = NameNormalizer.normalize(recognizedText);
      if (normalized.isEmpty) {
        lastError =
            'No clear name was recognized. Please say the name and sector again.';
        return null;
      }
      debugPrint('WhisperService normalized: "$normalized"');

      // Smart parse for sectors/localities
      final smartParsed = SmartSearchParser.parse(
        normalized,
        availableSectors: availableSectors,
      );

      return WhisperTranscribeResult(
        rawText: recognizedText,
        normalizedText: normalized,
        smartResult: smartParsed,
      );
    } on FormatException catch (e) {
      lastError = e.message;
      return null;
    } on TimeoutException {
      process?.kill();
      await process?.exitCode;
      lastError = 'Offline recognition took too long. Try a shorter phrase.';
      return null;
    } catch (e) {
      debugPrint('WhisperService execution error: $e');
      lastError =
          'Could not run offline recognition. Check the recording and bundled speech files.';
      return null;
    } finally {
      if (outputDir != null) {
        try {
          await outputDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
