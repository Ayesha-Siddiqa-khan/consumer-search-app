import 'dart:convert';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

Map<String, Object?> bill(
  String id,
  String period,
  int water, {
  int? receipt,
}) => BillHistory(
  connectionNo: 'A',
  billNo: id,
  billType: 'Regular',
  billingPeriod: period,
  waterFee: '$water',
  totalBill: '$water',
  amountReceived: '${receipt ?? water}',
  status: 'Paid',
).toMap();

BillingAuditEntry audit(List<Map<String, Object?>> bills) => buildBillingAudit(
  consumers: [
    {'connection_no': 'A'},
  ],
  bills: bills,
  asOf: DateTime(2026, 10, 22),
).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('newer half-year bills replace a fully covered annual entry once', () {
    final source = [
      bill('1', '01/07/2024 - 30/06/2025', 4800),
      bill('2', '01/07/2024 - 31/12/2024', 2400),
      bill('3', '01/01/2025 - 30/06/2025', 2400),
    ];
    final before = jsonEncode(source);
    final result = audit(source);
    expect(result.billCount, 2);
    expect(result.waterFee, 480000);
    expect(result.waterReceived, 480000);
    expect(result.received, 480000);
    expect(result.excludedBillNumbers, ['1']);
    expect(result.result, 'No water balance');
    expect(jsonEncode(source), before);
    final decoded = csv.decode(
      ExportService.billingAuditCsv([result]).replaceFirst('\ufeff', ''),
    );
    expect(decoded.first.toSet().length, decoded.first.length);
    expect(
      decoded[1][decoded.first.indexOf('Older Overlapping Bills Excluded')]
          .toString(),
      '1',
    );
  });

  test(
    'newer period entries replace the older overlapping row as requested',
    () {
      final result = audit([
        bill('1', '01/07/2024 - 30/06/2025', 4800),
        bill('2', '01/07/2024 - 31/12/2024', 2400),
      ]);
      expect(result.excludedBillNumbers, ['1']);
      expect(result.waterFee, 240000);
      expect(result.waterReceived, 240000);
      expect(result.result, 'No water balance');
    },
  );

  test(
    'an advance counts once; applied credit and spare credit stay separate',
    () {
      final initial = bill('1', '01/07/2023 - 31/12/2023', 2400, receipt: 6300);
      final applied = bill('2', '01/01/2024 - 30/06/2024', 2400)
        ..addAll({
          'arrears': '-3900',
          'total_bill': '-1500',
          'after_due_date': '-1500',
        });
      final result = audit([initial, applied]);
      expect(result.received, 870000);
      expect(result.advanceApplied, 240000);
      expect(result.cashReceived, 630000);
      expect(result.advanceBalance, 150000);
      expect(result.waterReceived, 480000);
      expect(result.payableBalance, 0);
      expect(result.result, 'No water balance');
    },
  );

  test(
    'partial-credit cash and cash plus fine are not mistaken for a transfer',
    () {
      for (final receipt in [1600, 1840, 2400, 2640]) {
        final source = [
          bill('1', '01/07/2023 - 31/12/2023', 2400, receipt: 3200),
          bill('2', '01/01/2024 - 30/06/2024', 2400, receipt: receipt)..addAll({
            'arrears': '-800',
            'total_bill': '1600',
            'fine': '240',
            'after_due_date': '1840',
          }),
        ];
        final result = audit(source);
        expect(result.advanceApplied, receipt >= 2400 ? 80000 : 0);
        expect(
          result.fineCollected,
          [1840, 2640].contains(receipt) ? 24000 : 0,
        );
        expect(result.waterReceived, 480000);
        expect(result.payableBalance, 0);
      }
    },
  );

  test(
    'authoritative history wins over rejected old-number daily receipts',
    () async {
      final db = await fixture(inMemoryDatabasePath);
      addTearDown(db.close);
      final service = DatabaseService.forTesting(db);
      await service.getBillHistoryCount();
      for (final cid in ['A', 'B']) {
        await db.insert('consumers', {
          'connection_no': cid,
          'consumer_name': 'REGISTER',
        });
        await db.insert('bill_history', {
          ...bill('2', '01/07/2026 - 31/12/2026', 2400),
          'connection_no': cid,
        });
        await db.insert('bill_import_state', {
          'connection_no': cid,
          'bill_no': '2',
          'kind': cid == 'A' ? 'history' : 'daily',
          'issues':
              'History name differs from consumer master; identity not reassigned; Invalid source due_date',
        });
        await db.insert('bill_history_quarantine', {
          'connection_no': cid,
          'bill_no': '1',
          'source': 'daily.csv',
          'reason':
              'Daily update refers to superseded bill number; receipt allocation needs review',
          'row_json': jsonEncode({'amount_received': '2640'}),
        });
      }
      final before = await db.query('bill_history');
      final result = await service.getBillingAudit();
      final trusted = result.singleWhere((e) => e.connectionNo == 'A');
      expect(trusted.result, 'No water balance');
      expect(trusted.waterReceived, 240000);
      expect(trusted.reviewReasons, isEmpty);
      expect(
        result.singleWhere((e) => e.connectionNo == 'B').result,
        'Needs review',
      );
      expect(await db.query('bill_history'), before);
      expect(await db.query('bill_history_quarantine'), hasLength(2));
    },
  );
}
