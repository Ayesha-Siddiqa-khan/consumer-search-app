import 'dart:io';
import 'dart:ui' as ui;
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/screens/billing_audit_screen.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/theme/app_theme.dart';
import 'package:consumer_search_engine/widgets/bill_history_dialog.dart';
import 'package:consumer_search_engine/widgets/copyable_text.dart';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> consumer(String connection, {String rate = 'DOMESTIC'}) =>
    {
      'connection_no': connection,
      'consumer_name': 'Consumer $connection',
      'father_husband_name': 'Father',
      'sector': 'Sector A',
      'locality': 'Locality',
      'address': 'Private address not selected',
      'rate_type': rate,
      'connection_date': '01/07/2023',
      'connection_status': 'Regular Connection',
      'consumer_status': 'Active',
      'bill_status': 'Un-Paid',
    };

List<Map<String, Object?>> history(
  String connection,
  List<String> fees, {
  List<String>? receipts,
}) => [
  for (var i = 0; i < fees.length; i++)
    {
      'connection_no': connection,
      'bill_no': '${i + 1}',
      'water_fee': fees[i],
      'amount_received': receipts?[i] ?? fees[i],
      'total_bill': fees[i],
      'bill_type': 'Regular',
      'arrears': '0',
      'fine': '0',
      'sanitation': '0',
      'drainage': '0',
      'billing_fee': '0',
      'status': receipts != null && receipts[i] != fees[i] ? 'Un-Paid' : 'Paid',
    },
];

class _AuditTrackingService extends DatabaseService {
  _AuditTrackingService(super.db) : super.forTesting();
  final requests = <String?>[];

  @override
  Future<List<BillingAuditEntry>> getBillingAudit({
    String billGroup = 'all',
    String? connectionNo,
  }) {
    requests.add(connectionNo);
    return super.getBillingAudit(
      billGroup: billGroup,
      connectionNo: connectionNo,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'New Connection charges have a separate group and never inflate regular bills',
    () {
      final newBill = history('NEW', ['405000'], receipts: ['0']);
      newBill.single['bill_type'] = 'New Connection';
      final masters = [consumer('NEW'), consumer('R')];
      final bills = [
        ...newBill,
        ...history('R', ['2400']),
      ];
      final regular = buildBillingAudit(
        consumers: masters,
        bills: bills,
        billGroup: 'regular',
      );
      final newConnections = buildBillingAudit(
        consumers: masters,
        bills: bills,
        billGroup: 'new_connection',
      );
      expect(regular.single.connectionNo, 'R');
      expect(regular.single.waterFee, 240000);
      expect(newConnections.single.connectionNo, 'NEW');
      expect(newConnections.single.difference, 40500000);
      expect(newConnections.single.billGroupLabel, 'New Connection bills');
      final decoded = csv.decode(
        ExportService.billingAuditCsv(
          newConnections,
        ).replaceFirst('\ufeff', ''),
      );
      expect(
        decoded[1][decoded.first.indexOf('Bill Group')],
        'New Connection bills',
      );
    },
  );

  test('cross-type arrears receipts require account-level reconciliation', () {
    final bills = history('A', ['405000', '2400'], receipts: ['0', '407400']);
    bills[0]['bill_type'] = 'New Connection';
    bills[1].addAll({'arrears': '405000', 'total_bill': '407400'});
    final separate = buildBillingAudit(
      consumers: [consumer('A')],
      bills: bills,
      billGroup: 'new_connection',
    ).single;
    expect(separate.difference, isNull);
    expect(separate.reviewReasons.join(), contains('All generated bills'));
    expect(
      buildBillingAudit(
        consumers: [consumer('A')],
        bills: bills,
      ).single.difference,
      0,
    );
  });

  testWidgets('clicking a displayed value copies its full text', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CopyableText('405,000.00'))),
    );
    await tester.tap(find.text('405,000.00'));
    await tester.pumpAndSettle();
    expect(copied, '405,000.00');
    expect(find.text('Copied to clipboard'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('one generated unpaid bill owes only 4800, one paid bill owes zero', () {
    final unpaid = history('10004', ['4800'], receipts: ['0']);
    unpaid.single.addAll({
      'fine': '480',
      'after_due_date': '5280',
      'due_date': '31/12/2099',
    });
    final rows = buildBillingAudit(
      consumers: [
        consumer('10004', rate: 'PRIVATE SOCIETIES'),
        consumer('PAID'),
      ],
      bills: [
        ...unpaid,
        ...history('PAID', ['2400']),
      ],
    );
    expect(rows.first.waterFee, 480000);
    expect(rows.first.difference, 480000);
    expect(rows.first.paidBillCount, 0);
    expect(rows.first.unpaidBillCount, 1);
    expect(rows.last.waterFee, 240000);
    expect(rows.last.difference, 0);
    expect(rows.last.result, 'No water balance');
  });

  test(
    'monthly and combined bills use actual fees; arrears are never added twice',
    () {
      final fees = [
        '4800',
        '4800',
        '2400',
        '800',
        '800',
        '800',
        '4800',
        '4800',
        '4800',
        '4800',
      ];
      final receipts = [
        '4800',
        '4800',
        '2640',
        '2480',
        '0',
        '0',
        '4800',
        '4800',
        '4800',
        '4800',
      ];
      final society = history('P', fees, receipts: receipts);
      for (var i = 0; i < society.length; i++) {
        society[i]['status'] = i == 4 || i == 5 ? 'Expired' : 'Paid';
      }
      society[2]['fine'] = '240';
      society[3].addAll({
        'arrears': '1680',
        'total_bill': '2480',
        'fine': '80',
      });
      society[4].addAll({'arrears': '800', 'total_bill': '1600', 'fine': '80'});
      final rows = buildBillingAudit(
        consumers: [
          consumer('D'),
          consumer('P', rate: 'PRIVATE SOCIETIES'),
        ],
        bills: [
          ...history('D', ['2400', '2400', '2400', '2400', '4800', '2400']),
          ...society,
        ],
      );
      final domestic = rows.firstWhere((e) => e.connectionNo == 'D');
      final private = rows.firstWhere((e) => e.connectionNo == 'P');
      expect(domestic.waterFee, 1680000);
      expect(domestic.billCount, 6);
      expect(domestic.paidBillCount, 6);
      expect(domestic.difference, 0);
      expect(private.waterFee, 3360000);
      expect(private.received, 3392000);
      expect(private.knownNonWaterReceived, 24000);
      expect(private.paidBillCount, 8);
      expect(private.unpaidBillCount, 0);
      expect(private.expiredBillCount, 2);
      expect(private.difference, 0);
      expect(private.waterReceived, 3360000);
      expect(private.advanceBalance, 8000);
      expect(private.allocationNeedsReview, isFalse);
    },
  );

  test(
    'water receipts exclude collected fines and other identified charges',
    () {
      final bills = history(
        'A',
        ['2400', '2400', '2400'],
        receipts: ['2640', '2500', '0'],
      );
      bills[0]['fine'] = '240';
      bills[1].addAll({'sanitation': '100', 'total_bill': '2500'});
      final row = buildBillingAudit(
        consumers: [consumer('A')],
        bills: bills,
      ).single;
      expect(row.waterFee, 720000);
      expect(row.knownNonWaterReceived, 34000);
      expect(row.fineCollected, 24000);
      expect(row.difference, 240000);
      final exported = csv.decode(
        ExportService.billingAuditCsv([row]).replaceFirst('\ufeff', ''),
      );
      expect(
        exported[1][exported.first.indexOf('Fine Collected')].toString(),
        '240.00',
      );
      expect(exported.first, isNot(contains('Known Non-water Received')));
      expect(
        exported[1][exported.first.indexOf('Water Balance')].toString(),
        '2400.00',
      );
    },
  );

  test(
    'partial mixed receipts keep the direct difference and an allocation review',
    () {
      final bill = history('A', ['2400'], receipts: ['1000']);
      bill.single.addAll({'sanitation': '100', 'total_bill': '2500'});
      final row = buildBillingAudit(
        consumers: [consumer('A')],
        bills: bill,
      ).single;
      expect(row.difference, 140000);
      expect(row.allocationNeedsReview, isTrue);
      expect(row.reviewReasons.join(), contains('allocation needs review'));
    },
  );

  test(
    'fine paid above water fee goes into fine collected, not water receipts',
    () {
      final bills = history('A', ['2400'], receipts: ['2640']);
      bills.single.addAll({'fine': '240', 'status': 'Paid'});
      final row = buildBillingAudit(
        consumers: [consumer('A')],
        bills: bills,
      ).single;
      expect(row.waterFee, 240000);
      expect(row.received, 264000);
      expect(row.fineCollected, 24000);
      expect(row.waterReceived, 240000);
      expect(row.difference, 0);
      expect(row.payableBalance, 0);
      expect(row.result, 'No water balance');
    },
  );

  test('paid status does not erase missing money', () {
    final bills = history('A', ['2400'], receipts: ['500']);
    bills.single['status'] = 'Paid';
    final row = buildBillingAudit(
      consumers: [consumer('A')],
      bills: bills,
    ).single;
    expect(row.paidBillCount, 1);
    expect(row.unpaidBillCount, 0);
    expect(row.paidShortCount, 1);
    expect(row.difference, 190000);
    expect(row.needsReview, isTrue);
  });

  test(
    'no history creates no demand, and category does not change actual fees',
    () {
      final rows = buildBillingAudit(
        consumers: [
          consumer('NONE'),
          consumer('C', rate: 'COMMERCIAL'),
          consumer('10010100', rate: 'COMMERCIAL'),
        ],
        bills: [
          ...history('C', ['18000']),
          ...history('10010100', ['400']),
        ],
      );
      final empty = rows.firstWhere((e) => e.connectionNo == 'NONE');
      expect(empty.waterFee, 0);
      expect(empty.difference, 0);
      expect(empty.result, 'No generated bills');
      expect(rows.firstWhere((e) => e.connectionNo == 'C').difference, 0);
      expect(
        rows.firstWhere((e) => e.connectionNo == '10010100').category,
        'domestic',
      );
    },
  );

  test(
    'bad money and duplicate bill identities require review without a fabricated balance',
    () {
      final rows = buildBillingAudit(
        consumers: [consumer('BAD'), consumer('DUP'), consumer(' dup ')],
        bills: [
          ...history('BAD', ['invalid']),
          ...history('DUP', ['2400']),
          ...history('dup ', ['2400']),
        ],
      );
      expect(rows.length, 2);
      expect(rows.every((e) => e.difference == null && e.needsReview), isTrue);
      expect(rows.firstWhere((e) => e.connectionNo == 'DUP').billCount, 1);
      expect(auditAmountInPaisa('Rs. 2,400.25'), 240025);
      for (final value in [
        '',
        '-',
        '-2400',
        'abc2400',
        'NaN',
        '1.234',
        '999999999999999999999999',
      ]) {
        expect(auditAmountInPaisa(value), isNull, reason: value);
      }
    },
  );

  test('CSV reports actual generated demand, receipts and review data', () {
    final master = consumer('A')..['consumer_name'] = '=SUM(1,2)';
    final rows = buildBillingAudit(
      consumers: [master],
      bills: history('A', ['2400.25'], receipts: ['2000']),
    );
    final decoded = csv.decode(
      ExportService.billingAuditCsv(rows).replaceFirst('\ufeff', ''),
    );
    final header = decoded.first;
    expect(decoded[1][header.indexOf('Consumer Name')], "'=SUM(1,2)");
    expect(
      decoded[1][header.indexOf('Generated Water Fee')].toString(),
      '2400.25',
    );
    expect(decoded[1][header.indexOf('Water Balance')].toString(), '400.25');
    expect(header, contains('Expected Water Fee'));
    expect(header, contains('Total Missing Amount'));
    // Coverage estimates stay separate from actual generated demand and debt.
    expect(rows.single.waterFee, 240025);
    expect(rows.single.payableBalance, 40025);
  });

  test(
    'PDF supports chosen columns, pagination and rejects empty selection',
    () async {
      final rows = buildBillingAudit(
        consumers: [for (var i = 0; i < 70; i++) consumer('PDF$i')],
        bills: [
          for (var i = 0; i < 70; i++)
            ...history('PDF$i', ['4800'], receipts: ['0']),
        ],
      );
      final service = ExportService.instance;
      await expectLater(
        service.generateBillingAuditPdf(entries: rows, selectedColumnKeys: {}),
        throwsArgumentError,
      );
      final selections = {
        'selected': {
          'connection',
          'consumer',
          'bills',
          'paid',
          'unpaid',
          'water',
          'receipts',
          'balance',
        },
        'all': ExportService.billingAuditColumns.map((c) => c.key).toSet(),
        'single': {'connection'},
      };
      for (final selection in selections.entries) {
        final bytes = await service.generateBillingAuditPdf(
          entries: rows,
          selectedColumnKeys: selection.value,
          filterSummary: 'Sector A | Water balance due',
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        if (Platform.environment['AUDIT_PDF_PREVIEW'] == '1') {
          await File('scratch/audit-${selection.key}.pdf').writeAsBytes(bytes);
        }
      }
    },
  );

  group('database and audit page', () {
    late Database db;
    late DatabaseService service;
    setUp(() async {
      sqfliteFfiInit();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''CREATE TABLE consumers (
        id INTEGER PRIMARY KEY, connection_no TEXT, consumer_name TEXT,
        father_husband_name TEXT, sector TEXT, locality TEXT, address TEXT,
        rate_type TEXT, connection_date TEXT, connection_status TEXT,
        consumer_status TEXT, bill_status TEXT)''');
      service = DatabaseService.forTesting(db);
      for (final row in [
        consumer('SHORT'),
        consumer('MATCH'),
        consumer('NONE'),
      ]) {
        await db.insert('consumers', row);
      }
      await service.getBillHistoryCount();
      for (final row in [
        ...history('SHORT', ['4800'], receipts: ['2400']),
        ...history('MATCH', ['2400']),
      ]) {
        await db.insert('bill_history', row);
      }
    });
    tearDown(() => db.close());

    test(
      'reads all generated bills and their statuses without changing stored records',
      () async {
        final before = await db.query('bill_history');
        final rows = await service.getBillingAudit();
        expect(rows.first.connectionNo, 'SHORT');
        expect(rows.first.difference, 240000);
        expect(rows.first.unpaidBillCount, 1);
        expect(await db.query('bill_history'), before);
        expect(await db.query('bill_report_members'), isEmpty);
      },
    );

    testWidgets(
      'an unresolved receipt does not blank confirmed summary totals',
      (tester) async {
        await tester.runAsync(
          () => db.update(
            'bill_history',
            {'amount_received': 'invalid'},
            where: 'connection_no = ?',
            whereArgs: ['MATCH'],
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1500, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: service),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Confirmed subtotal; 1 unresolved excluded.'),
          findsNWidgets(2),
        );
        expect(find.textContaining('Cash receipts: Rs. 2,400'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('connection, bill and consumer filters match the main app', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await db.update(
          'consumers',
          {'connection_status': 'Closed', 'bill_status': 'Paid'},
          where: 'connection_no = ?',
          whereArgs: ['MATCH'],
        );
        await db.update(
          'consumers',
          {'consumer_status': 'In-Active', 'bill_status': 'Expired'},
          where: 'connection_no = ?',
          whereArgs: ['SHORT'],
        );
        await db.insert('consumers', consumer('NEW'));
        final newBill = history('NEW', ['405000'], receipts: ['0']).single
          ..['bill_type'] = 'New Connection';
        await db.insert('bill_history', newBill);
      });
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: BillingAuditScreen(database: service),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.text('Consumer MATCH'), findsNothing);
      expect(find.text('Consumer NEW'), findsNothing);
      Future<void> select(String current, String next) async {
        await tester.tap(
          find.widgetWithText(DropdownButtonFormField<String>, current),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        await tester.tap(find.text(next).last);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
      }

      await select('Regular Connection', 'Closed');
      expect(find.text('Consumer MATCH'), findsOneWidget);
      await select('All bills', 'Paid');
      await select('All consumer statuses', 'Active');
      expect(find.text('Consumer MATCH'), findsOneWidget);
      await select('Active', 'In-Active');
      expect(find.text('No connections match these filters.'), findsOneWidget);
      await select('Closed', 'All connection statuses');
      await select('Paid', 'Un-Paid');
      expect(find.text('Consumer SHORT'), findsOneWidget);
      await select('Un-Paid', 'Expired');
      expect(find.text('Consumer SHORT'), findsOneWidget);
      await select('Expired', 'All bills');
      await select('In-Active', 'All consumer statuses');
      await select('Regular / other bills', 'New Connection bills');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      expect(find.text('Consumer NEW'), findsOneWidget);
      expect(find.text('Consumer SHORT'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('all audit columns fit without hiding long names or amounts', (
      tester,
    ) async {
      const name = 'TEHSIL HEADQUARTER HOSPITAL CHISHTIAN';
      const location = 'COMMERCIAL\n3 inch line connection';
      await tester.runAsync(() async {
        await db.insert('consumers', {
          ...consumer('66160004'),
          'consumer_name': name,
          'sector': 'COMMERCIAL',
          'locality': '3 inch line connection',
        });
        await db.insert(
          'bill_history',
          history('66160004', ['123456789.12'], receipts: ['240000']).single,
        );
        if (Platform.environment['AUDIT_SCREENSHOT'] == '1') {
          for (final family in ['Segoe UI', 'Roboto', 'MaterialIcons']) {
            final path = family == 'MaterialIcons'
                ? 'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
                : 'C:/Windows/Fonts/segoeui.ttf';
            await (FontLoader(
                  family,
                )..addFont(File(path).readAsBytes().then(ByteData.sublistView)))
                .load();
          }
        }
      });
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(1920, 1100));
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: service),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();
      for (final width in [1920.0, 1500.0, 1280.0, 600.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1100));
        await tester.pumpAndSettle();
        if (find.byType(DataTable).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.byType(DataTable),
            400,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull, reason: 'Width: $width');
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          ),
          findsNothing,
        );
        final table = tester.widget<DataTable>(find.byType(DataTable));
        expect(table.columns.length, 17);
        expect(table.columns[14].headingRowAlignment, MainAxisAlignment.center);
        for (final row in table.rows) {
          final cell = row.cells[14].child;
          expect(cell, isA<Center>());
          final count = find.descendant(
            of: find.byWidget(cell),
            matching: find.byType(Text),
          );
          expect(
            tester.getCenter(count).dx,
            closeTo(tester.getCenter(find.byWidget(cell)).dx, 1),
          );
        }
        for (final column in table.columns) {
          final rect = tester.getRect(find.byWidget(column.label));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        for (final value in [name, location, 'Rs. 123,456,789.12']) {
          final text = tester.widget<Text>(find.text(value));
          expect(text.maxLines, isNull);
          expect(text.overflow, isNot(TextOverflow.ellipsis));
        }
        if (Platform.environment['AUDIT_SCREENSHOT'] == '1' && width >= 1280) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'scratch/audit-fit-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'history close and hot reload refresh totals while preserving audit position',
      (tester) async {
        await tester.runAsync(() async {
          for (var i = 0; i < 35; i++) {
            await db.insert('consumers', consumer('P$i'));
            await db.insert('bill_history', history('P$i', ['1200']).single);
          }
        });
        final auditService = _AuditTrackingService(db);
        await tester.binding.setSurfaceSize(const Size(1500, 950));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: auditService),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        await tester.tap(
          find.text('Billing period, sessions & amount filters'),
        );
        await tester.pumpAndSettle();
        final vertical = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        vertical.jumpTo(vertical.maxScrollExtent);
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        expect(find.text('21–38 of 38'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          ),
          findsNothing,
        );
        final historyButton = find
            .byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Open bill history',
            )
            .first;
        await tester.ensureVisible(historyButton);
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        final beforeVertical = vertical.pixels;
        final sort = tester
            .widget<DataTable>(find.byType(DataTable))
            .sortColumnIndex;
        await tester.tap(historyButton);
        await tester.pump();
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        expect(find.byType(BillHistoryDialog), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(BillHistoryDialog),
            matching: find.byType(SelectionArea),
          ),
          findsOneWidget,
        );
        final openedConnection = tester
            .widget<BillHistoryDialog>(find.byType(BillHistoryDialog))
            .initialConnectionNo;
        await tester.runAsync(() async {
          await db.update(
            'bill_history',
            {'amount_received': '1000'},
            where: 'connection_no = ?',
            whereArgs: [openedConnection],
          );
        });
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        expect(find.byType(BillHistoryDialog), findsNothing);
        expect(auditService.requests.where((id) => id == null).length, 1);
        expect(auditService.requests.last, openedConnection);
        expect(find.text('21–38 of 38'), findsOneWidget);
        expect(vertical.pixels, closeTo(beforeVertical, 1));
        expect(
          tester.widget<DataTable>(find.byType(DataTable)).sortColumnIndex,
          sort,
        );
        vertical.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.text('Rs. 46,600'), findsOneWidget);
        vertical.jumpTo(beforeVertical);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await db.update(
            'bill_history',
            {'amount_received': '1200'},
            where: 'connection_no = ?',
            whereArgs: [openedConnection],
          );
          await db.update(
            'bill_history',
            {'amount_received': '2000'},
            where: 'connection_no = ?',
            whereArgs: ['MATCH'],
          );
        });
        final reassembled = tester.binding.reassembleApplication();
        await tester.pump();
        await reassembled;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle();
        expect(find.text('21–38 of 38'), findsOneWidget);
        expect(vertical.pixels, closeTo(beforeVertical, 1));
        vertical.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.text('Rs. 46,400'), findsOneWidget);
        expect(
          find.widgetWithText(
            DropdownButtonFormField<String>,
            'Regular Connection',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('filters, sorts, chooses PDF columns and fits smaller windows', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (Platform.environment['AUDIT_SCREENSHOT'] == '1') {
        await tester.runAsync(() async {
          for (final name in ['Segoe UI', 'Roboto', 'MaterialIcons']) {
            final path = name == 'MaterialIcons'
                ? 'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
                : 'C:/Windows/Fonts/segoeui.ttf';
            await (FontLoader(
                  name,
                )..addFont(File(path).readAsBytes().then(ByteData.sublistView)))
                .load();
          }
        });
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: service),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.text('Generated bills & water fee recovery'), findsOneWidget);
      expect(find.text('Generated bills: 2'), findsOneWidget);
      expect(find.text('Consumer SHORT'), findsOneWidget);
      expect(find.text('Six-month periods'), findsNothing);
      expect(find.text('Fine Collected'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      if (Platform.environment['AUDIT_SCREENSHOT'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'scratch/billing-audit-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Consumer'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DataTable>(find.byType(DataTable)).sortColumnIndex,
        2,
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'All results'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Water balance due').last);
      await tester.pumpAndSettle();
      expect(find.text('Consumer MATCH'), findsNothing);
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Export all 1 filtered connections, grouped by sector. Current sort order is kept within each sector.',
        ),
        findsOneWidget,
      );
      expect(find.text('Missing Bill Amount'), findsOneWidget);
      expect(find.text('Total Amount'), findsOneWidget);
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${ExportService.billingAuditColumns.length + ExportService.periodCheckColumnKeys.length} columns selected',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Save PDF'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Connection No'));
      await tester.pumpAndSettle();
      expect(find.text('1 columns selected'), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Save PDF'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => db.update(
          'bill_history',
          {'amount_received': '4800'},
          where: 'connection_no = ?',
          whereArgs: ['MATCH'],
        ),
      );
      await tester.tap(find.byTooltip('Refresh audit'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          DropdownButtonFormField<String>,
          'Water balance due',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unapplied receipts / advance').last);
      await tester.pumpAndSettle();
      expect(find.text('Consumer MATCH'), findsOneWidget);
      expect(find.text('Consumer SHORT'), findsNothing);
      expect(find.text('No water balance'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('audit-text-search')),
        'nonexistent',
      );
      await tester.pumpAndSettle();
      expect(find.text('No connections match these filters.'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(600, 900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
