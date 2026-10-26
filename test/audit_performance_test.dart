import 'dart:async';
import 'dart:io';

import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:csv/csv.dart' as csv_codec;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Opt-in benchmark on a disposable database copy, never the user's live database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['AUDIT_BENCHMARK_DB'];
  test(
    'full dataset audit benchmark and financial parity',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(path!);
      addTearDown(db.close);
      final service = DatabaseService.forTesting(db);
      for (final group in ['regular', 'all']) {
        var longestGap = Duration.zero;
        var lastTick = DateTime.now();
        final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
          final now = DateTime.now();
          final gap = now.difference(lastTick);
          if (gap > longestGap) longestGap = gap;
          lastTick = now;
        });
        addTearDown(timer.cancel);
        final watch = Stopwatch()..start();
        final entries = await service.getBillingAudit(billGroup: group);
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        timer.cancel();
        final csv = ExportService.billingAuditCsv(entries);
        final baseline = File('scratch/audit-performance-$group.csv');
        if (Platform.environment['AUDIT_SAVE_BASELINE'] == '1') {
          await baseline.writeAsString(csv);
        } else {
          final old = csv_codec.csv.decode(await baseline.readAsString());
          final current = csv_codec.csv.decode(csv.replaceFirst('\ufeff', ''));
          expect(current.length, old.length);
          final labels = old.first;
          final resultColumn = labels.indexOf('Result');
          final reasonColumn = labels.indexOf('Review Reasons');
          final changed = <String, int>{};
          for (var i = 1; i < current.length; i++) {
            for (var column = 0; column < labels.length; column++) {
              if (column == resultColumn || column == reasonColumn) continue;
              expect(
                current[i][column],
                old[i][column],
                reason: '$group row $i ${labels[column]}',
              );
            }
            if (current[i][resultColumn] != old[i][resultColumn]) {
              expect(old[i][resultColumn], 'Review allocation');
              expect(
                current[i][resultColumn],
                anyOf('No water balance', 'Needs review'),
              );
              expect(current[i][labels.indexOf('Water Balance')], '0.00');
              final result = '${current[i][resultColumn]}';
              changed.update(result, (n) => n + 1, ifAbsent: () => 1);
            }
          }
          expect(longestGap, lessThan(const Duration(seconds: 1)));
          await File(
            'scratch/audit-performance-$group-after.csv',
          ).writeAsString(csv);
          // ignore: avoid_print
          print('Updated settled-account classifications: $changed');
        }
        // ignore: avoid_print
        print(
          '$group: ${entries.length} entries, ${watch.elapsedMilliseconds} ms, '
          'largest UI event-loop gap ${longestGap.inMilliseconds} ms',
        );
      }
    },
    skip: path == null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
