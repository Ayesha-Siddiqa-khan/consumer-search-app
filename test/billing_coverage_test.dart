import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/screens/billing_audit_screen.dart';
import 'package:consumer_search_engine/widgets/bill_history_dialog.dart';
import 'package:consumer_search_engine/widgets/billing_audit_pdf_dialog.dart';
import 'package:consumer_search_engine/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

const periods = [
  '01/07/2023 - 31/12/2023',
  '01/01/2024 - 30/06/2024',
  '01/07/2024 - 31/12/2024',
  '01/01/2025 - 30/06/2025',
  '01/07/2025 - 31/07/2025',
  '01/08/2025 - 31/08/2025',
  '01/09/2025 - 30/09/2025',
  '01/10/2025 - 31/12/2025',
  '01/01/2026 - 30/06/2026',
  '01/07/2026 - 31/12/2026',
];
const fees = [2400, 2400, 2400, 2400, 400, 400, 400, 1200, 2400, 2400];
List<Map<String, Object?>> history({
  Set<int> omit = const {},
  int multiplier = 1,
}) => [
  for (var i = 0; i < periods.length; i++)
    if (!omit.contains(i))
      BillHistory(
        connectionNo: 'A',
        billNo: '${100 + i}',
        billType: 'Regular',
        billingPeriod: periods[i],
        waterFee: '${fees[i] * multiplier}',
        totalBill: '${fees[i] * multiplier}',
        status: i == 9 ? 'Un-Paid' : 'Expired',
      ).toMap(),
];
BillingAuditEntry audit(
  List<Map<String, Object?>> bills, {
  String rateType = 'DOMESTIC',
  DateTime? asOf,
}) => buildBillingAudit(
  consumers: [
    {
      'connection_no': 'A',
      'rate_type': rateType,
      'connection_date': '01-01-2026',
    },
  ],
  bills: bills,
  asOf: asOf ?? DateTime(2026, 10, 22),
).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('split six-month session is complete and not charged twice', () {
    final result = audit(history());
    expect(result.waterFee, 1680000);
    expect(result.coverage!.expectedWaterFee, 1680000);
    expect(result.coverage!.missingBillCount, 0);
    expect(result.coverage!.hasWarning, false);
  });

  test(
    '13200 example identifies both missing issues without inventing debt',
    () {
      final bills = history(omit: {3, 7});
      final before = jsonEncode(bills);
      final result = audit(bills);
      final coverage = result.coverage!;
      expect(result.waterFee, 1320000);
      expect(result.payableBalance, 1320000);
      expect(coverage.missingBillCount, 2);
      expect(coverage.estimatedMissingFee, 360000);
      expect(coverage.missingPeriods.map((p) => p.label), [
        '01-01-2025 - 30-06-2025',
        '01-10-2025 - 31-12-2025',
      ]);
      expect(jsonEncode(bills), before);
      final csv = ExportService.billingAuditCsv([result]);
      expect(csv, contains('Estimated Missing Water Fee'));
      expect(csv, contains('3600.00'));
    },
  );

  test(
    'missing monthly bills are separate, while expired bills cover their months',
    () {
      final coverage = audit(history(omit: {4, 5})).coverage!;
      expect(coverage.missingBillCount, 2);
      expect(coverage.estimatedMissingFee, 80000);
      expect(coverage.missingPeriods.map((p) => p.label), [
        '01-07-2025 - 31-07-2025',
        '01-08-2025 - 31-08-2025',
      ]);
    },
  );

  test(
    'combined annual and half-year periods replace split issues as coverage',
    () {
      final bills = history(omit: {0, 1, 4, 5, 6, 7});
      bills.addAll([
        BillHistory(
          connectionNo: 'A',
          billNo: '90',
          billType: 'Regular',
          billingPeriod: '01/07/2023 - 30/06/2024',
          waterFee: '4800',
          totalBill: '4800',
        ).toMap(),
        BillHistory(
          connectionNo: 'A',
          billNo: '91',
          billType: 'Regular',
          billingPeriod: '01/07/2025 - 31/12/2025',
          waterFee: '2400',
          totalBill: '2400',
        ).toMap(),
      ]);
      expect(audit(bills).coverage!.hasWarning, false);
      expect(audit(bills).waterFee, 1680000);
    },
  );

  test('all accounts use July 2023 baseline and rates match their history', () {
    final result = audit(
      history(omit: {0}, multiplier: 2),
      rateType: 'PRIVATE',
    );
    expect(result.coverage!.monthlyWaterRate, 80000);
    expect(result.coverage!.expectedWaterFee, 3360000);
    expect(result.coverage!.estimatedMissingFee, 480000);
    final empty = audit([]).coverage!;
    expect(empty.hasRecordedHistory, false);
    expect(empty.missingBillCount, 0);
    expect(empty.estimatedMissingFee, 0);
    expect(empty.estimatedMissingAmount, 0);
    expect(empty.expectedWaterFee, 0);
    expect(empty.hasWarning, false);
    expect(empty.standardRateEstimate, false);
  });

  test(
    'undated bills make gaps possible; new connection charges cannot fill gaps',
    () {
      final bills = history(omit: {3});
      bills.add(
        BillHistory(
          connectionNo: 'A',
          billNo: '300',
          billType: 'Regular',
          waterFee: '2400',
          totalBill: '2400',
        ).toMap(),
      );
      final coverage = audit(bills).coverage!;
      expect(coverage.missingBillCount, 1);
      expect(coverage.warningText((n) => '$n'), contains('Possible missing'));
      expect(coverage.undatedBills, ['300']);
      bills.last['bill_type'] = 'New Connection';
      expect(audit(bills).coverage!.undatedBills, isEmpty);
      expect(audit(bills).coverage!.missingBillCount, 1);
    },
  );

  test(
    'zero-fee bills are fee shortfalls and varying rates are not guessed',
    () {
      final bills = history();
      bills[3]['water_fee'] = '0';
      bills[3]['total_bill'] = '0';
      final zero = audit(bills).coverage!;
      expect(zero.missingBillCount, 0);
      expect(zero.shortFees.single.billNo, '103');
      expect(zero.shortFeeAmount, 240000);
      expect(zero.estimatedMissingAmount, 240000);
      bills[3]['water_fee'] = '1200';
      bills[3]['total_bill'] = '1200';
      final varied = audit(bills).coverage!;
      expect(varied.variableRates, true);
      expect(varied.monthlyWaterRate, isNull);
      expect(varied.shortFees, isEmpty);
    },
  );

  test(
    'monthly issues are only expected when issued, future half-years excluded',
    () {
      final before = audit(
        history().sublist(0, 6),
        asOf: DateTime(2025, 8, 15),
      ).coverage!;
      expect(before.expectedWaterFee, 1040000);
      expect(before.hasWarning, false);
      expect(before.checkedThrough, DateTime.utc(2025, 8, 31));
    },
  );

  testWidgets(
    'empty history has no missing-session warning or estimated charges',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        await db.insert('consumers', {
          'connection_no': '0010010002',
          'rate_type': 'DOMESTIC',
        });
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BillHistoryDialog(
              initialConnectionNo: '0010010002',
              database: DatabaseService.forTesting(db),
              auditPeriodFrom: DateTime(2026, 1, 1),
              auditPeriodTo: DateTime(2026, 6, 30),
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 30 &&
            find.textContaining('No bill history found').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('No bill history found'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('billing-coverage-warning')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('selected-audit-period-coverage')),
        findsNothing,
      );
      expect(find.textContaining('Missing bills:'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('history shows red gap periods, count and estimated amount', (
    tester,
  ) async {
    late Database db;
    late DatabaseService service;
    await tester.runAsync(() async {
      if (Platform.environment['CAPTURE_BILLING_COVERAGE'] == '1') {
        for (final family in ['Segoe UI', 'Roboto', 'MaterialIcons']) {
          final path = family == 'MaterialIcons'
              ? 'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
              : 'C:/Windows/Fonts/segoeui.ttf';
          await (FontLoader(family)
                ..addFont(File(path).readAsBytes().then(ByteData.sublistView)))
              .load();
        }
      }
      db = await fixture(inMemoryDatabasePath);
      service = DatabaseService.forTesting(db);
      await db.insert('consumers', {
        'connection_no': 'A',
        'consumer_name': 'Sample',
        'rate_type': 'DOMESTIC',
        'connection_date': '01-07-2023',
      });
      for (final bill in history(omit: {3, 7})) {
        await db.insert('bill_history', bill);
      }
    });
    addTearDown(() async {
      await db.close();
    });
    await tester.binding.setSurfaceSize(const Size(1280, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('coverage-preview'),
            child: BillHistoryDialog(
              initialConnectionNo: 'A',
              database: service,
            ),
          ),
        ),
      ),
    );
    final warning = find.byKey(const ValueKey('billing-coverage-warning'));
    for (var i = 0; i < 30 && warning.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    expect(warning, findsOneWidget);
    final text = tester.widget<Text>(
      find.descendant(of: warning, matching: find.byType(Text)),
    );
    expect(
      text.data,
      contains('Missing bills: 2; estimated water fees: Rs. 3,600'),
    );
    expect(text.data, contains('01-01-2025 - 30-06-2025: Rs. 2,400'));
    expect(text.data, contains('01-10-2025 - 31-12-2025: Rs. 1,200'));
    expect(text.style!.color, const Color(0xFFB91C1C));
    expect(tester.takeException(), isNull);
    if (Platform.environment['CAPTURE_BILLING_COVERAGE'] == '1') {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('coverage-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'scratch/billing-coverage-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'audit filters missing periods without reclassifying water balance',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        for (final id in ['A', 'FULL']) {
          await db.insert('consumers', {
            'connection_no': id,
            'consumer_name': 'Consumer $id',
            'connection_status': 'Regular Connection',
            'rate_type': 'DOMESTIC',
          });
          for (final bill in history(omit: id == 'A' ? {3, 7} : {})) {
            await db.insert('bill_history', {...bill, 'connection_no': id});
          }
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('missing-amounts-preview'),
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
          ),
        ),
      );
      for (
        var i = 0;
        i < 20 && find.text('Consumer A').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.text('Consumer FULL'), findsOneWidget);
      expect(find.text('Missing bill amount'), findsOneWidget);
      expect(find.text('Total amount'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 3,600'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Totals — all 2 filtered connection(s) (every page)'),
        findsOneWidget,
      );
      expect(find.text('Missing bill amount: Rs. 3,600'), findsOneWidget);
      expect(find.text('Total amount: Rs. 33,600'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'All results'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Missing amounts').last);
      await tester.pumpAndSettle();
      expect(find.text('Consumer A'), findsOneWidget);
      expect(find.text('Consumer FULL'), findsNothing);
      expect(find.text('Missing Bills'), findsOneWidget);
      expect(find.text('Estimated Missing Amount'), findsOneWidget);
      expect(find.text('Expected Water Fee'), findsOneWidget);
      expect(find.text('Recorded Water Fee'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 3,600'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.textContaining('01-01-2025 - 30-06-2025: Rs. 2,400'),
        findsOneWidget,
      );
      expect(
        find.textContaining('01-10-2025 - 31-12-2025: Rs. 1,200'),
        findsOneWidget,
      );
      expect(
        tester.widget<DataTable>(find.byType(DataTable)).sortColumnIndex,
        14,
      );
      await tester.ensureVisible(find.text('Total missing amount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Total missing amount'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DataTable>(find.byType(DataTable)).sortAscending,
        true,
      );
      if (Platform.environment['CAPTURE_BILLING_COVERAGE'] == '1') {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('missing-amounts-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'scratch/missing-amounts-preview.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BillingAuditPdfDialog>(find.byType(BillingAuditPdfDialog))
            .initialColumnKeys,
        ExportService.defaultMissingAmountsPdfColumns,
      );
      expect(
        find.text(
          '${ExportService.defaultMissingAmountsPdfColumns.length} columns selected',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Missing amounts'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All results').last);
      await tester.pumpAndSettle();
      expect(find.text('Consumer FULL'), findsOneWidget);
      expect(find.text('Result / review'), findsOneWidget);
      expect(
        tester.widget<DataTable>(find.byType(DataTable)).sortColumnIndex,
        11,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'PDF columns include missing and total amounts with period-aware totals',
    () async {
      final entry = audit(history(omit: {3, 8}));
      final coverage = entry.coverage!;
      expect(
        coverage.estimatedMissingFeeBetween(
          DateTime.utc(2026, 1, 1),
          DateTime.utc(2026, 6, 30),
        ),
        240000,
      );
      expect(
        coverage.estimatedMissingFeeBetween(
          DateTime.utc(2023, 1, 1),
          DateTime.utc(2023, 6, 30),
        ),
        0,
      );

      final keys = ExportService.billingAuditColumns.map((c) => c.key);
      expect(keys, containsAll(['missing_bill_amount', 'total_amount']));
      expect(
        ExportService.defaultBillingAuditPdfColumns,
        containsAll(['missing_bill_amount', 'missing_amount']),
      );

      final totals = ExportService.billingAuditTotals([entry]);
      expect(totals.missingBillAmount, coverage.estimatedMissingFee);
      expect(
        totals.totalAmount,
        entry.payableBalance! + coverage.estimatedMissingFee!,
      );

      final periodTotals = ExportService.billingAuditTotals(
        [entry],
        periodFrom: DateTime.utc(2026, 1, 1),
        periodTo: DateTime.utc(2026, 6, 30),
      );
      expect(periodTotals.missingBillAmount, 240000);
      expect(periodTotals.totalAmount, entry.payableBalance! + 240000);

      final csv = ExportService.billingAuditCsv(
        [entry],
        periodFrom: DateTime.utc(2026, 1, 1),
        periodTo: DateTime.utc(2026, 6, 30),
      );
      expect(csv, contains('"Missing Bill Amount"'));
      expect(csv, contains('"Total Amount"'));
      expect(csv, contains('"2400.00"'));

      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: [entry],
        selectedColumnKeys: {'missing_bill_amount', 'total_amount'},
        periodFrom: DateTime.utc(2026, 1, 1),
        periodTo: DateTime.utc(2026, 6, 30),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    },
  );

  testWidgets(
    'missing bill amount follows the selected period and totals every filtered row',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        await db.insert('consumers', {
          'connection_no': 'A',
          'consumer_name': 'Consumer A',
          'connection_status': 'Regular Connection',
          'rate_type': 'DOMESTIC',
        });
        final bills = history(omit: {3, 8});
        bills.first['amount_received'] = '4900';
        bills.first['status'] = 'Paid';
        for (final bill in bills) {
          await db.insert('bill_history', bill);
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
        ),
      );
      for (
        var i = 0;
        i < 20 && find.text('Consumer A').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.text('Consumer A'), findsOneWidget);
      expect(find.text('Missing bill amount'), findsOneWidget);
      expect(find.text('Total amount'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 4,800'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 11,900'),
        ),
        findsOneWidget,
      );
      expect(find.text('Missing bill amount: Rs. 4,800'), findsOneWidget);
      expect(find.text('Total amount: Rs. 11,900'), findsOneWidget);
      expect(
        find.text('Totals — all 1 filtered connection(s) (every page)'),
        findsOneWidget,
      );

      final fromKey = find.byKey(const ValueKey('audit-period-from'));
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(fromKey);
      await tester.pumpAndSettle();
      await tester.tap(fromKey);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('01/01/2026').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('01/01/2026').last);
      await tester.pumpAndSettle();
      final periodPresence = find.widgetWithText(
        DropdownButtonFormField<String>,
        'All period results',
      );
      await tester.ensureVisible(periodPresence);
      await tester.pumpAndSettle();
      await tester.tap(periodPresence);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Period missing / incomplete').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(DataTable));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 2,400'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 9,500'),
        ),
        findsOneWidget,
      );
      expect(find.text('Missing bill amount: Rs. 2,400'), findsOneWidget);
      expect(find.text('Total amount: Rs. 9,500'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing categories separate positive, zero and unknown balances and total fee shortfalls',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        for (final id in ['POS', 'ZERO', 'UNKNOWN', 'EMPTY']) {
          await db.insert('consumers', {
            'connection_no': id,
            'consumer_name': 'Consumer $id',
            'connection_status': 'Regular Connection',
            'rate_type': 'DOMESTIC',
          });
          if (id == 'EMPTY') continue;
          final bills = history(omit: {3});
          bills.singleWhere((b) => b['bill_no'] == '107').addAll({
            'water_fee': '0',
            'total_bill': '0',
          });
          if (id == 'ZERO') {
            for (final bill in bills) {
              bill['status'] = 'Paid';
              bill['amount_received'] = bill['water_fee'];
            }
          }
          if (id == 'UNKNOWN') bills.last['amount_received'] = 'invalid';
          for (final bill in bills) {
            await db.insert('bill_history', {...bill, 'connection_no': id});
          }
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1700, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
        ),
      );
      for (
        var i = 0;
        i < 30 && find.text('Consumer POS').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      Future<void> choose(String current, String next) async {
        if (find
            .byKey(const ValueKey('audit-period-from'))
            .evaluate()
            .isNotEmpty) {
          await tester.tap(
            find.text('Billing period, sessions & amount filters'),
          );
          await tester.pumpAndSettle();
        }
        final field = find.widgetWithText(
          DropdownButtonFormField<String>,
          current,
        );
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(DropdownButtonFormField<String>, current),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        await tester.pumpAndSettle();
      }

      await choose('All results', 'Missing amounts');
      expect(find.text('Consumer POS'), findsOneWidget);
      expect(find.text('Consumer ZERO'), findsOneWidget);
      expect(find.text('Consumer EMPTY'), findsNothing);
      expect(find.text('Consumer UNKNOWN'), findsOneWidget);
      await choose('All water balances', 'Water balance outstanding');
      expect(find.text('Consumer POS'), findsOneWidget);
      expect(find.text('Consumer ZERO'), findsNothing);
      expect(find.text('Consumer UNKNOWN'), findsNothing);
      final table = tester.widget<DataTable>(find.byType(DataTable));
      expect(table.rows, hasLength(1));
      final tableFinder = find.byType(DataTable);
      expect(
        find.descendant(of: tableFinder, matching: find.text('Rs. 3,600')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tableFinder, matching: find.text('Rs. 2,400')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tableFinder, matching: find.text('Rs. 1,200')),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 additional bill(s) have short water fees.'),
        findsOneWidget,
      );
      await choose('Water balance outstanding', 'Water balance zero');
      expect(find.text('Consumer ZERO'), findsOneWidget);
      expect(find.text('Consumer POS'), findsNothing);
      expect(find.text('Consumer UNKNOWN'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('Rs. 3,600'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<BillingAuditPdfDialog>(
        find.byType(BillingAuditPdfDialog),
      );
      expect(dialog.entries.single.connectionNo, 'ZERO');
      expect(dialog.filterSummary, contains('Water balance zero'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await choose('Missing amounts', 'All results');
      expect(find.text('Consumer POS'), findsOneWidget);
      expect(find.text('Consumer ZERO'), findsOneWidget);
      expect(find.text('Consumer UNKNOWN'), findsOneWidget);
      expect(find.text('Missing: water balance'), findsNothing);
      await choose('All results', 'Missing amounts');
      expect(find.text('Consumer ZERO'), findsOneWidget);
      expect(find.text('Consumer POS'), findsNothing);
      await choose('Water balance zero', 'All water balances');
      expect(find.text('Consumer UNKNOWN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'custom generated-fee threshold is strict, composes with balance filters and exports, and resets paging',
    (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        final amounts = <String, String>{
          for (var i = 0; i < 22; i++) 'LOW$i': '2400',
          'EXACT': '9600',
          'ABOVE': '9600.01',
          'HIGH': '13200',
          'ZERO': '0',
          'UNKNOWN': 'invalid',
        };
        for (final entry in amounts.entries) {
          await db.insert('consumers', {
            'connection_no': entry.key,
            'consumer_name': 'Consumer ${entry.key}',
            'rate_type': 'DOMESTIC',
            'connection_status': 'Regular Connection',
          });
          await db.insert(
            'bill_history',
            BillHistory(
              connectionNo: entry.key,
              billNo: '1',
              billType: 'Regular',
              billingPeriod: periods.first,
              waterFee: entry.value,
              totalBill: entry.value,
              status: 'Un-Paid',
            ).toMap(),
          );
        }
        // An enormous total with carried arrears must not pass a water-fee threshold.
        await db.update(
          'bill_history',
          {'total_bill': '50000', 'arrears': '47600'},
          where: 'connection_no = ?',
          whereArgs: ['LOW0'],
        );
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1700, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
        ),
      );
      for (
        var i = 0;
        i < 30 && find.byType(DataTable).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      Future<void> choose(String current, String next) async {
        final field = find.widgetWithText(
          DropdownButtonFormField<String>,
          current,
        );
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        await tester.pumpAndSettle();
      }

      await choose('All results', 'Missing amounts');
      final nextPage = find.widgetWithIcon(IconButton, Icons.chevron_right);
      expect(find.text('1–20 of 27'), findsOneWidget);
      tester.widget<IconButton>(nextPage).onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('21–27 of 27'), findsOneWidget);
      final threshold = find.byKey(
        const ValueKey('generated-water-fee-threshold'),
      );
      Future<void> enter(String value) async {
        await tester.ensureVisible(threshold);
        await tester.enterText(threshold, value);
        await tester.pumpAndSettle();
      }

      await enter('9,600.00');
      expect(find.text('Consumer HIGH'), findsOneWidget);
      expect(find.text('Consumer ABOVE'), findsOneWidget);
      expect(find.text('Consumer EXACT'), findsNothing);
      expect(find.text('Consumer LOW0'), findsNothing);
      expect(find.text('Consumer UNKNOWN'), findsNothing);
      expect(find.text('1–2 of 2'), findsOneWidget);
      expect(find.text('Rs. 22,800.01'), findsOneWidget);
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<BillingAuditPdfDialog>(
        find.byType(BillingAuditPdfDialog),
      );
      expect(dialog.entries.map((e) => e.connectionNo).toSet(), {
        'HIGH',
        'ABOVE',
      });
      expect(dialog.filterSummary, contains('Generated water fee > Rs. 9,600'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await enter('10000');
      expect(find.text('Consumer HIGH'), findsOneWidget);
      expect(find.text('Consumer ABOVE'), findsNothing);
      await choose('All water balances', 'Water balance zero');
      expect(find.text('No connections match these filters.'), findsOneWidget);
      final clear = find.byTooltip('Clear generated water fee filter');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('Consumer ZERO'), findsOneWidget);
      await choose('Water balance zero', 'All water balances');
      for (final bad in ['not money', '-1', '9600.001']) {
        await enter(bad);
        expect(
          find.text('Enter a valid non-negative rupee amount'),
          findsOneWidget,
        );
        expect(
          find.text('No connections match these filters.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(
                  ElevatedButton,
                  'Export missing amounts CSV',
                ),
              )
              .onPressed,
          isNull,
        );
      }
      await enter('9600');
      await choose('Missing amounts', 'All results');
      expect(threshold, findsNothing);
      expect(find.text('1–20 of 27'), findsOneWidget);
      await choose('All results', 'Missing amounts');
      expect(tester.widget<TextField>(threshold).controller!.text, '9600');
      expect(find.text('Consumer EXACT'), findsNothing);
      expect(find.text('1–2 of 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
