import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:consumer_search_engine/services/bill_import_service.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'database_backup_test.dart' show fixture;

const columns = [
  'Connection No',
  'Bill No',
  'Consumer Name',
  'Consumer F/H Name',
  'Bill Type',
  'Billing Period',
  'Water Fee',
  'Total Bill',
  'Status',
  'Amount Received',
  'Receive Date',
];
List<String> historyRow(String bill, {bool wrongOwner = false}) => [
  '90010045',
  bill,
  wrongOwner ? 'AKMAL SHAHZAD' : 'ZULFIQAR ALI',
  wrongOwner ? 'MUHAMMAD ASLAM' : 'MUHAMMAD UMAR',
  'Regular',
  '01/01/2026 - 30/06/2026',
  '2400',
  '2400',
  'Paid',
  '2640',
  wrongOwner ? '02/04/2026' : '26/07/2026',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late Directory folder;
  late Database db;
  late DatabaseService database;
  late BillImportService importer;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('history-owner-test-');
    db = await fixture('${folder.path}/app.db');
    database = DatabaseService.forTesting(db);
    importer = BillImportService.forTesting(database);
    await db.insert('consumers', {
      'connection_no': '90010045',
      'consumer_name': 'ZULFIQAR ALI',
      'father_husband_name': 'MUHAMMAD UMAR',
    });
  });
  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });
  Future<File> input(String name, List<List<String>> rows) => File(
    '${folder.path}/$name',
  ).writeAsString(csv.encode([columns, ...rows]));

  test(
    'newer snapshot replaces alternate bill IDs for the same connection and period',
    () async {
      final correct = await input('correct_2026-10-21.csv', [
        historyRow('6133319'),
      ]);
      final wrong = await input('wrong_2026-09-25.csv', [
        historyRow('6133320', wrongOwner: true),
      ]);
      final result = await importer.importBillHistoryFiles([
        wrong,
        correct,
      ], isHistory: true);
      expect(result.errors, isEmpty);
      expect(result.held, 0);
      final active = await database.getBillHistory('90010045');
      expect(active, hasLength(1));
      expect(active.single.billNo, '6133319');
      expect(active.single.receiveDate, '26/07/2026');
      final archived = (await db.query('bill_history_quarantine')).single;
      expect(
        jsonDecode(archived['row_json'] as String)['consumer_name'],
        'AKMAL SHAHZAD',
      );
      await importer.importBillHistoryFiles([wrong], isHistory: true);
      expect(await database.getBillHistory('90010045'), hasLength(1));
    },
  );

  test(
    'repair removes the legacy renamed wrong-owner row using original source evidence',
    () async {
      final wrong = await input('wrong_2026-09-25.csv', [
        historyRow('6133320', wrongOwner: true),
      ]);
      final correct = await input('correct_2026-10-21.csv', [
        historyRow('6133319'),
      ]);
      await database.insertOrUpdateBillHistoryBatch([
        const BillHistory(
          connectionNo: '90010045',
          billNo: '6133320',
          consumerName: 'ZULFIQAR ALI',
          fatherHusbandName: 'MUHAMMAD UMAR',
          billingPeriod: '01/01/2026 - 30/06/2026',
          billType: 'Regular',
          waterFee: '2400',
          totalBill: '2400',
          status: 'Paid',
          amountReceived: '2640',
          receiveDate: '02/04/2026',
        ),
      ]);
      await db.insert('bill_import_state', {
        'connection_no': '90010045',
        'bill_no': '6133320',
        'source': 'wrong_2026-09-25.csv',
        'as_of': '2026-09-25',
        'kind': 'history',
      });
      final result = await importer.importBillHistoryFiles(
        [wrong, correct],
        isHistory: true,
        repairSourceConflicts: true,
      );
      expect(result.errors, isEmpty);
      expect(
        (await database.getBillHistory('90010045')).single.billNo,
        '6133319',
      );
      expect(await db.query('bill_history_quarantine'), isNotEmpty);
      await importer.importBillHistoryFiles(
        [wrong, correct],
        isHistory: true,
        repairSourceConflicts: true,
      );
      expect(await database.getBillHistory('90010045'), hasLength(1));
    },
  );

  test(
    'unknown bill number for an existing period is held instead of silently counted twice',
    () async {
      final first = await input('first.csv', [historyRow('6133319')]);
      final alternative = await input('other.csv', [historyRow('6133320')]);
      await importer.importBillHistoryFiles([first], isHistory: true);
      final result = await importer.importBillHistoryFiles([
        alternative,
      ], isHistory: true);
      expect(result.held, 1);
      expect(await database.getBillHistory('90010045'), hasLength(1));
    },
  );

  test(
    'a name spelling difference alone does not discard a matching-father record',
    () async {
      final row = historyRow('6133319');
      row[2] = 'ZULFIKAR ALI';
      final file = await input('spelling.csv', [row]);
      final result = await importer.importBillHistoryFiles([
        file,
      ], isHistory: true);
      expect(result.inserted, 1);
      expect(result.held, 0);
    },
  );

  test(
    'a separate newer CSV retires the old bill and stale daily rows cannot recreate it',
    () async {
      final old = await input('old_2026-09-25.csv', [historyRow('6133320')]);
      final newer = await input('new_2026-10-21.csv', [historyRow('6133319')]);
      await importer.importBillHistoryFiles([old], isHistory: true);
      final currentDaily = await input('daily.csv', [historyRow('6133320')]);
      await importer.importBillHistoryFiles([currentDaily], asOf:DateTime(2026,9,25));
      final replacement = await importer.importBillHistoryFiles([
        newer,
      ], isHistory: true);
      expect(replacement.superseded, 1);
      final daily = await input('daily.csv', [historyRow('6133320')]);
      final result = await importer.importBillHistoryFiles([
        daily,
      ], asOf: DateTime(2026, 10, 22));
      expect(result.held, 1);
      expect(await database.getBillHistory('90010045'), hasLength(1));
      // Rejected daily updates stay archived; the trusted newer history controls totals.
      for (final entries in [
        await database.getBillingAudit(),
        await database.getBillingAudit(connectionNo: '90010045'),
      ]) {
        expect(entries.single.invalidHistory, false);
        expect(entries.single.billCount, 1);
        expect(entries.single.received, 264000);
        expect(entries.single.waterReceived, 240000);
      }
    },
  );

  test(
    'legitimate multiple bills listed together in the newest snapshot stay separate',
    () async {
      final file = await input('new_2026-10-21.csv', [
        historyRow('6133319'),
        historyRow('6133320'),
      ]);
      final result = await importer.importBillHistoryFiles([
        file,
      ], isHistory: true);
      expect(result.inserted, 2);
      expect(await database.getBillHistory('90010045'), hasLength(2));
    },
  );

  test(
    'recovery archive survives backup replacement and clears with all data',
    () async {
      final correct = await input('correct_2026-10-21.csv', [
        historyRow('6133319'),
      ]);
      final datedWrong = await input('wrong_2026-09-25.csv', [
        historyRow('6133320', wrongOwner: true),
      ]);
      await importer.importBillHistoryFiles([
        datedWrong,
        correct,
      ], isHistory: true);
      final backup = File('${folder.path}/backup.db');
      await backup.writeAsBytes(await database.createDatabaseBackup());
      await database.clearDatabase();
      expect(await db.query('bill_history_quarantine'), isEmpty);
      await database.restoreDatabaseBackup(backup.path);
      expect(await db.query('bill_history_quarantine'), hasLength(1));
    },
  );
}
