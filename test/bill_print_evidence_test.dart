import 'dart:io';
import 'package:consumer_search_engine/services/bill_print_evidence.dart';
import 'package:consumer_search_engine/services/pdf_bill_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/material.dart';
import 'package:consumer_search_engine/widgets/bill_print_evidence_dialog.dart';

Future<void> printPdf(
  String path, {
  String period = '01/01/2026 TO 30/06/2026',
  String fee = '2,400',
  String id = '0010010002',
  String bill = '6156964',
}) async {
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      build: (_) => pw.Column(
        children: [
          pw.Text('Name: TEST CONSUMER'),
          pw.Text('Connection No $id'),
          pw.Text('Bill No $bill'),
          pw.Text('Sector: Test Sector'),
          pw.Text('Locality: Test Locality Zone A'),
          pw.Text('Issue Date 01/01/2026'),
          pw.Text('Due Date 14/03/2026'),
          pw.Text('Billing Period: $period'),
          pw.Text('Water Fee Rs. $fee'),
          pw.Text('Arrears Rs. 5,280'),
          pw.Text('PAYABLE WITHIN DUE DATE Rs. 7,683'),
        ],
      ),
    ),
  );
  await File(path).writeAsBytes(await doc.save());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, input;
  late BillPrintEvidenceArchive archive;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await pdfrxInitialize();
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('print-evidence-');
    input = await Directory(p.join(temp.path, 'input')).create();
    archive = BillPrintEvidenceArchive(
      PdfBillLibrary(Directory(p.join(temp.path, 'archive'))),
    );
    await archive.open();
  });
  tearDown(() async {
    await archive.library.close();
    await temp.delete(recursive: true);
  });

  test(
    'extracts only printed billing periods and exact integer amounts; never substitutes issue/due/history dates',
    () {
      final row = parsePrintedBillEvidence(
        'Issue Date 01/01/2026\nBilling Period Jan 26 - Jun 26\nDue Date 14/03/2026\nWater Fee Rs. 2,400\nArrears Rs. 5,280\nPAYABLE WITHIN DUE DATE Rs. 7,683\nBilling Period: 01/01/2026 TO 30/06/2026 Sector: Test',
      );
      expect(row['period_from'], '2026-01-01');
      expect(row['period_to'], '2026-06-30');
      expect(row['printed_water_fee'], 240000);
      expect(row['printed_arrears'], 528000);
      expect(row['printed_payable'], 768300);
      expect(
        parsePrintedBillEvidence(
          'Billing Period Jul 2025 - Dec 2025',
        )['period_to'],
        '2025-12-31',
      );
      expect(
        parsePrintedBillEvidence(
          'Issue Date 01/01/2026\nDue Date 30/06/2026',
        )['period_from'],
        isNull,
      );
      expect(
        parsePrintedBillEvidence(
          'Billing Period: 31/02/2026 TO 30/06/2026',
        )['period_from'],
        isNull,
      );
    },
  );

  test(
    'folder import preserves same-name versions, skips exact copies and matches exact connection/session',
    () async {
      final first = p.join(input.path, 'Bills.pdf');
      await printPdf(first);
      await File(first).copy(p.join(input.path, 'Identical.pdf'));
      final second = await Directory(p.join(input.path, 'older')).create();
      await printPdf(
        p.join(second.path, 'Bills.pdf'),
        period: '01/07/2026 TO 31/12/2026',
        bill: '7000000',
      );
      final imported = await archive.importFolder(input.path);
      expect(imported.imported, 2);
      expect(imported.skipped, 1);
      final rows = await archive.find(
        '0010010002',
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 6, 30),
      );
      expect(rows, hasLength(1));
      expect(rows.single['bill_no'], '6156964');
      expect(await archive.find('10010002'), isEmpty);
      expect(await archive.find('0010010002'), hasLength(2));
      final rerun = await archive.importFolder(input.path);
      expect(rerun.imported, 0);
      expect(rerun.skipped, 3);
      await File(first).delete(); // owned copy remains available independently.
      await archive.verify(rows.single);
      final page = await archive.library.exportPages(rows);
      final doc = await PdfDocument.openData(page);
      try {
        expect(doc.pages, hasLength(1));
        expect(
          (await doc.pages.first.loadText())!.fullText,
          contains('6156964'),
        );
      } finally {
        await doc.dispose();
      }
    },
  );

  test(
    'all copies remain stored while identical bill pages are grouped; conflicting print versions stay separate',
    () async {
      await printPdf(p.join(input.path, 'Locality.pdf'));
      final r1 = await archive.importFolder(input.path);
      expect(r1.imported, 1);
      await printPdf(
        p.join(input.path, 'Merged.pdf'),
      ); // different PDF metadata, same page content
      await printPdf(p.join(input.path, 'Changed.pdf'), fee: '1,200');
      await archive.importFolder(input.path);
      final rows = await archive.find('0010010002');
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r['printed_water_fee']),
        containsAll([240000, 120000]),
      );
      expect((await archive.stats()).files, greaterThanOrEqualTo(2));
    },
  );

  test(
    'backup restores original bytes and evidence index; changed PDFs fail verification',
    () async {
      await printPdf(p.join(input.path, 'Bills.pdf'));
      await archive.importFolder(input.path);
      final rows = await archive.find('0010010002');
      final backup = await archive.backup(temp.path);
      await File(
        archive.library.filePath('${rows.single['file_id']}'),
      ).writeAsString('tampered');
      await expectLater(archive.verify(rows.single), throwsFormatException);
      await archive.restore(backup);
      final restored = await archive.find('0010010002');
      expect(restored.single['bill_no'], '6156964');
      expect(restored.single['period_from'], '2026-01-01');
      await archive.verify(restored.single);
    },
  );

  test(
    'deleting one archived PDF removes its index but keeps originals and other files',
    () async {
      final path = p.join(input.path, 'First.pdf');
      await printPdf(path);
      await printPdf(p.join(input.path, 'Second.pdf'), id: 'OTHER', bill: '2');
      await archive.importFiles([path, p.join(input.path, 'Second.pdf')]);
      final row = (await archive.find('0010010002')).single;
      await archive.library.deleteFile('${row['file_id']}');
      expect(await archive.find('0010010002'), isEmpty);
      expect(await File(path).exists(), isTrue);
      expect(await archive.find('OTHER'), hasLength(1));
      expect((await archive.stats()).files, 1);
      expect(
        await archive.library.db.rawQuery('PRAGMA foreign_key_check'),
        isEmpty,
      );
    },
  );

  test(
    'unknown periods remain reviewable but cannot match a selected session; cancelled imports keep existing data',
    () async {
      await printPdf(p.join(input.path, 'Unknown.pdf'), period: 'not supplied');
      await archive.importFolder(input.path);
      expect((await archive.stats()).review, 1);
      expect(await archive.find('0010010002'), hasLength(1));
      expect(
        await archive.find(
          '0010010002',
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 6, 30),
        ),
        isEmpty,
      );
      final result = await archive.importFolder(
        input.path,
        cancelled: () => true,
      );
      expect(result.cancelled, isTrue);
      expect((await archive.stats()).files, 1);
    },
  );

  testWidgets('archive exposes import and confirmed per-file deletion', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await printPdf(p.join(input.path, 'Bills.pdf'));
      await archive.importFolder(input.path);
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BillPrintArchiveDialog(archive: archive)),
      ),
    );
    for (
      var i = 0;
      i < 40 && find.byTooltip('Delete archived PDF').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Import PDF folder'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete archived PDF'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this archived PDF?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Bills.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
