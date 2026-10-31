import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:consumer_search_engine/services/bill_import_service.dart';
import 'package:consumer_search_engine/services/csv_import_service.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'database_backup_test.dart' show fixture;

const headers = [
  'Connection No',
  'Bill No',
  'Bill Type',
  'Billing Period',
  'Water Fee',
  'Arrears',
  'Total Bill',
  'Fine',
  'After Due Date',
  'Due Date',
  'Status',
  'Amount Received',
  'Receive Date',
];
List<String> row({
  String connection = '001-A',
  String bill = '10',
  String status = 'Un-Paid',
  String received = '0',
  String date = '-',
  String water = '2400',
}) => [
  connection,
  bill,
  'Regular',
  '01/01/2026 - 30/06/2026',
  water,
  '0',
  water,
  '240',
  '2640',
  '28/08/2026',
  status,
  received,
  date,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late Directory folder;
  late Database db;
  late DatabaseService service;
  late BillImportService importer;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('safe-csv-import-');
    db = await fixture('${folder.path}/test.db');
    service = DatabaseService.forTesting(db);
    importer = BillImportService.forTesting(service);
    await db.insert('consumers', {
      'connection_no': '001-A',
      'consumer_name': 'TEST',
    });
  });
  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });
  Future<File> file(String name, List<List<dynamic>> rows) async =>
      File('${folder.path}/$name').writeAsString(csv.encode(rows));

  test('import panel counts survive later imports and distinguish bills from connections', () async {
    final history = await file('history.csv', [headers, row(), row(bill: '11')]);
    await importer.importBillHistoryFiles([history], isHistory: true, asOf: DateTime(2026, 10, 20));
    final daily = await file('daily.csv', [
      headers,
      row(status: 'Paid', received: '2400', date: '21/10/2026'),
      row(connection: '002-B', bill: '12'),
    ]);
    await importer.importBillHistoryFiles([daily], asOf: DateTime(2026, 10, 21));
    final stats = await DatabaseService.forTesting(db).getStats();
    expect(stats['historyConnections'], 2);
    expect(stats['billHistoryCount'], 3);
    final runs = stats['latestImports'] as Map;
    expect(runs['history']['connections'], 1);
    expect(runs['history']['inserted'], 2);
    expect(runs['daily']['connections'], 2);
    expect(runs['daily']['inserted'], 1);
    expect(runs['daily']['updated'], 1);
    expect(runs['daily']['held'], 0);
    await importer.importBillHistoryFiles([daily], asOf: DateTime(2026, 10, 21));
    final repeated = (await service.getStats())['latestImports'] as Map;
    expect(repeated['daily']['unchanged'], 2);
    expect(repeated['daily']['updated'], 0);
    expect(repeated['history']['inserted'], 2);
  });

  test(
    'any filename, repeated copies, exact identities and missing daily fields are safe',
    () async {
      final history = await file('arbitrary.csv', [
        headers,
        row(status: 'Paid', received: '2400', date: '01/04/2026'),
      ]);
      var result = await importer.importBillHistoryFiles(
        [history, history],
        isHistory: true,
        asOf: DateTime(2026, 10, 20),
      );
      expect(result.inserted, 1);
      expect(result.duplicateRows, 1);
      final before = (await db.query('bill_history')).single;
      final daily = await file('anything.csv', [
        ['Connection No', 'Bill No', 'Total Bill', 'Status', 'Amount Received'],
        ['001-A', '10', '2400.00', 'Paid', '2400'],
      ]);
      result = await importer.importBillHistoryFiles([
        daily,
      ], asOf: DateTime(2026, 10, 21));
      expect(result.hasErrors, false);
      expect(result.inserted, 0);
      expect(result.updated, 0);
      expect(result.unchanged, 1);
      expect((await db.query('bill_history')).single, before);
      expect(before['connection_no'], '001-A');
    },
  );

  test(
    'newer snapshot wins regardless of folder order and retains older-only bills',
    () async {
      final old = await file('old_2026-09-25.csv', [
        headers,
        row(),
        row(bill: '9')..[3] = '01/07/2025 - 31/12/2025',
      ]);
      final fresh = await file('fresh_2026-10-21.csv', [
        headers,
        row(status: 'Paid', received: '2400', date: '20/10/2026'),
      ]);
      final result = await importer.importBillHistoryFiles([
        fresh,
        old,
      ], isHistory: true);
      expect(result.hasErrors, false);
      expect(result.inserted, 2);
      final bills = await db.query('bill_history', orderBy: 'bill_no');
      expect(bills.first['status'], 'Paid');
      expect((await db.query('consumers')).single['bill_status'], 'Paid');
      final repeat = await importer.importBillHistoryFiles([
        old,
        fresh,
      ], isHistory: true);
      expect(repeat.inserted, 0);
      expect(repeat.updated, 0);
      expect(repeat.unchanged, 2);
    },
  );

  test(
    'Paid advancement with no receipt date is accepted and flagged',
    () async {
      final h = await file('history.csv', [headers, row()]);
      await importer.importBillHistoryFiles(
        [h],
        isHistory: true,
        asOf: DateTime(2026, 10, 20),
      );
      final d = await file('daily.csv', [
        headers.take(12).toList(),
        row(status: 'Paid', received: '2400').take(12).toList(),
      ]);
      final result = await importer.importBillHistoryFiles([
        d,
      ], asOf: DateTime(2026, 10, 21));
      expect(result.updated, 1);
      expect((await db.query('bill_history')).single['receive_date'], '-');
      expect(
        result.issues.any(
          (i) => i['reason']!.contains('Paid receipt date missing'),
        ),
        true,
      );
      final audit = await service.getBillingAudit();
      expect(
        audit.single.reviewReasons.any(
          (s) => s.contains('receipt date missing'),
        ),
        true,
      );
    },
  );

  test(
    'a stale file and payment regression cannot undo a paid receipt',
    () async {
      final paid = await file('paid.csv', [
        headers,
        row(status: 'Paid', received: '2400', date: '20/10/2026'),
      ]);
      await importer.importBillHistoryFiles([
        paid,
      ], asOf: DateTime(2026, 10, 21));
      final unpaid = await file('stale.csv', [headers, row()]);
      var result = await importer.importBillHistoryFiles([
        unpaid,
      ], asOf: DateTime(2026, 10, 20));
      expect(result.unchanged, 1);
      result = await importer.importBillHistoryFiles([
        unpaid,
      ], asOf: DateTime(2026, 10, 22));
      expect(result.held, 1);
      expect(
        (await db.query('bill_history')).single['amount_received'],
        '2400',
      );
    },
  );

  test('equal-date conflicting bills are held without guessing', () async {
    final a = await file('a.csv', [headers, row()]);
    final b = await file('b.csv', [headers, row(water: '4800')]);
    final result = await importer.importBillHistoryFiles([
      a,
      b,
    ], isHistory: true);
    expect(result.held, 1);
    expect(await db.query('bill_history'), isEmpty);
    expect(await db.query('data_import_runs'), hasLength(1));
  });

  test(
    'malformed second file prevents even the first file from being saved',
    () async {
      final a = await file('good.csv', [headers, row()]);
      final b = await file('bad.csv', [headers, row()..removeLast()]);
      final result = await importer.importBillHistoryFiles([
        a,
        b,
      ], isHistory: true);
      expect(result.hasErrors, true);
      expect(await db.query('bill_history'), isEmpty);
      expect((await db.query('consumers')).single['total_bill'], isNull);
    },
  );

  test('database failure rolls back earlier bill and consumer updates', () async {
    await db.execute(
      "CREATE TRIGGER reject_bill BEFORE INSERT ON bill_history WHEN NEW.bill_no = '11' BEGIN SELECT RAISE(ABORT, 'test rejection'); END",
    );
    final input = await file('valid.csv', [headers, row(), row(bill: '11')]);
    final result = await importer.importBillHistoryFiles([
      input,
    ], isHistory: true);
    expect(result.hasErrors, true);
    expect(await db.query('bill_history'), isEmpty);
    expect(await db.query('data_import_runs'), isEmpty);
  });

  test(
    'master duplicate identity aborts all changes and preserves finance',
    () async {
      final input = await file('master-any-name.csv', [
        ['Consumer Name', 'Rate Type', 'Connection No'],
        ['NEW', 'Domestic', '002'],
        ['TEST', 'Domestic', '001-A'],
        ['OTHER', 'Domestic', '001-A'],
      ]);
      await expectLater(
        CsvImportService.forTesting(service).importConsumerFile(input.path),
        throwsFormatException,
      );
      expect(await db.query('consumers'), hasLength(1));
      expect((await db.query('consumers')).single['consumer_name'], 'TEST');
    },
  );

  test(
    'SQLite backup preserves source dates and saved import review reports',
    () async {
      final input = await file('source.csv', [
        headers,
        row(status: 'Paid', received: '2400'),
      ]);
      await importer.importBillHistoryFiles([input], isHistory: true);
      final backup = File('${folder.path}/backup.db');
      await backup.writeAsBytes(await service.createDatabaseBackup());
      final expected = await db.query('bill_import_state');
      await service.clearDatabase();
      expect(await db.query('bill_import_state'), isEmpty);
      await service.restoreDatabaseBackup(backup.path);
      expect(await db.query('bill_import_state'), expected);
      expect(await db.query('data_import_runs'), hasLength(1));
    },
  );

  test(
    'consistent source credits are preserved without warnings and are idempotent',
    () async {
      final credit = row(status: 'Paid');
      credit[5] = '-3900';
      credit[6] = '-1500';
      credit[7] = '0';
      credit[8] = '-1500';
      final input = await file('credit.csv', [headers, credit]);
      var result = await importer.importBillHistoryFiles([
        input,
      ], isHistory: true);
      expect(result.hasErrors, false);
      expect(result.inserted, 1);
      expect((await db.query('bill_history')).single['total_bill'], '-1500');
      expect(
        result.issues.any((r) => r['reason']!.contains('Negative credit')),
        false,
      );
      result = await importer.importBillHistoryFiles([input], isHistory: true);
      expect(result.updated, 0);
      expect(result.unchanged, 1);
      credit[1] = '11';
      credit[3] = '01/07/2026 - 31/12/2026';
      credit[6] = '-1400';
      credit[8] = '-1400';
      final inconsistent = await file('inconsistent-credit.csv', [
        headers,
        credit,
      ]);
      result = await importer.importBillHistoryFiles([
        inconsistent,
      ], isHistory: true);
      expect(
        result.issues.any((r) => r['reason']!.contains('Negative credit')),
        true,
      );
    },
  );

  test(
    'the same bill number on different connections stays separate',
    () async {
      final input = await file('distinct.csv', [
        headers,
        row(),
        row(connection: '001-B'),
      ]);
      final result = await importer.importBillHistoryFiles([
        input,
      ], isHistory: true);
      expect(result.inserted, 2);
      expect(await db.query('bill_history'), hasLength(2));
      expect(
        result.issues.any(
          (r) => r['reason']!.contains('missing from consumer master'),
        ),
        true,
      );
    },
  );

  test(
    'daily source governs consumer summary despite a higher-number history reissue',
    () async {
      final history = await file('history.csv', [headers, row(bill: '11')]);
      await importer.importBillHistoryFiles(
        [history],
        isHistory: true,
        asOf: DateTime(2026, 10, 20),
      );
      final daily = await file('daily.csv', [
        headers,
        row(bill: '10', status: 'Paid', received: '2400', date: '21/10/2026'),
      ]);
      await importer.importBillHistoryFiles([
        daily,
      ], asOf: DateTime(2026, 10, 21));
      expect((await db.query('consumers')).single['bill_status'], 'Paid');
      final older = await file('older.csv', [headers, row(bill: '9')]);
      await importer.importBillHistoryFiles([
        older,
      ], asOf: DateTime(2026, 10, 19));
      expect((await db.query('consumers')).single['bill_status'], 'Paid');
      expect((await db.query('bill_report_members')).single['bill_no'], '10');
      expect(
        (await db.query('bill_report_sources')).single['name'],
        'daily.csv',
      );
    },
  );

  test(
    'provided source files: full dry run, reconciliation, and repeat imports',
    () async {
      await db.close();
      final target = Platform.environment['IMPORT_TARGET_DB'];
      db = target == null
          ? await fixture(
              'scratch/validated-import-${DateTime.now().millisecondsSinceEpoch}.db',
              fts: true,
            )
          : await databaseFactoryFfi.openDatabase(target);
      expect(
        (await db.rawQuery('SELECT COUNT(*) n FROM consumers')).single['n'],
        0,
        reason:
            'Never overwrite a populated database in this source verification',
      );
      expect(
        (await db.rawQuery('SELECT COUNT(*) n FROM bill_history')).single['n'],
        0,
      );
      service = DatabaseService.forTesting(db);
      importer = BillImportService.forTesting(service);
      final master = await CsvImportService.forTesting(
        service,
      ).importConsumerFile('data/21-10-26_Consumer-List-Merged.csv');
      expect(master.inserted, 27883);
      final historyFiles = Directory('data/Merged bill history')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.csv'))
          .toList();
      final history = await importer.importBillHistoryFiles(
        historyFiles,
        isHistory: true,
        asOf: DateTime(2026, 10, 21),
      );
      expect(history.errors, isEmpty);
      expect(history.inserted, 94159);
      debugPrint('HISTORY: ${history.description}');
      final dailyFile = File('data/Bills-21-10-2026-21_40_51.csv');
      final daily = await importer.importBillHistoryFiles([
        dailyFile,
      ], asOf: DateTime(2026, 10, 21));
      expect(daily.errors, isEmpty);
      expect(daily.inserted, 943);
      debugPrint('DAILY: ${daily.description}');
      await Directory('output/import').create(recursive: true);
      await File(
        'output/import/Validated_Consumer_Database.db',
      ).writeAsBytes(await service.createDatabaseBackup());
      for (final sourceRow in await db.rawQuery(
        "SELECT c.connection_no FROM consumers c JOIN bill_report_members r ON r.connection_no = c.connection_no JOIN bill_history h ON h.connection_no = r.connection_no AND h.bill_no = r.bill_no WHERE (c.bill_status != h.status OR CAST(c.amount_received AS REAL) != CAST(h.amount_received AS REAL)) AND NOT EXISTS (SELECT 1 FROM bill_report_members newer WHERE newer.connection_no = r.connection_no AND CAST(newer.bill_no AS INTEGER) > CAST(r.bill_no AS INTEGER))",
      )) {
        fail('Current consumer bill differs from daily report: $sourceRow');
      }
      final before = await db.query('bill_history', orderBy: 'id');
      final repeat = await importer.importBillHistoryFiles([
        dailyFile,
      ], asOf: DateTime(2026, 10, 21));
      expect(repeat.inserted, 0);
      expect(repeat.updated, 0);
      expect(await db.query('bill_history', orderBy: 'id'), before);
      final historyAgain = await importer.importBillHistoryFiles(
        historyFiles.reversed.toList(),
        isHistory: true,
        asOf: DateTime(2026, 10, 21),
      );
      expect(historyAgain.inserted, 0);
      expect(historyAgain.updated, 0);
      expect(await db.query('bill_history', orderBy: 'id'), before);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      final dated = (await db.query(
        'bill_history',
        where: 'connection_no = ? AND bill_no = ?',
        whereArgs: ['81010001', '6865009'],
      )).single;
      expect(dated['receive_date'], '24/08/2026');
      expect(dated['billing_period'], '01/07/2026 - 31/12/2026');
      final corrected = await db.query(
        'bill_history',
        where: 'connection_no = ?',
        whereArgs: ['90010045'],
      );
      expect(
        corrected.every(
          (r) =>
              r['consumer_name'] == 'ZULFIQAR ALI' &&
              r['father_husband_name'] == 'MUHAMMAD UMAR',
        ),
        true,
      );
      await Directory('output/import').create(recursive: true);
      await File(
        'output/import/history-review.csv',
      ).writeAsString('\ufeff${history.reviewCsv}');
      await File(
        'output/import/daily-review.csv',
      ).writeAsString('\ufeff${daily.reviewCsv}');
      await File('output/import/reconciliation.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'database_path': db.path,
          'consumers': master.inserted,
          'history_unique': history.inserted,
          'daily_new': daily.inserted,
          'daily_updated': daily.updated,
          'daily_unchanged': daily.unchanged,
          'daily_held': daily.held,
          'total_bills': before.length,
          'daily_repeat_new': repeat.inserted,
          'daily_repeat_updated': repeat.updated,
          'history_repeat_new': historyAgain.inserted,
          'history_repeat_updated': historyAgain.updated,
          'history_notes': history.issues.length,
          'daily_notes': daily.issues.length,
          'integrity': 'ok',
        }),
      );
    },
    skip: Platform.environment['RUN_SOURCE_IMPORT'] != '1',
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
