import 'dart:convert';
import 'dart:io';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['BILLING_COVERAGE_DATASET'];
  test(
    'scan the complete source snapshot and export the sample warning',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(path!);
      addTearDown(db.close);
      final database = DatabaseService.forTesting(db);
      final watch = Stopwatch()..start();
      final entries = await database.getBillingAudit();
      final stats = <String, Object?>{
        'connections': entries.length,
        'audit_load_ms': watch.elapsedMilliseconds,
        'missing_period_accounts': 0,
        'missing_period_accounts_with_stored_history': 0,
        'no_stored_history': 0,
        'possible_gaps_due_to_undated_bills': 0,
        'varying_rate_accounts': 0,
        'unknown_rate_accounts_with_gaps': 0,
        'short_fee_accounts': 0,
        'missing_issue_count': 0,
      };
      void increment(String name, [int amount = 1]) =>
          stats[name] = (stats[name] as int) + amount;
      for (final entry in entries) {
        final coverage = entry.coverage!;
        if (entry.billCount == 0) increment('no_stored_history');
        if (coverage.variableRates) increment('varying_rate_accounts');
        if (coverage.shortFees.isNotEmpty) increment('short_fee_accounts');
        if (coverage.missingBillCount == 0) continue;
        increment('missing_period_accounts');
        increment('missing_issue_count', coverage.missingBillCount);
        if (entry.billCount > 0) {
          increment('missing_period_accounts_with_stored_history');
        }
        if (coverage.undatedBills.isNotEmpty) {
          increment('possible_gaps_due_to_undated_bills');
        }
        if (coverage.monthlyWaterRate == null) {
          increment('unknown_rate_accounts_with_gaps');
        }
      }
      final sample = entries.singleWhere((e) => e.connectionNo == '36011016');
      expect(sample.waterFee, 1320000);
      expect(sample.coverage!.missingBillCount, 2);
      expect(sample.coverage!.estimatedMissingFee, 360000);
      expect(sample.coverage!.expectedWaterFee, 1680000);
      final settled = entries.singleWhere((e) => e.connectionNo == '31010284');
      expect(settled.coverage!.hasShortBills, false);
      expect(settled.waterReceived, 1680000);
      expect(settled.fineCollected, 48000);
      stats['sample_missing_periods'] = sample.coverage!.missingPeriods
          .map((p) => p.label)
          .toList();
      await File(
        'scratch/billing-coverage-dataset.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(stats));
      // ignore: avoid_print
      print(jsonEncode(stats));
      if (Platform.environment['CAPTURE_BILLING_COVERAGE'] == '1') {
        final pdf = await ExportService.instance.generateBillHistoryPdf(
          connectionNo: sample.connectionNo,
          consumerDetail: await database.getConsumerConnectionDetail(
            sample.connectionNo,
          ),
          bills: await database.getBillHistory(sample.connectionNo),
          audit: sample,
        );
        await File('scratch/billing-coverage-history.pdf').writeAsBytes(pdf);
      }
    },
    skip: path == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
