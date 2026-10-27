import 'dart:io';
import 'dart:ui' as ui;
import 'package:consumer_search_engine/models/audit_period_check.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/screens/billing_audit_screen.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/theme/app_theme.dart';
import 'package:consumer_search_engine/widgets/billing_audit_pdf_dialog.dart';
import 'package:consumer_search_engine/widgets/copyable_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;
import 'bill_history_pdf_layout_test.dart' show contentStreams;

const periods = [
  '01/07/2025 - 31/07/2025',
  '01/08/2025 - 31/08/2025',
  '01/09/2025 - 30/09/2025',
  '01/10/2025 - 31/12/2025',
  '01/01/2026 - 30/06/2026',
  '01/07/2026 - 31/12/2026',
];

List<Map<String, Object?>> history(
  String id, {
  Set<int> omit = const {},
  String? fee,
}) => [
  for (var i = 0; i < periods.length; i++)
    if (!omit.contains(i))
      BillHistory(
        connectionNo: id,
        billNo: '${100 + i}',
        billType: 'Regular',
        billingPeriod: periods[i],
        waterFee:
            fee ??
            (i < 3
                ? '400'
                : i == 3
                ? '1200'
                : '2400'),
        totalBill:
            fee ??
            (i < 3
                ? '400'
                : i == 3
                ? '1200'
                : '2400'),
        status: 'Un-Paid',
      ).toMap(),
];

BillingAuditEntry entry(List<Map<String, Object?>> bills) => buildBillingAudit(
  consumers: [
    {'connection_no': 'A', 'rate_type': 'DOMESTIC'},
  ],
  bills: bills,
  billGroup: 'regular',
).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  final from = DateTime(2025, 7, 1), to = DateTime(2026, 12, 31);

  test(
    'session choices start in July 2023, use June 30 and stop at the current session',
    () {
      final choices = auditBillingSessions(DateTime(2026, 10, 27));
      expect(choices, hasLength(7));
      expect(choices.first, (
        start: DateTime(2023, 7, 1),
        end: DateTime(2023, 12, 31),
      ));
      expect(choices[1], (
        start: DateTime(2024, 1, 1),
        end: DateTime(2024, 6, 30),
      ));
      expect(choices.last, (
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 12, 31),
      ));
      expect(
        auditBillingSessions(DateTime(2026, 6, 30)).last.end,
        DateTime(2026, 6, 30),
      );
      expect(
        auditBillingSessions(DateTime(2026, 7, 1)).last.end,
        DateTime(2026, 12, 31),
      );
    },
  );

  test(
    'four split 2025 bills and two half-years count as three sessions, not six bills',
    () {
      final e = entry(history('A'));
      final check = checkAuditPeriod(e.periodBills, from, to);
      expect(e.billCount, 6);
      expect(e.waterFee, 720000);
      expect(check.sessions.length, 3);
      expect(check.completeSessions, 3);
      expect(check.present, isTrue);
      expect(check.missingSessions, isEmpty);
      final csv = ExportService.billingAuditCsv(
        [e],
        periodChecks: {'A': check},
      );
      expect(csv, contains('Six-Month Sessions Complete'));
      expect(csv, contains('3/3 sessions complete'));
    },
  );

  test(
    'missing one monthly issue or a half-year identifies the exact session and gap',
    () {
      final e = entry(history('A', omit: {1, 5}));
      final check = checkAuditPeriod(e.periodBills, from, to);
      expect(check.completeSessions, 1);
      expect(check.present, isFalse);
      expect(
        check.missingSessions,
        contains('01/07/2025 - 31/12/2025: missing 01/08/2025 - 31/08/2025'),
      );
      expect(check.missingSessions, contains('01/07/2026 - 31/12/2026'));
      expect(
        checkAuditPeriod(
          e.periodBills,
          DateTime(2026, 1, 1),
          DateTime(2026, 6, 30),
        ).present,
        isTrue,
      );
    },
  );

  test(
    'period PDF exports include session counts and exact missing dates',
    () async {
      final e = entry(history('A', omit: {1, 5}));
      final check = checkAuditPeriod(e.periodBills, from, to);
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: [e],
        selectedColumnKeys: {
          'connection',
          'sessions_complete',
          'missing_sessions',
        },
        periodChecks: {'A': check},
      );
      final text = RegExp(r'\[\((.*?)\)\]TJ')
          .allMatches(contentStreams(bytes).join('\n'))
          .map((m) => m[1]!)
          .join(' ');
      expect(text, contains('1/3 sessions complete'));
      expect(text, contains('01/08/2025'));
      expect(text, contains('31/08/2025'));
    },
  );

  test(
    'combined, overlapping and duplicate rows cover dates only once including leap days',
    () {
      final check = checkAuditPeriod(
        [
          AuditBillPeriod('1', DateTime(2024, 1, 1), DateTime(2024, 12, 31)),
          AuditBillPeriod('2', DateTime(2024, 2, 1), DateTime(2024, 2, 29)),
          AuditBillPeriod('2', DateTime(2024, 2, 1), DateTime(2024, 2, 29)),
        ],
        DateTime(2024, 2, 29),
        DateTime(2024, 7, 1),
      );
      expect(check.sessions.length, 2);
      expect(check.completeSessions, 2);
      expect(check.present, isTrue);
    },
  );

  test(
    'partial dates, one-day gaps, no history, invalid dates and zero-fee adjustments are safe',
    () {
      expect(checkAuditPeriod([], from, to).completeSessions, 0);
      expect(checkAuditPeriod([], from, to).sessions.length, 3);
      expect(() => checkAuditPeriod([], to, from), throwsArgumentError);
      final partial = checkAuditPeriod(
        [AuditBillPeriod('1', DateTime(2026, 7, 2), to)],
        DateTime(2026, 7, 1),
        to,
      );
      expect(
        partial.missingSessions,
        contains('missing 01/07/2026 - 01/07/2026'),
      );
      final unknown = checkAuditPeriod(
        [const AuditBillPeriod('bad', null, null)],
        from,
        to,
      );
      expect(unknown.presenceLabel, 'Unconfirmed gaps');
      expect(unknown.details, contains('bad'));
      final e = entry([
        BillHistory(
          connectionNo: 'A',
          billNo: '0',
          billType: 'Regular',
          billingPeriod: '01/07/2026 - 01/07/2026',
          waterFee: '0',
        ).toMap(),
      ]);
      expect(e.periodBills, isEmpty);
    },
  );

  testWidgets('visible copy icon copies the complete identifier', (
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
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: CopyableText('00123456789', showIcon: true),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(copied, '00123456789');
  });

  testWidgets(
    'audit pickers, present/missing lists, threshold and exports compose',
    (tester) async {
      final capture = Platform.environment['AUDIT_PERIOD_SCREENSHOT'] == '1';
      if (capture) {
        await tester.runAsync(() async {
          for (final name in ['Segoe UI', 'Roboto', 'Ahem', 'MaterialIcons']) {
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
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        for (final id in ['COMPLETE', 'MISSING', 'NONE', 'EXACT', 'ABOVE']) {
          await db.insert('consumers', {
            'connection_no': id,
            'consumer_name': 'Consumer $id',
            'connection_status': 'Regular Connection',
            'rate_type': 'DOMESTIC',
            'sector': switch (id) {
              'COMPLETE' => 'Hafiz Hotel',
              'MISSING' => 'Hussain Colony',
              'NONE' => 'HAIDAR PURA',
              'EXACT' => 'Gulberg Town',
              _ => 'City area',
            },
          });
          final bills = switch (id) {
            'COMPLETE' => history(id),
            'MISSING' => history(id, omit: {1, 5}),
            'EXACT' => history(id, omit: {0, 1, 2, 3, 4}, fee: '5000'),
            'ABOVE' => history(id, omit: {0, 1, 2, 3, 4}, fee: '5000.01'),
            _ => <Map<String, Object?>>[],
          };
          for (final bill in bills) {
            await db.insert('bill_history', bill);
          }
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
          ),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.byType(DataTable).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audit-period-from')), findsOneWidget);
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audit-period-from')), findsNothing);
      await tester.tap(find.text('Billing period, sessions & amount filters'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audit-period-from')), findsOneWidget);
      DropdownButtonFormField<DateTime> selector(String key) =>
          tester.widget<DropdownButtonFormField<DateTime>>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(DropdownButtonFormField<DateTime>),
            ),
          );
      expect(selector('audit-period-from').initialValue, DateTime(2023, 7, 1));
      expect(selector('audit-period-to').initialValue, DateTime(2023, 12, 31));
      expect(
        tester
            .widget<DropdownButton<DateTime>>(
              find.descendant(
                of: find.byKey(const ValueKey('audit-period-from')),
                matching: find.byType(DropdownButton<DateTime>),
              ),
            )
            .items!
            .map((item) => item.value),
        orderedEquals(
          auditBillingSessions(DateTime.now()).map((session) => session.start),
        ),
      );
      Future<void> date(String key, String value) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(value).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(value).last);
        await tester.pumpAndSettle();
      }

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

      await date('audit-period-from', '01/01/2024');
      expect(selector('audit-period-to').initialValue, DateTime(2024, 6, 30));
      expect(
        tester
            .widget<DropdownButton<DateTime>>(
              find.descendant(
                of: find.byKey(const ValueKey('audit-period-to')),
                matching: find.byType(DropdownButton<DateTime>),
              ),
            )
            .items!
            .first
            .value,
        DateTime(2024, 6, 30),
      );
      await date('audit-period-from', '01/07/2025');
      expect(selector('audit-period-to').initialValue, DateTime(2025, 12, 31));
      await date('audit-period-to', '31/12/2026');
      await choose('All session results', 'All sessions complete');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 1);
      expect(find.text('Consumer COMPLETE'), findsOneWidget);
      expect(find.textContaining('3/3 sessions complete'), findsOneWidget);
      await tester.ensureVisible(find.text('Export PDF / choose columns'));
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<BillingAuditPdfDialog>(
        find.byType(BillingAuditPdfDialog),
      );
      expect(dialog.entries.single.connectionNo, 'COMPLETE');
      expect(dialog.periodChecks['COMPLETE']!.completeSessions, 3);
      expect(find.text('Missing / Incomplete Sessions'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await choose('All sessions complete', 'Missing / incomplete sessions');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 4);
      expect(find.text('Consumer COMPLETE'), findsNothing);
      final detailsButton = find.text('View session details').first;
      await tester.ensureVisible(detailsButton);
      await tester.pumpAndSettle();
      await tester.tap(detailsButton);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('01/07/2025 - 31/12/2025: missing'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      if (capture) {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'scratch/audit-period-filters.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await choose('Missing / incomplete sessions', 'All session results');
      await date('audit-period-from', '01/07/2026');
      await choose('All period results', 'Period present');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 3);
      await choose('Period present', 'Period missing / incomplete');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 2);
      await choose('Period missing / incomplete', 'All period results');
      await tester.ensureVisible(
        find.byKey(const ValueKey('audit-amount-threshold')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('audit-amount-threshold')),
        '5,000',
      );
      await tester.pumpAndSettle();
      expect(find.text('Consumer ABOVE'), findsOneWidget);
      expect(find.text('Consumer EXACT'), findsNothing);
      expect(find.text('Consumer NONE'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('audit-amount-threshold')),
        'invalid',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid non-negative rupee amount'),
        findsOneWidget,
      );
      expect(find.byType(DataTable), findsNothing);
      await tester.ensureVisible(find.text('Reset period & amount filters'));
      await tester.tap(find.text('Reset period & amount filters'));
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 5);
      expect(selector('audit-period-from').initialValue, DateTime(2023, 7, 1));
      expect(selector('audit-period-to').initialValue, DateTime(2023, 12, 31));
      await tester.ensureVisible(find.text('All sectors'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All sectors'));
      await tester.pumpAndSettle();
      final dialogSearch = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogSearch, 'H');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Hafiz Hotel'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Hussain Colony'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Gulberg Town'),
        ),
        findsNothing,
      );
      await tester.enterText(dialogSearch, 'hUsSaIn');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Hussain Colony'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 1);
      expect(find.text('Consumer MISSING'), findsOneWidget);
      await tester.ensureVisible(find.text('Hussain Colony').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hussain Colony').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset Filter'));
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 5);
      await tester.tap(find.text('All sectors'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Checkboxes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Hafiz Hotel'));
      await tester.enterText(dialogSearch, 'hussain');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Hussain Colony'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 2);
      expect(find.text('Consumer COMPLETE'), findsOneWidget);
      expect(find.text('Consumer MISSING'), findsOneWidget);
      expect(find.text('Consumer ABOVE'), findsNothing);
      await tester.ensureVisible(find.text('Export PDF / choose columns'));
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      final combined = tester.widget<BillingAuditPdfDialog>(
        find.byType(BillingAuditPdfDialog),
      );
      expect(
        combined.entries.map((e) => e.connectionNo),
        unorderedEquals(['COMPLETE', 'MISSING']),
      );
      expect(combined.selectedSector, 'Hafiz Hotel, Hussain Colony');
      expect(
        ExportService.billingAuditTotals(combined.entries).waterBalance,
        combined.entries.fold<int>(0, (sum, e) => sum + e.payableBalance!),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('2 sectors selected'));
      await tester.tap(find.text('2 sectors selected'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Hafiz Hotel'),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Hafiz Hotel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 2);
      await tester.tap(find.text('2 sectors selected'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Single sector'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Gulberg Town'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 1);
      expect(find.text('Consumer EXACT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
