import 'dart:io';

import 'package:consumer_search_engine/services/pdf_bill_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> makePdf(
  String path, {
  String name = 'MUHAMMAD AHMAD',
  String connection = '0401001',
  int count = 2,
  bool mixedLocalities = false,
}) async {
  final doc = pw.Document();
  for (var i = 1; i <= count; i++) {
    doc.addPage(
      pw.Page(
        build: (_) => pw.Column(
          children: [
            pw.Text('Name: $name'),
            pw.Text('F/H. Name: ALI'),
            pw.Text('Mobile#: 03001234567'),
            pw.Text('Address: HOUSE $i MAIN ROAD'),
            pw.Text('Sector: TEST SECTOR'),
            pw.Text(
              'Locality: ${mixedLocalities && i == 2 ? 'OTHER LOCALITY' : 'TEST LOCALITY'}',
            ),
            pw.Text('Connection Type: Water Residential'),
            pw.Text('Reference #'),
            pw.Text('26770120201000011117'),
            pw.Text('Bill No ${7000 + i}'),
            pw.Text('Connection No $connection'),
            pw.Text('Old Conn. 15'),
          ],
        ),
      ),
    );
  }
  await File(path).writeAsBytes(await doc.save());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PdfBillLibrary library;
  late String input;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await pdfrxInitialize();
  });
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('pdf-bills-test-');
    library = PdfBillLibrary(Directory(p.join(temporary.path, 'library')));
    await library.open();
    input = p.join(temporary.path, 'Bills.pdf');
    await makePdf(input);
  });
  tearDown(() async {
    await library.close();
    await temporary.delete(recursive: true);
  });

  test('CSV mapping and bill labels preserve identifiers and normalize names', () {
    final mappings = parsePdfLocalities(
      '\ufeff"Locality","Sector","PDF Filename"\r\n"A, B","Sector A","Bills.pdf"',
    );
    expect(mappings['bills.pdf']!['locality'], 'A, B');
    expect(() => parsePdfLocalities('name\ninvalid'), throwsFormatException);
    final fields = parsePdfBill(
      'Name: MOHAMMAD AHMED\r\nMobile#: 03001234567\nReference #\n26770120201000011117\nConnection No 0401001\nOld Conn. 15',
    );
    expect(fields['consumer_name_search'], 'MUHAMMAD AHMAD');
    expect(fields['connection_no'], '0401001');
    expect(fields['reference'], '26770120201000011117');
    expect(fields['mobile'], '03001234567');
    expect(fields['old_connection_no'], '15');
  });

  test(
    'imports, multiword targeted search, CSV filters, pagination and vector export',
    () async {
      final csv = File(p.join(temporary.path, 'Localities.csv'));
      await csv.writeAsString(
        'Locality,Sector,PDF Filename\nMapped locality,Mapped sector,Bills.pdf',
      );
      await library.importPdfs([input], csvPath: csv.path);
      expect(
        (await library.search(
          query: 'ahmed mohammad',
          searchBy: 'consumer_name',
        )).total,
        2,
      );
      expect(
        (await library.search(query: '0401', searchBy: 'connection_no')).total,
        2,
      );
      expect(
        (await library.search(query: '7002', searchBy: 'bill_no')).total,
        1,
      );
      expect(
        (await library.search(
          query: '26770120201000011117',
          searchBy: 'reference',
        )).total,
        2,
      );
      expect(
        (await library.search(
          locality: 'Mapped locality',
          sector: 'Mapped sector',
        )).total,
        2,
      );
      expect(
        (await library.search(
          query: "' OR 1=1 --",
          searchBy: 'connection_no',
        )).total,
        0,
      );
      final result = await library.search(limit: 1, offset: 1);
      expect(result.total, 2);
      expect(result.rows.single['page'], 2);
      final output = await library.exportPages(result.rows);
      final pdf = await PdfDocument.openData(output);
      try {
        expect(pdf.pages.length, 1);
        expect(
          (await pdf.pages.first.loadText())!.fullText,
          contains('Bill No 7002'),
        );
      } finally {
        await pdf.dispose();
      }
      final id = '${(await library.files()).single['id']}';
      await library.updateMetadata(id, 'Edited locality', 'Edited sector');
      expect((await library.search(locality: 'Edited locality')).total, 2);
      await library.deleteFile(id);
      expect((await library.search()).total, 0);
      expect(await File(input).exists(), isTrue);
    },
  );

  test(
    'failed or cancelled replacement preserves all existing PDFs and index',
    () async {
      await library.importPdfs([input]);
      final before = await library.files();
      final bad = File(p.join(temporary.path, 'bad.pdf'));
      await bad.writeAsString('Not a PDF');
      await expectLater(
        library.importPdfs([bad.path], replaceAll: true),
        throwsA(anything),
      );
      expect(await library.files(), before);
      await expectLater(
        library.importPdfs([input], replaceAll: true, cancelled: () => true),
        throwsFormatException,
      );
      expect((await library.search()).total, 2);
      expect(
        await Directory(p.join(library.root.path, 'files')).list().length,
        1,
      );
    },
  );

  test(
    'duplicate content is skipped and same filename updates atomically',
    () async {
      await library.importPdfs([input]);
      final renamed = await File(
        input,
      ).copy(p.join(temporary.path, 'Renamed.pdf'));
      final duplicate = await library.importPdfs([renamed.path]);
      expect(duplicate.skipped, 1);
      expect((await library.files()).length, 1);
      await makePdf(input, name: 'NEW CONSUMER', count: 1);
      await library.importPdfs([input]);
      expect((await library.files()).length, 1);
      expect((await library.search(query: 'NEW CONSUMER')).total, 1);
      expect((await library.search(query: 'MUHAMMAD')).total, 0);
    },
  );

  test(
    'backup restores PDFs and rejects a changed or missing backup PDF safely',
    () async {
      await library.importPdfs([input]);
      final backup = await library.backup(temporary.path);
      await library.clear();
      await library.restore(backup);
      expect((await library.search()).total, 2);
      final restored = await library.files();
      final backupFile =
          await Directory(p.join(backup, 'files')).list().first as File;
      await backupFile.writeAsString('corrupt');
      await expectLater(library.restore(backup), throwsFormatException);
      expect(await library.files(), restored);
      expect((await library.search()).total, 2);
    },
  );

  test(
    'merged PDFs retain per-page locality and register status filters',
    () async {
      await makePdf(input, mixedLocalities: true);
      await library.importPdfs([input]);
      expect((await library.search(locality: 'TEST LOCALITY')).total, 1);
      expect((await library.search(locality: 'OTHER LOCALITY')).total, 1);
      final consumerDb = await openDatabase(
        p.join(temporary.path, 'consumers.db'),
      );
      await consumerDb.execute(
        'CREATE TABLE consumers (id INTEGER PRIMARY KEY, connection_no TEXT, consumer_status TEXT, connection_status TEXT, bill_status TEXT)',
      );
      await consumerDb.insert('consumers', {
        'connection_no': '0401001',
        'consumer_status': 'ACTIVE',
        'connection_status': 'REGULAR CONNECTION',
        'bill_status': 'EXPIRED',
      });
      await library.attachConsumers(consumerDb.path);
      expect(
        (await library.search(
          consumerStatus: 'Active',
          connectionStatus: 'Regular Connection',
          billStatus: 'Un-Paid',
        )).total,
        2,
      );
      expect((await library.search(billStatus: 'Paid')).total, 0);
      await consumerDb.close();
    },
  );
}
