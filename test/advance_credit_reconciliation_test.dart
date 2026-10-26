import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/bill_import_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/models/history_bill_balance.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

Map<String, Object?> creditBill({
  int arrears = -2400,
  int total = 0,
  int fine = 0,
  int receipt = 2400,
  String status = 'Paid',
}) => BillHistory(
  connectionNo: '31010026',
  billNo: '3017299',
  billType: 'Regular',
  billingPeriod: '01/01/2024 - 30/06/2024',
  waterFee: '2400',
  arrears: '$arrears',
  totalBill: '$total',
  fine: '$fine',
  afterDueDate: '${total + fine}',
  amountReceived: '$receipt',
  dueDate: '15/02/2024',
  status: status,
).toMap();

BillingAuditEntry audit(List<Map<String, Object?>> bills) => buildBillingAudit(
  consumers: [
    {'connection_no': '31010026'},
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

  test(
    '31010026 accepts its advance credit without changing source receipts',
    () async {
      final bills = <Map<String, Object?>>[];
      const data = [
        [
          '6904970',
          '01/07/2026 - 31/12/2026',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ],
        [
          '6124002',
          '01/01/2026 - 30/06/2026',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ],
        [
          '5389729',
          '01/10/2025 - 31/12/2025',
          1200,
          1280,
          2480,
          0,
          0,
          'Expired',
        ],
        [
          '5234683',
          '01/09/2025 - 30/09/2025',
          400,
          840,
          1240,
          40,
          0,
          'Expired',
        ],
        ['5057394', '01/08/2025 - 31/08/2025', 400, 400, 800, 40, 0, 'Expired'],
        ['4967006', '01/07/2025 - 31/07/2025', 400, 0, 400, 40, 0, 'Expired'],
        [
          '4277838',
          '01/01/2025 - 30/06/2025',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ],
        [
          '3489831',
          '01/07/2024 - 31/12/2024',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ],
        ['3017299', '01/01/2024 - 30/06/2024', 2400, -2400, 0, 0, 2400, 'Paid'],
        ['2663113', '01/07/2023 - 31/12/2023', 2400, 0, 2400, 0, 4800, 'Paid'],
      ];
      for (final r in data) {
        bills.add(
          BillHistory(
            connectionNo: '31010026',
            billNo: '${r[0]}',
            billType: 'Regular',
            billingPeriod: '${r[1]}',
            waterFee: '${r[2]}',
            arrears: '${r[3]}',
            totalBill: '${r[4]}',
            fine: '${r[5]}',
            amountReceived: '${r[6]}',
            status: '${r[7]}',
            afterDueDate: '${(r[4] as int) + (r[5] as int)}',
          ).toMap(),
        );
      }
      bills[8]['import_issues'] =
          '$negativeCreditReviewIssue; Invalid source due_date';
      final result = audit(bills);
      expect(result.waterFee, 1680000);
      expect(result.received, 1680000);
      expect(result.waterReceived, 1440000);
      expect(result.advanceApplied, 240000);
      expect(result.cashReceived, 1440000);
      expect(result.fineCollected, 0);
      expect(result.payableBalance, 240000);
      expect(result.result, 'Water balance due');
      expect(result.reviewReasons, isEmpty);

      final db = await fixture(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.insert('consumers', {'connection_no': '31010026'});
      for (final bill in bills) {
        await db.insert('bill_history', {...bill}..remove('import_issues'));
      }
      final before = await db.query('bill_history');
      final service = DatabaseService.forTesting(db);
      await service.getBillHistoryCount();
      await db.insert('bill_import_state', {
        'connection_no': '31010026',
        'bill_no': '3017299',
        'as_of': '2026-10-21',
        'source': 'history.csv',
        'issues': '$negativeCreditReviewIssue; Invalid source due_date',
      });
      for (final entry in [
        (await service.getBillingAudit(billGroup: 'regular')).single,
        (await service.getBillingAudit(connectionNo: '31010026')).single,
      ]) {
        expect(entry.waterReceived, 1440000);
        expect(entry.fineCollected, 0);
        expect(entry.payableBalance, 240000);
        expect(entry.result, 'Water balance due');
      }
      expect(await db.query('bill_history'), before);
    },
  );

  test('remaining credit is valid and adds no invented receipt or fine', () {
    final bill = creditBill(arrears: -3900, total: -1500);
    expect(hasConsistentAdvanceCredit(bill), true);
    final advance = creditBill(arrears: 0, total: 2400, receipt: 6300)
      ..['bill_no'] = '2663113'
      ..['billing_period'] = '01/07/2023 - 31/12/2023';
    final result = audit([advance, bill]);
    expect(result.waterReceived, 480000);
    expect(result.received, 870000);
    expect(result.cashReceived, 630000);
    expect(result.advanceApplied, 240000);
    expect(result.advanceBalance, 150000);
    expect(result.fineCollected, 0);
    expect(result.payableBalance, 0);
    expect(result.result, 'No water balance');
    final unpaid = BillHistory.fromMap({
      ...bill,
      'status': 'Un-Paid',
      'amount_received': '0',
    });
    expect(latestHistoryBillBalance([unpaid], asOf: DateTime(2026)).amount, 0);
  });

  test(
    'partial advance credit leaves the correct bill and unpaid late fine',
    () {
      final bill = BillHistory.fromMap(
        creditBill(
          arrears: -2160,
          total: 240,
          fine: 240,
          receipt: 0,
          status: 'Un-Paid',
        ),
      );
      expect(
        latestHistoryBillBalance([bill], asOf: DateTime(2024, 2, 15)).amount,
        24000,
      );
      final late = latestHistoryBillBalance([
        bill,
      ], asOf: DateTime(2024, 2, 16));
      expect(late.amount, 48000);
      expect(late.outstandingFine, 24000);
    },
  );

  test('inconsistent credits and negative receipts remain flagged', () {
    for (final bill in [
      creditBill(arrears: -2400, total: 100),
      creditBill()..['amount_received'] = '-2400',
      creditBill()..['water_fee'] = '-2400',
    ]) {
      final result = audit([bill]);
      expect(result.needsReview, true);
      expect(result.payableBalance, isNull);
      expect(result.result, 'Needs review');
    }
  });
}
