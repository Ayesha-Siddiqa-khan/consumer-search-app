import 'package:consumer_search_engine/services/export_service.dart';
import 'package:consumer_search_engine/services/csv_import_service.dart';
import 'package:csv/csv.dart';
import 'dart:io';
import 'package:consumer_search_engine/services/bill_import_service.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('KPI Statistics and Category Collections Tests', () {
    late Database db;
    late DatabaseService service;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE consumers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sr_no INTEGER,
          consumer_name TEXT,
          father_husband_name TEXT,
          mobile TEXT,
          sector TEXT,
          locality TEXT,
          address TEXT,
          order_no TEXT,
          rate_type TEXT,
          connection_no TEXT,
          old_connection_no TEXT,
          connection_date TEXT,
          connection_status TEXT,
          consumer_status TEXT,
          total_bill TEXT DEFAULT '',
          fine TEXT DEFAULT '',
          after_due_date TEXT DEFAULT '',
          due_date TEXT DEFAULT '',
          bill_status TEXT DEFAULT '',
          amount_received TEXT DEFAULT ''
        );
      ''');

      await db.execute('''
        CREATE TABLE bill_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          connection_no TEXT NOT NULL,
          sector TEXT DEFAULT '',
          locality TEXT DEFAULT '',
          consumer_name TEXT DEFAULT '',
          father_husband_name TEXT DEFAULT '',
          sr_no TEXT DEFAULT '',
          bill_no TEXT DEFAULT '',
          bill_type TEXT DEFAULT '',
          billing_period TEXT DEFAULT '',
          arrears TEXT DEFAULT '0',
          water_fee TEXT DEFAULT '0',
          sanitation TEXT DEFAULT '0',
          drainage TEXT DEFAULT '0',
          billing_fee TEXT DEFAULT '0',
          total_bill TEXT DEFAULT '0',
          fine TEXT DEFAULT '0',
          after_due_date TEXT DEFAULT '0',
          due_date TEXT DEFAULT '-',
          status TEXT DEFAULT 'Un-Paid',
          amount_received TEXT DEFAULT '0',
          receive_date TEXT DEFAULT '-',
          created_at TEXT DEFAULT ''
        );
      ''');

      // Insert consumers across categories
      // Domestic 1 (Paid)
      await db.insert('consumers', {
        'sr_no': 1,
        'consumer_name': 'Domestic User 1',
        'connection_no': 'CON1',
        'rate_type': 'DOMESTIC',
        'connection_status': 'Regular Connection',
        'consumer_status': 'Active',
        'bill_status': 'Paid',
        'total_bill': '1,000',
        'amount_received': '1,000',
      });
      // Domestic 2 (Unpaid)
      await db.insert('consumers', {
        'sr_no': 2,
        'consumer_name': 'Domestic User 2',
        'connection_no': 'CON2',
        'rate_type': 'DOMESTIC',
        'connection_status': 'Regular Connection',
        'consumer_status': 'Active',
        'bill_status': 'Un-Paid',
        'total_bill': '1,500',
        'amount_received': '0',
      });
      // Commercial 1 (Paid)
      await db.insert('consumers', {
        'sr_no': 3,
        'consumer_name': 'Commercial Shop',
        'connection_no': 'CON3',
        'rate_type': 'COMMERCIAL',
        'connection_status': 'Regular Connection',
        'consumer_status': 'Active',
        'bill_status': 'Paid',
        'total_bill': '5,000',
        'amount_received': '5,000',
      });
      // Private Societies 1 (Expired / Unpaid)
      await db.insert('consumers', {
        'sr_no': 4,
        'consumer_name': 'Private Society Plaza',
        'rate_type': 'PRIVATE',
        'connection_status': 'Closed / Dead',
        'consumer_status': 'In-Active',
        'bill_status': 'Expired',
        'total_bill': '10,000',
        'amount_received': '0',
      });

      // Insert bill_history records
      // Bill 1: Paid 2,000
      await db.insert('bill_history', {
        'bill_no': 'B1',
        'connection_no': 'CON1',
        'total_bill': '2,000',
        'amount_received': '2,000',
        'status': 'Paid',
      });
      // Bill 2: Un-Paid 3,000
      await db.insert('bill_history', {
        'bill_no': 'B2',
        'connection_no': 'CON2',
        'total_bill': '3,000',
        'amount_received': '0',
        'status': 'Un-Paid',
      });
      // Bill 3: Expired 5,000
      await db.insert('bill_history', {
        'bill_no': 'B3',
        'connection_no': 'CON3',
        'total_bill': '5,000',
        'amount_received': '0',
        'status': 'Expired',
      });

      service = DatabaseService.forTesting(db);
      await service.insertOrUpdateBillHistoryBatch((await db.query('bill_history')).map(BillHistory.fromMap).toList(), reportSource: 'fixture.csv');
    });

    tearDown(() async {
      await db.close();
    });

    test('getStats calculates bill_history metrics accurately', () async {
      final stats = await service.getStats();

      // Bill history checks
      expect(stats['totalBillsCount'], equals(3));
      expect(stats['paidBillsCount'], equals(1));
      expect(stats['pendingBillsCount'], equals(2));
      expect(stats['expiredBillsCount'], equals(1));

      expect(stats['totalBilledAmount'], equals(10000.0)); // 2000 + 3000 + 5000
      expect(stats['totalReceivedAmount'], equals(2000.0));
      expect(stats['totalPendingAmount'], equals(8000.0));
      expect(stats['recoveryRate'], closeTo(20.0, 0.01)); // 2000 / 10000 = 20%
    });

    test('category figures use the same bills, not cached consumer amounts', () async {
      final stats = await service.getStats();
      expect(stats['domesticDemand'], 5000);
      expect(stats['domesticReceived'], 2000);
      expect(stats['commercialDemand'], 5000);
      expect(stats['commercialReceived'], 0);
      expect(stats['privateDemand'], 0);
      expect(stats['domesticCount'], 2);
      expect(stats['commercialCount'], 1);
      expect(stats['privateCount'], 0);
    });

    test('clear removes bills, selected report, aliases and external FTS; reimport works', () async {
      await db.execute("CREATE VIRTUAL TABLE consumers_fts USING fts5(consumer_name, content='consumers', content_rowid='id')");
      await db.execute("INSERT INTO consumers_fts(consumers_fts) VALUES('rebuild')");
      await service.rememberVoiceCorrection('test name', 'Domestic User');
      await service.clearDatabase();
      final stats = await service.getStats();
      for (final key in ['total', 'billHistoryCount', 'totalBillsCount', 'totalBilledAmount', 'totalReceivedAmount', 'domesticCount', 'unknownCount']) {
        expect(stats[key], 0, reason: key);
      }
      expect(stats['billingImportedAt'], isNull);
      expect(await service.getVoiceCorrection('test name'), isNull);
      expect(await db.rawQuery("SELECT rowid FROM consumers_fts WHERE consumers_fts MATCH 'Domestic'"), isEmpty);
      expect(await db.query('bill_report_members'), isEmpty);
      expect(await db.query('bill_report_sources'), isEmpty);
      await service.clearDatabase(); // Safe when already empty.
      await service.insertOrUpdateBillHistoryBatch([
        const BillHistory(connectionNo: 'NEW', billNo: 'NEW-BILL', totalBill: '123'),
      ], reportSource: 'fresh.csv');
      expect((await service.getStats())['totalBilledAmount'], 123);
      expect(await service.getBillHistoryCount(), 1);
    });

    test('Connections format preserves IDs and maps Open/New without inventing Consumer Status', () async {
      final directory = await Directory.systemTemp.createTemp('connections-format-');
      try {
        final file = File('${directory.path}/connections.csv');
        await file.writeAsString('Sr.,Consumer Name,Rate Type,Connection Number,Old Connection Number,Reference No,Status\n1,Test A,DOMESTIC,0001,OLD1,REF1,Open\n2,Test B,COMMERCIAL,0002,,,New\n3,Test C,PRIVATE,0003,,,Closed\n');
        await service.clearDatabase();
        await CsvImportService.forTesting(service).importFromFile(file.path);
        final rows = await db.query('consumers', orderBy: 'sr_no');
        expect(rows.first['connection_no'], '0001');
        expect(rows.first['old_connection_no'], 'OLD1');
        expect(rows.first['order_no'], 'REF1');
        final stats = await service.getStats();
        expect(stats['regular'], 1);
        expect(stats['newDemand'], 1);
        expect(stats['active'], 0);
        expect(stats['inactive'], 0);
        expect(stats['unknownConsumerStatus'], 3);
        await CsvImportService.forTesting(service).importConsumerFile(file.path);
        expect((await service.getStats())['total'], 3);
      } finally { await directory.delete(recursive: true); }
    });

    test('confirmed connection category rules survive clearing and reimport', () async {
      for (var attempt = 0; attempt < 2; attempt++) {
        await service.clearDatabase();
        await service.insertOrUpdateBillHistoryBatch([
          const BillHistory(connectionNo: '10010100', billNo: 'N', totalBill: '19200'),
          const BillHistory(connectionNo: '66160006', billNo: 'P', totalBill: '75600'),
          const BillHistory(connectionNo: '66050050', billNo: 'A', totalBill: '12000'),
        ], reportSource: 'confirmed.csv');
        final stats = await service.getStats();
        expect(stats['domesticCount'], 1);
        expect(stats['commercialCount'], 2);
        expect(stats['unknownCount'], 0);
        expect(stats['commercialDemand'], 87600);
      }
    });

    test('no selected file never falls back to historical bills', () async {
      await db.delete('bill_report_members');
      await db.delete('bill_report_sources');
      final stats = await service.getStats();
      expect(stats['totalBillsCount'], 0);
      expect(stats['totalBilledAmount'], 0);
      expect(stats['billHistoryCount'], 3);
    });

    test('reimport updates both status directions in place and adds only new identities', () async {
      final before = (await service.getBillHistory('CON1')).single.id;
      await service.insertOrUpdateBillHistoryBatch([
        const BillHistory(connectionNo: ' con1 ', billNo: 'b1', totalBill: '2000', status: 'Un-Paid'),
        const BillHistory(connectionNo: 'CON2', billNo: 'B2', totalBill: '3000', status: 'Paid', amountReceived: '3100'),
        const BillHistory(connectionNo: 'CON2', billNo: 'B4', totalBill: '100', arrears: '50'),
      ], reportSource: 'new.csv');
      expect(await service.getBillHistoryCount(), 4);
      expect((await service.getBillHistory('CON1')).single.id, before);
      final stats = await service.getStats();
      expect(stats['totalBillsCount'], 3);
      expect(stats['totalBilledAmount'], 5100);
      expect(stats['totalReceivedAmount'], 3100);
      expect(stats['totalPendingAmount'], 2100);
      expect(stats['Arrears'], 50);
      expect(stats['domesticCount'], 3);
      expect(stats['domesticConnectionCount'], 2);
      expect(stats['PaidAmount'], 3000);
      await service.insertOrUpdateBillHistoryBatch([
        const BillHistory(connectionNo: 'CON2', billNo: 'B4', totalBill: '100', status: 'Paid'),
      ], reportSource: 'next.csv');
      expect(await service.getBillHistoryCount(), 4);
      final next = await service.getStats();
      expect(next['totalBillsCount'], 1);
      expect(next['totalReceivedAmount'], 0); // Paid status cannot invent a receipt.
    });

    test('serial numbers do not select a billing cycle and unknown stays visible', () async {
      await db.update('bill_history', {'sr_no': '1'}, where: "bill_no = 'B1'");
      await db.insert('consumers', {'connection_no': 'CON1', 'rate_type': 'DOMESTIC'});
      await service.insertOrUpdateBillHistoryBatch([const BillHistory(connectionNo: 'MISSING', billNo: 'M1', totalBill: '10')], reportSource: 'extra.csv', resetReport: false);
      final stats = await service.getStats();
      expect(stats['totalBillsCount'], 4);
      expect(stats['totalBilledAmount'], 10010);
      expect(stats['domesticDemand'], 5000); // Duplicate consumers never multiply bills.
      expect(stats['unknownDemand'], 10);
    });

    test('invalid file leaves existing bills and report selection intact', () async {
      final directory = await Directory.systemTemp.createTemp('bill-import-test-');
      try {
        final file = File('${directory.path}/invalid.csv');
        await file.writeAsString('Connection No,Bill No,Total Bill,Status,Amount Received\nCON1,B1,not-money,Paid,20\n');
        final result = await BillImportService.forTesting(service).importBillHistoryFiles([file]);
        expect(result.errors, hasLength(1));
        expect(await service.getBillHistoryCount(), 3);
        expect((await service.getStats())['totalBilledAmount'], 10000);
      } finally {
        await directory.delete(recursive: true);
      }
    });

    test('uploaded CSV totals and repeated import reconcile with independent audit', () async {
      final file = File(const String.fromEnvironment('BILLS_CSV'));
      final master = File('${file.parent.path}/13-10-26_Consumer-List-Merged.csv');
      if (await master.exists()) {
        final rows = csv.decode((await master.readAsString()).replaceFirst('\ufeff', ''));
        final headers = rows.first.map((v) => v.toString()).toList();
        final batch = db.batch();
        for (final row in rows.skip(1)) {
          if (row.length != headers.length) continue;
          batch.insert('consumers', {'connection_no': row[headers.indexOf('Connection No.')], 'rate_type': row[headers.indexOf('Rate Type')]});
        }
        await batch.commit(noResult: true);
      }
      final importer = BillImportService.forTesting(service);
      final result = await importer.importBillHistoryFiles([file]);
      expect(result.errors, isEmpty);
      expect(result.totalBills, 9690);
      final stats = await service.getStats();
      expect(stats['totalBillsCount'], 9690);
      expect(stats['paidBillsCount'], 2480);
      expect(stats['pendingBillsCount'], 7210);
      expect(stats['expiredBillsCount'], 189);
      expect(stats['totalBilledAmount'], 68342462);
      expect(stats['PaidAmount'], 7007760);
      expect(stats['UnpaidAmount'], 61334702);
      expect(stats['totalReceivedAmount'], 7100010);
      expect(stats['Arrears'], 43204662);
      if (await master.exists()) {
        expect(stats['domesticReceived'], 5883130);
        expect(stats['commercialReceived'], 510400);
        expect(stats['privateReceived'], 706480);
        expect(stats['unknownReceived'], 0);
        expect(stats['unknownCount'], 0);
      }
      final pdf = await ExportService.instance.generateBillingSummaryPdf(stats);
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
      const pdfPath = String.fromEnvironment('PDF_OUTPUT');
      if (pdfPath.isNotEmpty) await File(pdfPath).writeAsBytes(pdf);
      final count = await service.getBillHistoryCount();
      await importer.importBillHistoryFiles([file]);
      expect(await service.getBillHistoryCount(), count);
    }, skip: const String.fromEnvironment('BILLS_CSV').isEmpty);
  });
}
