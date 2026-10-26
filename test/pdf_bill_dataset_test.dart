import 'dart:io';

import 'package:consumer_search_engine/services/pdf_bill_library.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final folder = Platform.environment['PDF_BILLS_DATASET'];
  test(
    'actual PDF folder matches CSV page counts and searchable bill identities',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await pdfrxInitialize();
      final temporary = await Directory.systemTemp.createTemp(
        'pdf-bills-dataset-',
      );
      final library = PdfBillLibrary(temporary);
      await library.open();
      try {
        final paths =
            (await Directory(folder!).list().toList())
                .whereType<File>()
                .where(
                  (f) =>
                      p.extension(f.path).toLowerCase() == '.pdf' &&
                      p.basename(f.path).toLowerCase() != 'all bills.pdf',
                )
                .map((f) => f.path)
                .toList()
              ..sort();
        final csvPath = p.join(folder, 'Localities.csv');
        final result = await library.importPdfs(paths, csvPath: csvPath);
        final imported = await library.files();
        final csvRows = csv.decode(await File(csvPath).readAsString());
        final headers = csvRows.first.map((v) => '$v').toList();
        final expected = {
          for (final row in csvRows.skip(1))
            '${row[headers.indexOf('PDF Filename')]}': int.parse(
              '${row[headers.indexOf('Pages')]}',
            ),
        };
        var pages = 0;
        for (final file in imported) {
          expect(
            file['pages'],
            expected[file['name']],
            reason: '${file['name']}',
          );
          expect(file['unsearchable'], 0, reason: '${file['name']}');
          pages += file['pages'] as int;
        }
        expect((await library.search()).total, pages);
        final academy = await library.search(
          query: '66070002',
          searchBy: 'connection_no',
        );
        expect(academy.total, 1);
        expect(academy.rows.single['consumer_name'], 'STAR ACADEMY');
        expect(academy.rows.single['bill_no'], '6932059');
        expect(academy.rows.single['locality'], 'ACADEMY');
        final missing = await library.db.rawQuery(
          "SELECT count(*) AS n FROM pages WHERE connection_no = '' OR bill_no = ''",
        );
        expect(missing.single['n'], 0);
        final bytes = await library.exportPages(academy.rows);
        final output = await PdfDocument.openData(bytes);
        try {
          expect(output.pages.length, 1);
          expect(
            (await output.pages.first.loadText())!.fullText,
            contains('6932059'),
          );
        } finally {
          await output.dispose();
        }
        // A measured dataset result, without consumer details in the logs.
        // ignore: avoid_print
        print(
          'Verified ${result.imported} PDFs, $pages bill pages; ${result.skipped} identical PDFs skipped.',
        );
      } finally {
        await library.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: folder == null
        ? 'Set PDF_BILLS_DATASET to a bills folder for this integration check.'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
