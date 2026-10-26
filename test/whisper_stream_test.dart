import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'whisper-stream starts and emits output',
    () async {
      final exeDir = p.join(Directory.current.path, 'assets', 'bin');
      final streamExe = p.join(exeDir, 'whisper-stream.exe');
      final modelPath = p.join(exeDir, 'ggml-base.bin');

      expect(File(streamExe).existsSync(), isTrue);
      expect(File(modelPath).existsSync(), isTrue);

      final proc = await Process.start(streamExe, [
        '-m',
        modelPath,
        '--step',
        '1000',
        '--length',
        '3000',
        '-t',
        '4',
        '-l',
        'en',
        '-vth',
        '0.5',
      ], workingDirectory: exeDir);

      final lines = <String>[];
      final completer = Completer<void>();

      // Listen to stdout
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final clean = line
                .replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '')
                .replaceAll('[BLANK_AUDIO]', '')
                .trim();
            if (clean.isNotEmpty) {
              lines.add(clean);
              debugPrint('Clean stdout: "$clean"');
            }
          });

      // Listen to stderr
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((err) {
            if (err.contains('SDL_main: processing')) {
              debugPrint('Whisper stream started listening successfully!');
              if (!completer.isCompleted) completer.complete();
            }
          });

      // Wait up to 5 seconds for it to start listening
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('Timeout waiting for start line');
        },
      );

      // Allow 2 seconds for stdout to deliver tokens
      await Future.delayed(const Duration(seconds: 2));

      proc.kill();
      await proc.exitCode;
      expect(lines, isNotEmpty);
      expect(lines.first, contains('Start speaking'));
    },
    skip: Platform.environment['RUN_MIC_TESTS'] != '1'
        ? 'Opt-in hardware test: set RUN_MIC_TESTS=1 to open the microphone.'
        : false,
  );
}
