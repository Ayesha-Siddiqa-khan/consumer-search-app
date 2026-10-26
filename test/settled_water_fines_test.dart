import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

Map<String, Object?> row(
  String number,
  String period,
  int fee,
  int arrears,
  int total,
  int fine,
  int receipt,
  String status,
) => BillHistory(
  connectionNo: '31010284',
  billNo: number,
  billType: 'Regular',
  billingPeriod: period,
  waterFee: '$fee',
  arrears: '$arrears',
  totalBill: '$total',
  fine: '$fine',
  afterDueDate: '${total + fine}',
  amountReceived: '$receipt',
  status: status,
).toMap();

BillingAuditEntry audit(List<Map<String, Object?>> bills) => buildBillingAudit(
  consumers: [
    {'connection_no': '31010284'},
  ],
  bills: bills,
  asOf: DateTime(2026, 10, 22),
).single;

List<Map<String, Object?>> monthlyChain({
  required int augustArrears,
  required int septemberArrears,
  required int recoveredArrears,
}) => [
  row('1', '01/07/2025 - 31/07/2025', 400, 0, 400, 40, 0, 'Expired'),
  row(
    '2',
    '01/08/2025 - 31/08/2025',
    400,
    augustArrears,
    400 + augustArrears,
    40,
    0,
    'Expired',
  ),
  row(
    '3',
    '01/09/2025 - 30/09/2025',
    400,
    septemberArrears,
    400 + septemberArrears,
    40,
    0,
    'Expired',
  ),
  row(
    '4',
    '01/10/2025 - 31/12/2025',
    1200,
    recoveredArrears,
    1200 + recoveredArrears,
    0,
    1200 + recoveredArrears,
    'Paid',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    '31010284 separates both Rs 240 fines and respects waived monthly fines',
    () async {
      final bills = [
        row(
          '6905102',
          '01/07/2026 - 31/12/2026',
          2400,
          0,
          2400,
          240,
          2640,
          'Paid',
        ),
        row(
          '6124145',
          '01/01/2026 - 30/06/2026',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ),
        row(
          '5389627',
          '01/10/2025 - 31/12/2025',
          1200,
          1200,
          2400,
          0,
          2400,
          'Paid',
        ),
        row(
          '5234829',
          '01/09/2025 - 30/09/2025',
          400,
          840,
          1240,
          40,
          0,
          'Expired',
        ),
        row(
          '5057542',
          '01/08/2025 - 31/08/2025',
          400,
          400,
          800,
          40,
          0,
          'Expired',
        ),
        row(
          '4966935',
          '01/07/2025 - 31/07/2025',
          400,
          0,
          400,
          40,
          0,
          'Expired',
        ),
        row(
          '4268382',
          '01/01/2025 - 30/06/2025',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ),
        row(
          '3489994',
          '01/07/2024 - 31/12/2024',
          2400,
          240,
          2640,
          240,
          2640,
          'Paid',
        ),
        row(
          '3017466',
          '01/01/2024 - 30/06/2024',
          2400,
          0,
          2400,
          240,
          2400,
          'Paid',
        ),
        row(
          '2663321',
          '01/07/2023 - 31/12/2023',
          2400,
          0,
          2400,
          0,
          2400,
          'Paid',
        ),
      ];
      final result = audit(bills);
      expect(result.waterFee, 1680000);
      expect(result.received, 1728000);
      expect(result.fineCollected, 48000);
      expect(result.waterReceived, 1680000);
      expect(result.difference, 0);
      expect(result.payableBalance, 0);
      expect(result.paidBillCount, 7);
      expect(result.expiredBillCount, 3);
      expect(result.allocationNeedsReview, false);
      expect(result.needsReview, false);
      expect(result.result, 'No water balance');

      final db = await fixture(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.insert('consumers', {'connection_no': '31010284'});
      for (final bill in bills) {
        await db.insert('bill_history', bill);
      }
      final before = await db.query('bill_history');
      final service = DatabaseService.forTesting(db);
      // The Audit list and History dialog must receive the same financial data.
      for (final entry in [
        (await service.getBillingAudit(billGroup: 'regular')).single,
        (await service.getBillingAudit(connectionNo: '31010284')).single,
      ]) {
        expect(entry.waterFee, result.waterFee);
        expect(entry.received, result.received);
        expect(entry.waterReceived, result.waterReceived);
        expect(entry.fineCollected, result.fineCollected);
        expect(entry.outstandingFine, 0);
        expect(entry.payableBalance, 0);
      }
      expect(await db.query('bill_history'), before);
    },
  );

  test('paid arrears with waived fines need no allocation review', () {
    final bills = [
      row('1', '01/07/2025 - 31/07/2025', 400, 0, 400, 40, 0, 'Expired'),
      row('2', '01/08/2025 - 31/08/2025', 400, 400, 800, 40, 0, 'Expired'),
      row('3', '01/09/2025 - 30/09/2025', 400, 800, 1200, 40, 1200, 'Paid'),
    ];
    for (final bill in bills) {
      bill['import_issues'] = 'Invalid source due_date';
    }
    final result = audit(bills);
    expect(result.waterFee, 120000);
    expect(result.waterReceived, 120000);
    expect(result.fineCollected, 0);
    expect(result.payableBalance, 0);
    expect(result.allocationNeedsReview, false);
    expect(result.needsReview, false);
    expect(result.result, 'No water balance');

    bills.last['import_issues'] =
        'Invalid source due_date; Invalid source water_fee';
    final conflicting = audit(bills);
    expect(conflicting.needsReview, true);
    expect(conflicting.result, 'Needs review');
    expect(
      conflicting.reviewReasons.join(),
      contains('Invalid source water_fee'),
    );
  });

  test('a balanced water total does not hide a short mixed payment', () {
    final bill = row(
      '1',
      '01/07/2026 - 31/12/2026',
      400,
      0,
      500,
      0,
      400,
      'Paid',
    )..['sanitation'] = '100';
    final result = audit([bill]);
    expect(result.waterFee, result.waterReceived);
    expect(result.allocationNeedsReview, true);
    expect(result.paidShortCount, 1);
    expect(result.result, 'Review allocation');
  });

  test('settled water clears historical short receipts with waived fines', () {
    final bills = [
      row('1', '01/07/2023 - 31/12/2023', 2400, 0, 2400, 240, 2400, 'Paid'),
      row('2', '01/01/2024 - 30/06/2024', 2400, 240, 2640, 240, 2400, 'Paid'),
    ];
    final result = audit(bills);
    expect(result.waterFee, 480000);
    expect(result.waterReceived, 480000);
    expect(result.fineCollected, 0);
    expect(result.paidShortCount, 1); // Preserve the source comparison.
    expect(result.payableBalance, 0);
    expect(result.result, 'No water balance');
    expect(result.needsReview, false);

    bills.last['amount_received'] = '2200';
    final underpaid = audit(bills);
    expect(underpaid.payableBalance, 20000);
    expect(underpaid.allocationNeedsReview, true);
    expect(underpaid.needsReview, true);

    bills.last['amount_received'] = '2400';
    bills.last['import_issues'] = 'Invalid source water_fee';
    expect(audit(bills).result, 'Needs review');
  });

  test('missing fine date does not hide the confirmed water balance', () {
    final bill = row(
      '1',
      '01/07/2026 - 31/12/2026',
      400,
      0,
      400,
      40,
      0,
      'Un-Paid',
    )..['import_issues'] = 'Invalid source due_date';
    final result = audit([bill]);
    expect(result.payableBalance, 40000);
    expect(result.outstandingFine, isNull);
    expect(result.needsReview, false);
    expect(result.result, 'Water balance due');
  });

  test('a balanced receipt does not hide an inconsistent arrears total', () {
    final result = audit([
      row('1', '01/07/2026 - 31/12/2026', 400, 100, 400, 0, 400, 'Paid'),
    ]);
    expect(result.waterFee, result.waterReceived);
    expect(result.allocationNeedsReview, true);
    expect(
      result.reviewReasons.join(),
      contains('does not match current charges and arrears'),
    );
  });

  test(
    'a previously partly collected fine only contributes its unpaid remainder',
    () {
      final result = audit([
        row('1', '01/01/2024 - 30/06/2024', 2400, 0, 2400, 240, 2500, 'Paid'),
        row('2', '01/07/2024 - 31/12/2024', 2400, 140, 2540, 240, 2540, 'Paid'),
      ]);
      expect(result.fineCollected, 24000);
      expect(result.waterReceived, 480000);
      expect(result.payableBalance, 0);
    },
  );

  test(
    'fines passed through several expired bills are collected only once',
    () {
      final result = audit(
        monthlyChain(
          augustArrears: 440,
          septemberArrears: 880,
          recoveredArrears: 1320,
        ),
      );
      expect(result.received, 252000);
      expect(result.waterFee, 240000);
      expect(result.fineCollected, 12000);
      expect(result.waterReceived, 240000);
      expect(result.payableBalance, 0);
    },
  );

  test(
    'full and partial waivers never turn printed fines into collected money',
    () {
      final waived = audit(
        monthlyChain(
          augustArrears: 400,
          septemberArrears: 840,
          recoveredArrears: 1200,
        ),
      );
      expect(waived.fineCollected, 0);
      expect(waived.waterReceived, 240000);
      final partialWaiver = audit(
        monthlyChain(
          augustArrears: 400,
          septemberArrears: 840,
          recoveredArrears: 1240,
        ),
      );
      expect(partialWaiver.fineCollected, 4000);
      expect(partialWaiver.waterReceived, 240000);
    },
  );
}
