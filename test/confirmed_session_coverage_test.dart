import 'dart:convert';
import 'package:consumer_search_engine/models/audit_period_check.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/widgets/bill_history_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

List<Map<String, Object?>> source(
  String connection, {
  bool january = true,
  bool quarter = false,
  String replacement = '5986238',
  bool replacementBill = true,
  bool datedArrears = false,
}) => [
  for (final row in [
    ('5025849', 'Regular', '01/07/2025 - 31/07/2025', '400', '2640', '3040'),
    ('5050478', 'Regular', '01/08/2025 - 31/08/2025', '400', '3040', '3440'),
    ('5242493', 'Regular', '01/09/2025 - 30/09/2025', '400', '3480', '3880'),
    if (quarter)
      ('5407129', 'Regular', '01/10/2025 - 31/12/2025', '1200', '0', '1200'),
    if (replacementBill)
      (replacement, 'Arrears', '26/01/2026 - 26/01/2026', '0', '2400', '2400'),
    if (january)
      ('6130884', 'Regular', '01/01/2026 - 30/06/2026', '2400', '2640', '5040'),
    if (datedArrears)
      ('6652296', 'Arrears', '11/06/2026 - 11/06/2026', '0', '2400', '2400'),
    ('6853018', 'Regular', '01/07/2026 - 31/12/2026', '2400', '5280', '7680'),
  ])
    BillHistory(
      connectionNo: connection,
      billNo: row.$1,
      billType: row.$2,
      billingPeriod: row.$3,
      waterFee: row.$4,
      arrears: row.$5,
      totalBill: row.$6,
      status: 'Expired',
    ).toMap(),
];

BillingAuditEntry audit(String connection, List<Map<String, Object?>> bills) =>
    buildBillingAudit(
      consumers: [
        {'connection_no': connection, 'rate_type': 'DOMESTIC'},
      ],
      bills: bills,
      billGroup: 'regular',
      asOf: DateTime(2026, 10, 27),
    ).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'paid June 30 arrears bill fills January-June in filters and history without changing money',
    () {
      final bills = source(
        '12020222',
        january: false,
        quarter: true,
        replacementBill: false,
      );
      bills.add(
        BillHistory(
          connectionNo: '12020222',
          billNo: '6897944',
          billType: 'Arrears',
          billingPeriod: '30/06/2026 - 30/06/2026',
          waterFee: '0',
          arrears: '2500',
          totalBill: '2500',
          status: 'Paid',
          amountReceived: '2500',
          receiveDate: '21/08/2026',
        ).toMap(),
      );
      final before = jsonEncode(bills);
      final e = audit('12020222', bills);
      final check = checkAuditPeriod(
        e.periodBills,
        DateTime(2026, 1, 1),
        DateTime(2026, 6, 30),
      );
      expect(check.present, isTrue);
      expect(check.completeSessions, 1);
      expect(check.details, contains('6897944'));
      expect(check.details, contains('30/06/2026'));
      expect(
        e.coverage!.missingPeriods.any(
          (gap) => gap.start == DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );
      expect(
        e.coverage!.estimatedMissingFeeBetween(
          DateTime.utc(2026, 1, 1),
          DateTime.utc(2026, 6, 30),
        ),
        0,
      );
      expect(e.coverage!.shortFees, isEmpty);
      expect(e.waterFee, 480000);
      expect(e.received, 250000);
      expect(jsonEncode(bills), before);
    },
  );

  test(
    'any dated entry maps to its own half-year, independent of payment or water fee',
    () {
      for (final period in [
        '15/03/2026 - 15/03/2026',
        '02/01/2026 - 30/06/2026',
        '30/06/2026 - 30/06/2026',
        '31/12/2026 - 31/12/2026',
      ]) {
        for (final status in ['Paid', 'Un-Paid', 'Expired']) {
          final e = audit('ANY', [
            BillHistory(
              connectionNo: 'ANY',
              billNo: 'DATED',
              billType: 'Arrears',
              billingPeriod: period,
              waterFee: '0',
              totalBill: '2500',
              status: status,
            ).toMap(),
          ]);
          final july = period.startsWith('31/12');
          final check = checkAuditPeriod(
            e.periodBills,
            DateTime(2026, 1, 1),
            DateTime(2026, 12, 31),
          );
          expect(check.completeSessions, 1);
          expect(check.sessions.first.complete, !july);
          expect(check.sessions.last.complete, july);
          expect(e.coverage!.shortFees, isEmpty);
        }
      }
    },
  );

  test(
    'confirmed replacement fills July-Dec 2025 once without changing raw data or money',
    () {
      final bills = source('13010340');
      final before = jsonEncode(bills);
      final e = audit('13010340', bills);
      final unconfirmed = audit(
        '13010340',
        source('13010340', replacement: '5986237'),
      );
      final check = checkAuditPeriod(
        e.periodBills,
        DateTime(2025, 7, 1),
        DateTime(2026, 12, 31),
      );
      expect(check.completeSessions, 3);
      expect(check.sessions.length, 3);
      expect(check.confirmations.single, contains('5986238'));
      expect(check.confirmations.single, contains('26/01/2026'));
      expect(
        e.coverage!.missingPeriods.any(
          (g) => g.start == DateTime.utc(2025, 10, 1),
        ),
        isFalse,
      );
      expect(
        unconfirmed.coverage!.estimatedMissingFee! -
            e.coverage!.estimatedMissingFee!,
        120000,
      );
      expect(e.coverage!.shortFees, isEmpty);
      expect(e.waterFee, unconfirmed.waterFee);
      expect(e.received, unconfirmed.received);
      expect(e.payableBalance, unconfirmed.payableBalance);
      expect(e.fineCollected, unconfirmed.fineCollected);
      expect(e.billCount, unconfirmed.billCount);
      expect(jsonEncode(bills), before);
      expect(
        ExportService.billingAuditCsv([e], periodChecks: {'13010340': check}),
        contains('Confirmed replacement'),
      );
    },
  );

  test(
    'confirmed replacement never covers January 2026 or leaks to another connection',
    () {
      final e = audit('13010340', source('13010340', january: false));
      final check = checkAuditPeriod(
        e.periodBills,
        DateTime(2025, 7, 1),
        DateTime(2026, 12, 31),
      );
      expect(check.completeSessions, 2);
      expect(check.missingSessionLabels, 'Jan-Jun 2026');
      final january = checkAuditPeriod(
        e.periodBills,
        DateTime(2026, 1, 1),
        DateTime(2026, 12, 31),
      );
      expect(january.completeSessions, 1);
      expect(january.confirmations, isEmpty);
      final other = audit('13010040', source('13010040'));
      final otherCheck = checkAuditPeriod(
        other.periodBills,
        DateTime(2025, 7, 1),
        DateTime(2025, 12, 31),
      );
      expect(otherCheck.present, isFalse);
      expect(otherCheck.confirmations, isEmpty);
      final actualMissing = audit(
        '13010040',
        source(
          '13010040',
          january: false,
          quarter: true,
          replacementBill: false,
        ),
      );
      final missing = checkAuditPeriod(
        actualMissing.periodBills,
        DateTime(2025, 7, 1),
        DateTime(2026, 12, 31),
      );
      expect(missing.completeSessions, 2);
      expect(missing.missingSessionLabels, 'Jan-Jun 2026');
      final multiple = audit(
        '13010023',
        source('13010023', january: false, replacementBill: false),
      );
      expect(
        checkAuditPeriod(
          multiple.periodBills,
          DateTime(2025, 7, 1),
          DateTime(2026, 12, 31),
        ).missingSessionLabels,
        'Jul-Dec 2025, Jan-Jun 2026',
      );
    },
  );

  test(
    'regular quarter plus confirmed replacement still counts only one session',
    () {
      final e = audit('13010340', source('13010340', quarter: true));
      final check = checkAuditPeriod(
        e.periodBills,
        DateTime(2025, 7, 1),
        DateTime(2025, 12, 31),
      );
      expect(check.completeSessions, 1);
      expect(e.coverage!.shortFees, isEmpty);
    },
  );

  testWidgets(
    'history labels selected scope separately and explains the confirmed replacement',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        await db.insert('consumers', {
          'connection_no': '13010340',
          'consumer_name': 'Example',
          'rate_type': 'DOMESTIC',
        });
        for (final bill in source('13010340')) {
          await db.insert('bill_history', bill);
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1700, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BillHistoryDialog(
              initialConnectionNo: '13010340',
              database: DatabaseService.forTesting(db),
              auditPeriodFrom: DateTime(2025, 7, 1),
              auditPeriodTo: DateTime(2026, 12, 31),
              auditBillGroup: 'regular',
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 40 &&
            find
                .byKey(const ValueKey('selected-audit-period-coverage'))
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selected-audit-period-coverage')),
        findsOneWidget,
      );
      expect(find.textContaining('3/3 sessions complete'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('billing-coverage-confirmation')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Full-history coverage since July 2023'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
