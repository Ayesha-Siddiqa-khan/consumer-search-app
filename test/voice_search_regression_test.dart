import 'dart:io';
import 'package:csv/csv.dart';
import 'dart:typed_data';
import 'package:consumer_search_engine/services/wav_audio.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:consumer_search_engine/services/audio_recorder_service.dart';
import 'package:consumer_search_engine/services/name_normalizer.dart';
import 'package:consumer_search_engine/services/smart_search_parser.dart';
import 'package:consumer_search_engine/services/voice_vocabulary.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeRecorder implements AudioRecorder {
  int stops = 0;
  Completer<String?>? stopGate;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {}
  @override
  Future<String?> stop() async {
    stops++;
    return stopGate?.future ?? 'test.wav';
  }

  @override
  Future<void> dispose() async {}
  @override
  Future<Amplitude> getAmplitude() async => Amplitude(current: -65, max: -65);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('digital silence after speech triggers automatic stop', () {
    final detector = SpeechEndpointDetector();
    detector.add(-35, const Duration(milliseconds: 100));
    detector.add(-35, const Duration(milliseconds: 200));
    expect(detector.add(-160, const Duration(seconds: 4)), isTrue);
  });
  test(
    'English examples resolve to consumers in the shipped 27870-row register',
    () async {
      final rows = csv.decode(
        await File('assets/data/consumers.csv').readAsString(),
      );
      final header = rows.first.map((v) => v.toString()).toList();
      final nameIndex = header.indexOf('Consumer Name');
      final sectorIndex = header.indexOf('Sector');
      final names = rows.skip(1).where((r) => r.length > sectorIndex).toList();
      final sectors = names
          .map((r) => r[sectorIndex].toString())
          .toSet()
          .toList();
      expect(names.length, 27870);
      for (final phrase in [
        'Asif Ali Town',
        'Ghafoor Farooq Colony',
        'Gafoor Farooq Colony',
      ]) {
        final parsed = SmartSearchParser.parse(
          phrase,
          availableSectors: sectors,
        );
        expect(parsed.hasSector, isTrue);
        final variants = NameNormalizer.spellingVariants(parsed.cleanKeywords);
        final matches = names.where(
          (r) =>
              r[sectorIndex] == parsed.detectedSector &&
              variants.any(
                (v) => r[nameIndex].toString().toUpperCase().contains(v),
              ),
        );
        expect(matches, isNotEmpty, reason: phrase);
      }
    },
  );
  test(
    'WAV normalization preserves extra metadata and rejects silence/truncation',
    () {
      final bytes = Uint8List(60);
      final data = ByteData.sublistView(bytes);
      void tag(int offset, String value) =>
          bytes.setRange(offset, offset + 4, value.codeUnits);
      tag(0, 'RIFF');
      data.setUint32(4, 52, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      data.setUint32(16, 16, Endian.little);
      data.setUint16(20, 1, Endian.little);
      data.setUint16(22, 1, Endian.little);
      data.setUint32(24, 16000, Endian.little);
      data.setUint32(28, 32000, Endian.little);
      data.setUint16(32, 2, Endian.little);
      data.setUint16(34, 16, Endian.little);
      tag(36, 'JUNK');
      data.setUint32(40, 4, Endian.little);
      tag(44, 'KEEP');
      tag(48, 'data');
      data.setUint32(52, 4, Endian.little);
      expect(WavAudio.prepare(bytes), isFalse);
      data.setInt16(56, 1000, Endian.little);
      data.setInt16(58, -1000, Endian.little);
      final header = bytes.sublist(0, 56);
      expect(WavAudio.prepare(bytes), isTrue);
      expect(bytes.sublist(0, 56), header);
      expect(data.getInt16(56, Endian.little), 10000);
      expect(data.getInt16(58, Endian.little), -10000);
      data.setUint32(52, 1000, Endian.little);
      expect(() => WavAudio.prepare(bytes), throwsFormatException);
    },
  );
  test('auto-stop followed by UI stop preserves finalized path', () async {
    final recorder = FakeRecorder();
    final service = AudioRecorderService.forTesting(recorder);
    expect(await service.startRecording(), isTrue);
    expect(await service.stopRecording(), 'test.wav');
    expect(await service.stopRecording(), 'test.wav');
    expect(recorder.stops, 1);
  });
  test('concurrent stop calls share one finalization', () async {
    final recorder = FakeRecorder()..stopGate = Completer<String?>();
    final service = AudioRecorderService.forTesting(recorder);
    await service.startRecording();
    final first = service.stopRecording();
    final second = service.stopRecording();
    recorder.stopGate!.complete('complete.wav');
    expect(await first, 'complete.wav');
    expect(await second, 'complete.wav');
    expect(recorder.stops, 1);
  });
  test('quiet speech and natural pauses do not stop recording', () {
    final detector = SpeechEndpointDetector();
    for (var ms = 0; ms < 8000; ms += 100) {
      final db = ms >= 2000 && ms < 4200 ? -70.0 : -44.0;
      expect(detector.add(db, Duration(milliseconds: ms)), isFalse);
    }
    expect(detector.add(-70, const Duration(milliseconds: 10600)), isFalse);
    expect(detector.add(-70, const Duration(milliseconds: 10700)), isTrue);
  });
  test('invalid meter values and silence never establish speech', () {
    final detector = SpeechEndpointDetector();
    for (final db in [-80.0, double.nan, double.negativeInfinity, -160.0]) {
      expect(detector.add(db, const Duration(seconds: 20)), isFalse);
    }
    expect(detector.hasSpeech, isFalse);
  });
  test('English name and full sector examples', () {
    final asif = SmartSearchParser.parse(
      'Asif Ali Town',
      availableSectors: ['Ali Town'],
    );
    expect(asif.cleanKeywords, 'ASIF');
    expect(asif.detectedSector, 'Ali Town');
    final ghafoor = SmartSearchParser.parse(
      'Ghafoor Farooq Colony',
      availableSectors: ['Farooq Colony'],
    );
    expect(ghafoor.cleanKeywords, 'GHAFOOR');
    expect(ghafoor.detectedSector, 'Farooq Colony');
    expect(NameNormalizer.normalize('SAQEB'), 'SAQEB');
  });
  test('database aliases cannot leak between imports', () {
    expect(
      SmartSearchParser.parse(
        'ASIF CUSTOM TOWN',
        availableSectors: ['Custom Town'],
      ).detectedSector,
      'Custom Town',
    );
    expect(
      SmartSearchParser.parse(
        'ASIF CUSTOM TOWN',
        availableSectors: ['Ali Town'],
      ).hasSector,
      isFalse,
    );
    expect(
      SmartSearchParser.parse(
        'ASIF ALI TOWN',
        availableSectors: ['Farooq Colony'],
      ).hasSector,
      isFalse,
    );
  });
  test('longer sectors and locality phrases win', () {
    final parsed = SmartSearchParser.parse(
      'ASIF NEW SATELLITE TOWN',
      availableSectors: ['Satellite Town', 'New Satellite Town'],
    );
    expect(parsed.detectedSector, 'New Satellite Town');
    expect(parsed.cleanKeywords, 'ASIF');
    final locality = SmartSearchParser.parse(
      'ASIF WARIS COLONY ZONE B',
      availableSectors: ['Waris Colony'],
      availableLocalities: ['WARIS COLONY Zone B'],
    );
    expect(locality.detectedLocality, 'WARIS COLONY Zone B');
    expect(locality.cleanKeywords, 'ASIF');
  });
  test('vocabulary uses real spelling and refuses ambiguous consonants', () {
    expect(VoiceVocabulary(['SAQIB']).resolve('SAQEB'), 'SAQIB');
    expect(VoiceVocabulary(['ISMAEEL']).resolve('Ismaiel'), 'ISMAEEL');
    expect(VoiceVocabulary(['SAQIB', 'SAKIB']).resolve('SAQEB'), 'SAQEB');
  });
  test(
    'saved corrections and spelling variants search actual database rows',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE consumers (id INTEGER PRIMARY KEY, sr_no INTEGER, consumer_name TEXT, sector TEXT)',
      );
      for (final name in ['GHAFOOR', 'GAFOOR', 'GAFUR']) {
        await db.insert('consumers', {
          'consumer_name': name,
          'sector': 'Farooq Colony',
          'sr_no': 1,
        });
      }
      await db.insert('consumers', {
        'consumer_name': 'GAFOOR',
        'sector': 'Ali Town',
        'sr_no': 2,
      });
      final service = DatabaseService.forTesting(db);
      await service.rememberVoiceCorrection('Gafoor', 'GAFOOR Farooq Colony');
      expect(
        await service.getVoiceCorrection('Gafoor'),
        'GAFOOR Farooq Colony',
      );
      final result = await service.searchConsumers(
        query: 'GHAFOOR',
        searchBy: 'consumer_name',
        sector: 'Farooq Colony',
        voiceNameSearch: true,
      );
      expect(result.totalCount, 3);
    },
  );
}
