import 'dart:io';
import 'dart:ui' as ui;
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/audit_period_check.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/widgets/billing_audit_pdf_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'bill_history_pdf_layout_test.dart' show contentStreams;

List<BillingAuditEntry> sample({bool unknown = false}) => buildBillingAudit(
  consumers: [
    for (final id in ['A', 'B', if (unknown) 'C'])
      {
        'connection_no': id,
        'consumer_name': 'Consumer $id',
        'sector': 'Chak No.46/F',
        'locality': 'Chak No. 46-F Zone B',
        'rate_type': 'DOMESTIC',
      },
  ],
  bills: [
    for (final id in ['A', 'B', if (unknown) 'C'])
      BillHistory(
        connectionNo: id,
        billNo: '1',
        billType: 'Regular',
        billingPeriod: '01/01/2026 - 30/06/2026',
        waterFee: id == 'A'
            ? '2400'
            : id == 'B'
            ? '4800'
            : 'invalid',
        totalBill: id == 'A' ? '2400' : '4800',
        status: 'Un-Paid',
      ).toMap(),
  ],
  asOf: DateTime(2026, 10, 27),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'filename follows explicit locality/sector, handles unsafe characters, and falls back to row scope',
    () {
      final rows = sample();
      final now = DateTime(2026, 10, 27, 15, 30);
      expect(
        ExportService.billingAuditPdfFileName(
          rows,
          selectedSector: 'Chak No.46/F',
          now: now,
        ),
        'Chak No.46_F_Water_Fee_Audit_27-10-2026_1530.pdf',
      );
      expect(
        ExportService.billingAuditPdfFileName(
          rows,
          selectedSector: 'Sector A',
          selectedLocality: 'Locality B',
          now: now,
        ),
        startsWith('Locality B_'),
      );
      expect(
        ExportService.billingAuditPdfFileName(
          rows,
          selectedSector: 'All sectors',
          now: now,
        ),
        startsWith('Chak No. 46-F Zone B_'),
      );
      expect(
        ExportService.billingAuditPdfFileName([], now: now),
        'Water_Fee_Audit_27-10-2026_1530.pdf',
      );
      expect(
        ExportService.billingAuditPdfFileName(
          rows,
          selectedSector: 'A:<B>"/\\|?*.',
          now: now,
        ),
        isNot(contains(RegExp(r'[<>:"/\\|?*]'))),
      );
    },
  );

  test('column totals sum all filtered rows and mark unresolved amounts', () {
    final totals = ExportService.billingAuditColumnTotals(
      sample(),
      periodFrom: DateTime(2026, 7, 1),
      periodTo: DateTime(2026, 12, 31),
    );
    expect(totals['water'], '7200.00');
    expect(totals['bills'], '2');
    expect(totals['balance'], '7200.00');
    expect(totals['missing_bill_amount'], '7200.00');
    expect(totals['total_amount'], '14400.00');
    expect(totals['missing_water_fee'], '7200.00');
    expect(totals['missing_amount'], '14400.00');
    expect(totals.containsKey('connection'), isFalse);
    expect(
      ExportService.billingAuditColumnTotals(sample(unknown: true))['water'],
      '7200.00*',
    );
  });

  test(
    'Total Missing Amount includes the water balance and missing fees',
    () async {
      final rows = buildBillingAudit(
        consumers: [
          {'connection_no': '13010086', 'rate_type': 'DOMESTIC'},
        ],
        bills: [
          BillHistory(
            connectionNo: '13010086',
            billNo: '1',
            billType: 'Regular',
            billingPeriod: '01/07/2023 - 30/06/2026',
            waterFee: '14400',
            totalBill: '14400',
            amountReceived: '7300',
            status: 'Un-Paid',
          ).toMap(),
        ],
        asOf: DateTime(2026, 10, 27),
      );
      final from = DateTime(2026, 7, 1);
      final to = DateTime(2026, 12, 31);
      final totals = ExportService.billingAuditColumnTotals(
        rows,
        periodFrom: from,
        periodTo: to,
      );
      expect(totals['balance'], '7100.00');
      expect(totals['missing_water_fee'], '2400.00');
      expect(totals['missing_amount'], '9500.00');
      final column = ExportService.billingAuditColumns.singleWhere(
        (column) => column.key == 'missing_amount',
      );
      expect(column.valueFor(rows.single, from, to), '9500.00');
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: rows,
        selectedColumnKeys: {
          'connection',
          'balance',
          'missing_water_fee',
          'missing_amount',
        },
        periodFrom: from,
        periodTo: to,
      );
      expect(contentStreams(bytes).join('\n'), contains('(9,500)'));
    },
  );

  test(
    'PDF has one concise first-page header and no footer or summary',
    () async {
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: [for (var i = 0; i < 60; i++) ...sample()],
        selectedColumnKeys: {
          'connection',
          'consumer',
          'balance',
          'missing_amount',
        },
        selectedSector: 'Chak No.46/F',
        filterSummary: 'Regular / other bills | Domestic | All session results',
        periodFrom: DateTime(2026, 7, 1),
        periodTo: DateTime(2026, 12, 31),
      );
      await pdfrxInitialize();
      final doc = await PdfDocument.openData(bytes);
      try {
        expect(doc.pages.length, greaterThan(1));
        final pages = [
          for (final page in doc.pages) (await page.loadText())!.fullText,
        ];
        expect(pages.first, contains('Water Fees Shortfall'));
        expect(
          pages.first,
          contains(
            'Water balance: Rs. 432,000 | Missing bill amount: Rs. 432,000 | '
            'Total amount: Rs. 864,000 | Chak No.46/F | 01/07/2026 - 31/12/2026',
          ),
        );
        expect(pages.first, contains('SR #'));
        expect(pages.last, contains('120'));
        expect(pages.first, contains('Chak No.46/F | 01/07/2026 - 31/12/2026'));
        expect(pages.first, contains('01/07/2026 - 31/12/2026'));
        expect(pages.first, contains('Water balance:'));
        for (final page in pages.skip(1)) {
          expect(page, isNot(contains('Water Fees Shortfall')));
          expect(page, isNot(contains('Water balance:')));
        }
        final text = pages.join(' ');
        for (final unwanted in [
          'All session results',
          'Generated:',
          'Totals - all',
          'Water Balance =',
          'Page 1 of',
        ]) {
          expect(text, isNot(contains(unwanted)));
        }
        expect(text, contains('TOTAL'));
      } finally {
        await doc.dispose();
      }
    },
  );

  test('PDF renders the total row and all selected numeric totals', () async {
    final bytes = await ExportService.instance.generateBillingAuditPdf(
      entries: sample(),
      selectedColumnKeys: {
        'connection',
        'water',
        'bills',
        'balance',
        'missing_bill_amount',
        'total_amount',
      },
      periodFrom: DateTime(2026, 7, 1),
      periodTo: DateTime(2026, 12, 31),
    );
    final text = contentStreams(bytes).join('\n');
    expect(text, contains('(TOTAL)'));
    expect(text, contains('(7,200)'));
    expect(text, contains('(14,400)'));
    expect(text, isNot(contains('(unresolved)')));
    final numericOnly = await ExportService.instance.generateBillingAuditPdf(
      entries: sample(),
      selectedColumnKeys: {'water'},
    );
    final numericText = contentStreams(numericOnly).join('\n');
    expect(numericText, contains('(TOTAL)'));
    expect(numericText, contains('(7,200)'));
  });

  test(
    'all selectable columns can be exported together with session notes and totals',
    () async {
      final rows = sample();
      final checks = {
        for (final e in rows)
          e.connectionNo: checkAuditPeriod(
            e.periodBills,
            DateTime(2023, 7, 1),
            DateTime(2026, 12, 31),
          ),
      };
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: rows,
        selectedColumnKeys: {
          ...ExportService.billingAuditColumns.map((c) => c.key),
          ...ExportService.periodCheckColumnKeys,
        },
        periodChecks: checks,
      );
      expect(contentStreams(bytes).join('\n'), contains('(TOTAL)'));
    },
  );

  test(
    'shortfall defaults, minimum type size and whole-rupee layout remain readable',
    () async {
      expect(ExportService.defaultBillingAuditPdfColumns, {
        'connection',
        'consumer',
        'bills',
        'paid',
        'unpaid',
        'water',
        'receipts',
        'balance',
        'missing_bill_amount',
        'missing_bill_count',
        'missing_water_fee',
        'missing_amount',
      });
      final rows = buildBillingAudit(
        consumers: [
          for (var i = 0; i < 8; i++)
            {
              'connection_no': '1301000$i',
              'consumer_name': 'SAMPLE CONSUMER ${i + 1}',
              'rate_type': 'DOMESTIC',
            },
        ],
        bills: [
          for (var i = 0; i < 8; i++)
            BillHistory(
              connectionNo: '1301000$i',
              billNo: '${6000000 + i}',
              billType: 'Regular',
              billingPeriod: '01/01/2026 - 30/06/2026',
              status: 'Un-Paid',
              waterFee: i == 0 ? '2400.49' : '2400.51',
              totalBill: i == 0 ? '2400.49' : '2400.51',
            ).toMap(),
        ],
        asOf: DateTime(2026, 10, 27),
      );
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: rows,
        selectedColumnKeys: ExportService.defaultBillingAuditPdfColumns,
        filterSummary:
            'Sector: Chak No.46/F | Regular bills | All filtered connections',
      );
      final streams = contentStreams(bytes).join('\n');
      final text = RegExp(
        r'\[\((.*?)\)\]TJ',
      ).allMatches(streams).map((m) => m[1]!).join(' ');
      expect(text, contains('Water Fees Shortfall'));
      expect(text, contains('2,400'));
      expect(text, contains('2,401'));
      expect(text, isNot(matches(RegExp(r'.*\b\d+\.\d{2}\b.*'))));
      final sizes = RegExp(
        r'/F\d+\s+(\d+(?:\.\d+)?)\s+Tf',
      ).allMatches(streams).map((m) => double.parse(m[1]!)).toList();
      expect(sizes, isNotEmpty);
      expect(sizes.every((size) => size >= 9), isTrue);
      expect(sizes, containsAll([20.0, 12.0]));
      await pdfrxInitialize();
      final doc = await PdfDocument.openData(bytes);
      try {
        expect(doc.pages.length, 1);
        if (Platform.environment['AUDIT_SHORTFALL_PREVIEW'] == '1') {
          final page = doc.pages.first;
          final rendered = await page.render(
            fullWidth: 1800,
            fullHeight: 1800 * page.height / page.width,
          );
          final image = await rendered!.createImage();
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'scratch/water-fees-shortfall-preview.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
            rendered.dispose();
          }
        }
      } finally {
        await doc.dispose();
      }
    },
  );

  testWidgets(
    'every report column is available without an active period filter',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: BillingAuditPdfDialog(
            entries: sample(),
            filterSummary: 'All results',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .where((tile) => tile.value == true)
            .length,
        12,
      );
      final available = find.byType(CheckboxListTile);
      expect(
        available,
        findsNWidgets(
          ExportService.billingAuditColumns.length +
              ExportService.periodCheckColumnKeys.length,
        ),
      );
      expect(
        find.widgetWithText(CheckboxListTile, 'Missing Bill Amount'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(CheckboxListTile, 'Total Amount'),
        findsOneWidget,
      );
      for (final label in ['Total Amount', 'Estimated Water Fee Shortfall']) {
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, label),
              )
              .value,
          isFalse,
        );
      }
      expect(
        find.widgetWithText(CheckboxListTile, 'Missing / Incomplete Sessions'),
        findsOneWidget,
      );
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckboxListTile>(available)
            .every((tile) => tile.value == true),
        isTrue,
      );
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckboxListTile>(available)
            .every((tile) => tile.value == false),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
