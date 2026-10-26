import 'dart:io';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/history_bill_balance.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/models/consumer_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

List<BillHistory> sampleBills() {
  const data = [
    ['6865832', '2400', '0', '0', '2400', '240', 'Un-Paid'],
    ['6133319', '2400', '2640', '0', '2400', '240', 'Paid'],
    ['5391203', '1200', '1200', '0', '1200', '0', 'Paid'],
    ['5237250', '400', '840', '440', '840', '40', 'Paid'],
    ['5063016', '400', '0', '0', '400', '40', 'Expired'],
    ['4951527', '400', '400', '0', '400', '40', 'Paid'],
    ['4293869', '2400', '2400', '0', '2400', '240', 'Paid'],
    ['3693511', '2400', '2400', '0', '2400', '240', 'Paid'],
    ['3448531', '2400', '2400', '0', '2400', '240', 'Paid'],
    ['2887092', '2400', '0', '0', '2400', '240', 'Expired'],
  ];
  const periods = [
    '01/07/2026 - 31/12/2026',
    '01/01/2026 - 30/06/2026',
    '01/10/2025 - 31/12/2025',
    '01/09/2025 - 30/09/2025',
    '01/08/2025 - 31/08/2025',
    '01/07/2025 - 31/07/2025',
    '01/01/2025 - 30/06/2025',
    '01/07/2024 - 31/12/2024',
    '01/01/2024 - 30/06/2024',
    '01/07/2023 - 31/12/2023',
  ];
  return [
    for (final r in data)
      BillHistory(
        connectionNo: '90010045',
        billNo: r[0],
        waterFee: r[1],
        amountReceived: r[2],
        arrears: r[3],
        totalBill: r[4],
        fine: r[5],
        status: r[6],
        afterDueDate: '${int.parse(r[4]) + int.parse(r[5])}',
        dueDate: r[0] == '6865832' ? '29/08/2026' : '-',
        billingPeriod: periods[data.indexOf(r)],
        billType: 'Regular',
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    '90010045 totals use generated fees and receipt amounts, not latest balance or due-date values',
    () {
      final audit = buildBillingAudit(
        consumers: [
          {'connection_no': '90010045'},
        ],
        bills: sampleBills().map((b) => b.toMap()).toList(),
      ).single;
      expect(audit.recordedDifference, 452000);
      expect(audit.waterFee, 1680000);
      expect(audit.received, 1228000);
      expect(audit.fineCollected, 28000);
      expect(audit.waterReceiptLimit, 1200000);
      expect(audit.difference, 480000);
      expect(audit.paidBillCount, 7);
      expect(audit.unpaidBillCount, 1);
      expect(audit.expiredBillCount, 2);
      expect(audit.allocationNeedsReview, true);
      expect(audit.reviewReasons.join(), contains('5237250'));
    },
  );

  test(
    'audit difference and history remaining balance use separate calculations',
    () {
      final bills = sampleBills();
      final audit = buildBillingAudit(
        consumers: [
          {'connection_no': '90010045'},
        ],
        bills: bills.map((b) => b.toMap()).toList(),
      ).single;
      final latest = BillHistory.fromMap({
        ...bills.first.toMap(),
        'due_date': '29/08/2026',
      });
      final remaining = latestHistoryBillBalance([
        latest,
        ...bills.skip(1),
      ], asOf: DateTime(2026, 10, 21));
      expect(audit.difference, 480000);
      expect(audit.fineCollected, 28000);
      expect(remaining.amount, 264000);
    },
  );

  test(
    'connection-scoped history audit preserves totals without touching financial rows',
    () async {
      final db = await fixture(inMemoryDatabasePath);
      final service = DatabaseService.forTesting(db);
      try {
        await db.insert(
          'consumers',
          Consumer.fromMap({'connection_no': '90010045'}).toMap(),
        );
        await db.insert(
          'consumers',
          Consumer.fromMap({'connection_no': 'OTHER'}).toMap(),
        );
        for (final bill in sampleBills()) {
          await db.insert('bill_history', bill.toMap());
        }
        await db.insert(
          'bill_history',
          const BillHistory(
            connectionNo: 'OTHER',
            billNo: '999',
            waterFee: '99999',
          ).toMap(),
        );
        final before = await db.query('bill_history');
        final audit = (await service.getBillingAudit(
          connectionNo: ' 90010045 ',
        )).single;
        expect(audit.waterFee, 1680000);
        expect(audit.received, 1228000);
        expect(audit.recordedDifference, 452000);
        expect(audit.allocationNeedsReview, true);
        expect(audit.unpaidBillCount, 1);
        expect(audit.expiredBillCount, 2);
        expect(await db.query('bill_history'), before);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'confirmed first-period exception is limited to two sectors and never changes already-Paid receipts',
    () {
      final original = const BillHistory(
        connectionNo: 'A',
        billNo: '1',
        billType: 'Regular',
        billingPeriod: '01/07/2023 - 31/12/2023',
        waterFee: '2400',
        totalBill: '2400',
        fine: '240',
        status: 'Expired',
      ).toMap();
      for (final sector in ['Ali Town', 'MUSLIM TOWN']) {
        final updated = applyConfirmedSectorPayment(original, sector);
        expect(updated['status'], 'Paid');
        expect(updated['amount_received'], '2400.00');
        expect(updated['receive_date'], '-');
        expect(updated['confirmed_payment_adjustment'], 240000);
        expect(applyConfirmedSectorPayment(updated, sector), updated);
        final alreadyPaid = {
          ...original,
          'status': 'Paid',
          'amount_received': '1200',
          'receive_date': '12/08/2023',
        };
        expect(applyConfirmedSectorPayment(alreadyPaid, sector), alreadyPaid);
      }
      expect(original['status'], 'Expired');
      expect(original['amount_received'], '0');
      expect(applyConfirmedSectorPayment(original, 'Other Town'), original);
      final nextPeriod = {
        ...original,
        'billing_period': '01/01/2024 - 30/06/2024',
      };
      expect(applyConfirmedSectorPayment(nextPeriod, 'Ali Town'), nextPeriod);
      final connectionCharge = {...original, 'bill_type': 'New Connection'};
      expect(
        applyConfirmedSectorPayment(connectionCharge, 'Ali Town'),
        connectionCharge,
      );
      final audit = buildBillingAudit(
        consumers: [
          {'connection_no': 'A', 'sector': 'Ali Town'},
        ],
        bills: [original],
      ).single;
      expect(audit.confirmedPaymentCount, 1);
      expect(audit.confirmedPaymentAdjustment, 240000);
      expect(audit.received, 240000);
      expect(audit.paidBillCount, 1);
      expect(audit.difference, 0);
    },
  );

  test(
    'one first-period payment per connection and duplicate bill is held for review',
    () {
      final bills = [
        for (final no in ['100', '200'])
          const BillHistory(
            connectionNo: 'A',
            billType: 'Regular',
            billingPeriod: '01/07/2023 - 31/12/2023',
            waterFee: '2400',
            totalBill: '2400',
          ).toMap()..['bill_no'] = no,
      ];
      final audit = buildBillingAudit(
        consumers: [
          {'connection_no': 'A', 'sector': 'Ali Town'},
        ],
        bills: bills,
      ).single;
      expect(audit.confirmedPaymentCount, 1);
      expect(audit.received, 240000);
      expect(audit.invalidHistory, true);
      expect(audit.difference, isNull);
      expect(audit.reviewReasons.join(), contains('review bill 100'));
      final alreadyPaid = [
        {...bills.first, 'status': 'Paid', 'amount_received': '2400'},
        bills.last,
      ];
      final again = buildBillingAudit(
        consumers: [
          {'connection_no': 'A', 'sector': 'Ali Town'},
        ],
        bills: alreadyPaid,
      ).single;
      expect(again.confirmedPaymentCount, 0);
      expect(again.received, 240000);
      expect(again.reviewReasons.join(), contains('review bill 200'));
    },
  );

  test(
    'verify live snapshot without changing source and export matching history PDF',
    () async {
      final db = await databaseFactoryFfi.openDatabase(
        File('scratch/history-totals-live-snapshot.db').absolute.path,
      );
      final service = DatabaseService.forTesting(db);
      try {
        final bills = await service.getBillHistory('90010045');
        final audit = (await service.getBillingAudit(
          connectionNo: '90010045',
        )).single;
        expect(bills, hasLength(10));
        expect(audit.waterFee, 1680000);
        expect(audit.received, 1468000);
        expect(audit.difference, 240000);
        expect(audit.paidBillCount, 8);
        expect(audit.confirmedPaymentCount, 1);
        expect(audit.recordedDifference, 212000);
        expect(audit.waterReceived, 1440000);
        expect(audit.fineCollected, 28000);
        expect(audit.outstandingFine, 24000);
        expect(audit.payableBalance, 240000);
        final all = await service.getBillingAudit();
        final exceptions = all
            .where((row) => row.confirmedPaymentCount > 0)
            .toList();
        expect(exceptions, isNotEmpty);
        expect(
          exceptions.every(
            (row) => ['Ali Town', 'MUSLIM TOWN'].contains(row.sector),
          ),
          true,
        );
        await File(
          'output/import/Confirmed_Sector_Payment_Exceptions.csv',
        ).writeAsString(
          'Connection No,Sector,Confirmed bills,Principal added to receipts\n${exceptions.map((row) => '${row.connectionNo},${row.sector},${row.confirmedPaymentCount},${row.confirmedPaymentAdjustment / 100}').join('\n')}',
        );
        final before = await db.query(
          'bill_history',
          where: 'connection_no = ?',
          whereArgs: ['90010045'],
        );
        final bytes = await ExportService.instance.generateBillHistoryPdf(
          connectionNo: '90010045',
          consumerDetail: await service.getConsumerConnectionDetail('90010045'),
          bills: bills,
          audit: audit,
        );
        await File(
          'output/pdf/90010045_Corrected_History.pdf',
        ).writeAsBytes(bytes);
        expect(
          await db.query(
            'bill_history',
            where: 'connection_no = ?',
            whereArgs: ['90010045'],
          ),
          before,
        );
      } finally {
        await db.close();
      }
    },
    skip: Platform.environment['RUN_HISTORY_TOTALS_LIVE'] != '1',
  );
}
