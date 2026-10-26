import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumer_search_engine/models/consumer_model.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/services/bill_import_service.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Merged History Bills Import Tests', () {
    late Database db;
    late DatabaseService dbService;
    late BillImportService importService;
    late Directory tempDir;

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
          connection_no TEXT UNIQUE,
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
          connection_no TEXT,
          sector TEXT,
          locality TEXT,
          consumer_name TEXT,
          father_husband_name TEXT,
          sr_no TEXT,
          bill_no TEXT,
          bill_type TEXT,
          billing_period TEXT,
          arrears TEXT,
          water_fee TEXT,
          sanitation TEXT,
          drainage TEXT,
          billing_fee TEXT,
          total_bill TEXT,
          fine TEXT,
          after_due_date TEXT,
          due_date TEXT,
          status TEXT,
          amount_received TEXT,
          receive_date TEXT,
          created_at TEXT,
          UNIQUE(connection_no, bill_no)
        );
      ''');

      await db.execute('''
        CREATE TABLE sync_reports (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          report_type TEXT,
          source_file TEXT,
          record_count INTEGER,
          created_at TEXT
        );
      ''');

      await db.execute('''
        CREATE TABLE bill_report_members (
          connection_no TEXT,
          bill_no TEXT,
          PRIMARY KEY(connection_no, bill_no)
        );
      ''');

      await db.execute('''
        CREATE TABLE bill_report_sources (
          name TEXT PRIMARY KEY,
          imported_at TEXT
        );
      ''');

      // Seed a consumer
      await db.insert('consumers', {
        'sr_no': 1,
        'consumer_name': 'HAFEEZ ULLAH BUTT',
        'connection_no': '99010334',
        'bill_status': 'Un-Paid',
        'total_bill': '0',
        'amount_received': '0',
      });

      dbService = DatabaseService.forTesting(db);
      importService = BillImportService.forTesting(dbService);
      tempDir = await Directory.systemTemp.createTemp('merged_test_');
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('successfully imports merged history CSV with divider banner rows', () async {
      final sampleCsv = '''
Connection No,Sector,Locality,Consumer Name,Consumer F/H Name,Sr #,Bill No.,Bill Type,Billing Period,Arrears,Water Fee,Total Bill,Fine,After Due Date,Due Date,Status,Amount Received,Receive Date
"99010334","NAIKy WALA TIBA","NAIK WALA TIBA","HAFEEZ ULLAH BUTT","NONE","1","3775310","Regular","01/10/2024 - 31/12/2024","0","1,200","1,200","120","1,320","1,320","Un-Paid","0","-"
"--- End of 99010334 (HAFEEZ ULLAH BUTT) ---","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------"
"99010325","NAIKy WALA TIBA","NAIK WALA TIBA","MUHAMMAD ASIF","MUHAMMAD MUNIR","1","3775309","Regular","01/10/2024 - 31/12/2024","0","1,200","1,200","120","1,320","1,320","Paid","1,200","15/11/2024"
"--- End of 99010325 (MUHAMMAD ASIF) ---","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------"
''';

      final file = File('${tempDir.path}/test_merged.csv');
      await file.writeAsString(sampleCsv);

      final summary = await importService.importBillHistoryFiles([file], isHistory: true);

      expect(summary.hasErrors, isFalse);
      expect(summary.errors, isEmpty);
      expect(summary.totalBills, equals(2));
      expect(summary.totalFiles, equals(1));

      // Verify records in DB
      final billsInDb = await db.query('bill_history');
      expect(billsInDb.length, equals(2));
      expect(billsInDb[0]['connection_no'], equals('99010334'));
      expect(billsInDb[0]['bill_no'], equals('3775310'));
      expect(billsInDb[1]['connection_no'], equals('99010325'));
      expect(billsInDb[1]['bill_no'], equals('3775309'));

      // Verify that consumer 99010334 was updated because it had total_bill = '0'
      final consumer = await db.query('consumers', where: 'connection_no = ?', whereArgs: ['99010334']);
      expect(consumer.isNotEmpty, isTrue);
      expect(consumer[0]['total_bill'], equals('1,200'));
    });

    test('3-Step Pipeline: Current bills import updates consumer, subsequent history does not downgrade', () async {
      // 1. Current bills file arrives with 2026 bill (Paid, 2400)
      final currentBillCsv = '''
Sr.,"Bill Type","Bill No","Reference No",Sector,Locality,Address,"Consumer Name / F/H Name","Consumer Mobile","Connection No","Old Connection No",Arrears,"Water Fee",Sanitation,Drainage,"Billing Fee","Total Bill",Fine,"After Due Date","Due Date",Status,"Amount Received"
1,Regular,6865009,26770120201000015937,"NAIKy WALA TIBA","Zone 1","Address","HAFEEZ ULLAH BUTT",03004821888,99010334,1,0.00,2400.00,0,0,0,2400.00,240,2640,28/08/2026,Paid,2400
''';
      final currentFile = File('${tempDir.path}/current_bills.csv');
      await currentFile.writeAsString(currentBillCsv);

      await importService.importBillHistoryFiles([currentFile], isHistory: false);

      // Verify consumer updated with current bill
      var consumer = (await db.query('consumers', where: 'connection_no = ?', whereArgs: ['99010334'])).first;
      expect(consumer['total_bill'], equals('2400.00'));
      expect(consumer['bill_status'], equals('Paid'));
      expect(consumer['amount_received'], equals('2400'));

      // 2. Now user imports older history file with 2024 bill (Un-Paid, 1200)
      final historyCsv = '''
Connection No,Sector,Locality,Consumer Name,Consumer F/H Name,Sr #,Bill No.,Bill Type,Billing Period,Arrears,Water Fee,Total Bill,Fine,After Due Date,Due Date,Status,Amount Received,Receive Date
"99010334","NAIKy WALA TIBA","NAIK WALA TIBA","HAFEEZ ULLAH BUTT","NONE","1","3775310","Regular","01/10/2024 - 31/12/2024","0","1,200","1,200","120","1,320","1,320","Un-Paid","0","-"
"--- End of 99010334 (HAFEEZ ULLAH BUTT) ---","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------","--------------------"
''';
      final historyFile = File('${tempDir.path}/history.csv');
      await historyFile.writeAsString(historyCsv);

      await importService.importBillHistoryFiles([historyFile], isHistory: true);

      // 3. Verify that bill_history has BOTH bills (no clash, both saved)
      final allBills = await db.query('bill_history', where: 'connection_no = ?', whereArgs: ['99010334']);
      expect(allBills.length, equals(2));

      // 4. Verify that the consumer's current active bill remained 2026 (Paid, 2400.00), not downgraded to 1200!
      consumer = (await db.query('consumers', where: 'connection_no = ?', whereArgs: ['99010334'])).first;
      expect(consumer['total_bill'], equals('2400.00'));
      expect(consumer['bill_status'], equals('Paid'));
      expect(consumer['amount_received'], equals('2400'));
    });

    test('Default PDF export columns are the 7 requested columns', () {
      expect(ExportService.defaultPdfColumnKeys.length, equals(7));
      expect(
        ExportService.defaultPdfColumnKeys,
        containsAll([
          'sr_no',
          'consumer_name',
          'father_husband_name',
          'mobile',
          'connection_no',
          'old_connection_no',
          'after_due_date',
        ]),
      );
    });

    test('generateConsumerPdf does not include Government of Punjab footer line', () async {
      final consumer = Consumer(
        srNo: 1,
        consumerName: 'HAFEEZ ULLAH BUTT',
        fatherHusbandName: 'NONE',
        mobile: '03004821888',
        sector: 'NAIK WALA TIBA',
        locality: 'Zone 1',
        address: 'Main Bazar',
        orderNo: '101',
        rateType: 'Domestic',
        connectionNo: '99010334',
        oldConnectionNo: '1',
        connectionDate: '01-01-2024',
        connectionStatus: 'Regular Connection',
        consumerStatus: 'Active',
        totalBill: '2400',
        afterDueDate: '2640',
      );

      final pdfBytes = await ExportService.instance.generateConsumerPdf(
        consumers: [consumer],
        selectedColumnKeys: ExportService.defaultPdfColumnKeys,
      );

      final pdfString = String.fromCharCodes(pdfBytes);
      expect(pdfString.contains('Government of Punjab | eLGCDD Consumer Search Engine'), isFalse);
    });

    test('getActiveColumns correctly includes after_due_date and excludes sector when sector is filtered', () {
      final consumer = Consumer(
        srNo: 1,
        consumerName: 'TAHIR JAVEED',
        fatherHusbandName: 'MUHAMMAD IBRAHEEM',
        mobile: '03007546199',
        sector: 'Ali Town',
        locality: 'Zone A',
        address: 'House 1',
        orderNo: '101',
        rateType: 'Domestic',
        connectionNo: '90010002',
        oldConnectionNo: '0',
        connectionDate: '01-01-2024',
        connectionStatus: 'Regular Connection',
        consumerStatus: 'Active',
        totalBill: '5040.00',
        afterDueDate: '5040.00',
      );

      final activeCols = ExportService.instance.getActiveColumns(
        selectedColumnKeys: ExportService.defaultPdfColumnKeys,
        sector: 'Ali Town',
      );

      final colKeys = activeCols.map((c) => c.key).toList();
      expect(colKeys, equals([
        'sr_no',
        'consumer_name',
        'father_husband_name',
        'mobile',
        'connection_no',
        'old_connection_no',
        'after_due_date',
      ]));

      final afterDueCol = activeCols.firstWhere((c) => c.key == 'after_due_date');
      expect(afterDueCol.label, equals('After Due Date'));
      expect(afterDueCol.valueGetter(consumer), equals('5,040'));
      expect(ExportService.formatAmountWithoutDecimals('5040.00'), equals('5,040'));
      expect(ExportService.formatAmountWithoutDecimals('0.00'), equals('0'));
    });

    test('generateConsumerPdf generates valid PDF with default 7 columns', () async {
      final consumer = Consumer(
        srNo: 1,
        consumerName: 'TAHIR JAVEED',
        fatherHusbandName: 'MUHAMMAD IBRAHEEM',
        mobile: '03007546199',
        sector: 'Ali Town',
        locality: 'Zone A',
        address: 'House 1',
        orderNo: '101',
        rateType: 'Domestic',
        connectionNo: '90010002',
        oldConnectionNo: '0',
        connectionDate: '01-01-2024',
        connectionStatus: 'Regular Connection',
        consumerStatus: 'Active',
        totalBill: '5040.00',
        afterDueDate: '5040.00',
      );

      final pdfBytes = await ExportService.instance.generateConsumerPdf(
        consumers: [consumer],
        selectedColumnKeys: ExportService.defaultPdfColumnKeys,
        sector: 'Ali Town',
        billStatus: 'Un-Paid',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(1000));
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), equals('%PDF'));
    });

    test('generateBillHistoryPdf excludes top department banner and statement box', () async {
      final bills = [
        const BillHistory(
          srNo: '1',
          billNo: '6865864',
          billType: 'Regular',
          billingPeriod: '01/07/2026 - 31/12/2026',
          arrears: '2640.00',
          waterFee: '2400.00',
          sanitation: '0',
          drainage: '0',
          billingFee: '0',
          totalBill: '5040.00',
          fine: '240',
          afterDueDate: '5280',
          dueDate: '29/08/2026',
          status: 'Un-Paid',
          amountReceived: '0',
          receiveDate: '-',
          connectionNo: '90010207',
        ),
      ];

      final pdfBytes = await ExportService.instance.generateBillHistoryPdf(
        connectionNo: '90010207',
        consumerDetail: {
          'consumer_name': 'MUHAMMAD BILAL',
          'father_husband_name': 'CH MUHAMMAD LATIF',
          'sector': 'Ali Town',
          'locality': 'Ali town Zone A',
        },
        bills: bills,




      );

      expect(pdfBytes, isNotNull);
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), equals('%PDF'));
      final pdfContent = String.fromCharCodes(pdfBytes);
      expect(pdfContent.contains('WATER SANITATION BILL HISTORY & AUDIT STATEMENT'), isFalse);
      expect(pdfContent.contains('Local Government & Community Development Department'), isFalse);
    });
  });
}
