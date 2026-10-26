import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumer_search_engine/services/whisper_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WhisperService locates binary and model', () async {
    final exe = await WhisperService.instance.getWhisperExePath();
    final model = await WhisperService.instance.getModelPath();

    expect(exe, isNotNull);
    expect(File(exe!).existsSync(), isTrue);

    expect(model, isNotNull);
    expect(File(model!).existsSync(), isTrue);
    expect(model, endsWith('ggml-base.bin'));
  });

  test(
    'Default English recognition preserves a searchable name and full sector',
    () async {
      final audioFile = File('scratch/test_asif.wav');
      expect(await audioFile.exists(), isTrue);
      final before = await audioFile.readAsBytes();
      final result = await WhisperService.instance.transcribe(
        wavPath: audioFile.path,
        availableSectors: ['Ali Town'],
      );
      expect(result, isNotNull, reason: WhisperService.instance.lastError);
      expect(
        RegExp(r'^[A-Za-z0-9\s.,!?-]+$').hasMatch(result!.rawText),
        isTrue,
      );
      expect(result.smartResult.cleanKeywords, 'ASIF');
      expect(result.smartResult.detectedSector, 'Ali Town');
      expect(await audioFile.readAsBytes(), before);
    },
    timeout: const Timeout(Duration(seconds: 100)),
  );

  test(
    'WhisperService transcribes audio file and parses name + sector',
    () async {
      final audioFile = File('scratch/test_speech.mp3');
      if (!audioFile.existsSync()) {
        return;
      }

      final result = await WhisperService.instance.transcribe(
        wavPath: audioFile.path,
      );

      expect(result, isNotNull);
      expect(result!.rawText.toUpperCase(), contains('ASLAM'));
      expect(result.smartResult.hasSector, isTrue);
      expect(result.smartResult.detectedSector, equals('Ali Town'));
      expect(result.smartResult.cleanKeywords, contains('ASLAM'));
    },
  );
}
