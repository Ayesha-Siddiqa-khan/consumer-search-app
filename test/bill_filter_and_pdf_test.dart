import 'package:flutter_test/flutter_test.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/consumer_model.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Bill Status Filter Tests in DatabaseService', () {
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

      await db.insert('consumers', {
        'sr_no': 1,
        'consumer_name': 'AHMAD KHAN',
        'connection_no': 'CON101',
        'bill_status': 'Paid',
        'total_bill': '2400',
        'amount_received': '2400',
      });
      await db.insert('consumers', {
        'sr_no': 2,
        'consumer_name': 'BILAL SHAH',
        'connection_no': 'CON102',
        'bill_status': 'Un-Paid',
        'total_bill': '3500',
        'amount_received': '0',
      });
      await db.insert('consumers', {
        'sr_no': 3,
        'consumer_name': 'USMAN ALI',
        'connection_no': 'CON103',
        'bill_status': 'Expired',
        'total_bill': '1200',
        'amount_received': '0',
      });

      service = DatabaseService.forTesting(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('searchConsumers with billStatus: All Bills returns all 3', () async {
      final res = await service.searchConsumers(billStatus: 'All Bills');
      expect(res.totalCount, equals(3));
    });

    test('searchConsumers with billStatus: Paid returns only Ahmad Khan', () async {
      final res = await service.searchConsumers(billStatus: 'Paid');
      expect(res.totalCount, equals(1));
      expect(res.items.first.consumerName, equals('AHMAD KHAN'));
      expect(res.items.first.billStatus, equals('Paid'));
    });

    test('searchConsumers with billStatus: Un-Paid returns both Un-Paid and Expired', () async {
      final res = await service.searchConsumers(billStatus: 'Un-Paid');
      expect(res.totalCount, equals(2));
      final names = res.items.map((c) => c.consumerName).toList();
      expect(names, contains('BILAL SHAH'));
      expect(names, contains('USMAN ALI'));
    });

    test('searchConsumers with billStatus: Expired returns only Expired', () async {
      final res = await service.searchConsumers(billStatus: 'Expired');
      expect(res.totalCount, equals(1));
      expect(res.items.first.consumerName, equals('USMAN ALI'));
    });
  });

  group('PDF Generation & Black/White Print Tests', () {
    test('generateConsumerPdf generates valid B&W PDF with selected columns', () async {
      final consumers = [
        Consumer(
          srNo: 1,
          consumerName: 'KHALID HUSSAIN',
          fatherHusbandName: 'HUSSAIN ALI',
          mobile: '03001234567',
          sector: 'Farooq Colony',
          locality: 'Zone A',
          address: 'House 5, Street 2',
          orderNo: 'ORD-1',
          rateType: 'DOMESTIC',
          connectionNo: '1001-A',
          oldConnectionNo: 'OLD-1001',
          connectionDate: '01-07-2023',
          connectionStatus: 'Regular Connection',
          consumerStatus: 'Active',
          totalBill: '2400',
          billStatus: 'Paid',
          amountReceived: '2400',
        ),
      ];

      final pdfBytes = await ExportService.instance.generateConsumerPdf(
        consumers: consumers,
        selectedColumnKeys: {'sr_no', 'consumer_name', 'connection_no', 'total_bill', 'bill_status'},
        reportTitle: 'Test Consumer Report',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(1000));
      // PDF header magic bytes %PDF-
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), equals('%PDF'));
    });

    test('generateBillHistoryPdf generates valid B&W Bill History PDF', () async {
      final bills = [
        const BillHistory(
          srNo: '1',
          billNo: '6990245',
          billType: 'Regular',
          billingPeriod: '01/07/2026 - 31/12/2026',
          arrears: '0',
          waterFee: '2400',
          sanitation: '0',
          drainage: '0',
          billingFee: '0',
          totalBill: '2400',
          fine: '240',
          afterDueDate: '2640',
          dueDate: '22/08/2026',
          status: 'Un-Paid',
          amountReceived: '0',
          receiveDate: '-',
          connectionNo: 'CON101',
        ),
        const BillHistory(
          srNo: '2',
          billNo: '6135615',
          billType: 'Regular',
          billingPeriod: '01/01/2026 - 30/06/2026',
          arrears: '0',
          waterFee: '2400',
          sanitation: '0',
          drainage: '0',
          billingFee: '0',
          totalBill: '2400',
          fine: '240',
          afterDueDate: '2640',
          dueDate: '22/02/2026',
          status: 'Paid',
          amountReceived: '2400',
          receiveDate: '05/03/2026',
          connectionNo: 'CON101',
        ),
      ];

      final pdfBytes = await ExportService.instance.generateBillHistoryPdf(
        connectionNo: 'CON101',
        consumerDetail: {
          'consumer_name': 'ABDULLAH BUTT',
          'father_husband_name': 'BUTT SAHAB',
          'sector': 'NAIK WALA TIBA',
          'locality': 'Zone 1',
        },
        bills: bills,




      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(1000));
      // PDF header magic bytes %PDF-
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), equals('%PDF'));
    });

    test('generateBillingSummaryPdf generates valid expanded PDF without source or arrears lines', () async {
      final stats = {
        'domesticCount': 9044,
        'domesticPaidAmount': 5796160,
        'domesticUnpaidAmount': 56305622,
        'domesticArrears': 40736382,
        'domesticReceived': 5883130,
        'commercialCount': 256,
        'commercialPaidAmount': 508000,
        'commercialUnpaidAmount': 2251200,
        'commercialArrears': 837200,
        'commercialReceived': 510400,
        'privateCount': 390,
        'privatePaidAmount': 703600,
        'privateUnpaidAmount': 2777880,
        'privateArrears': 1631080,
        'privateReceived': 706480,
        'Count': 9690,
        'PaidAmount': 7007760,
        'UnpaidAmount': 61334702,
        'Arrears': 43204662,
        'Received': 7100010,
      };

      final pdfBytes = await ExportService.instance.generateBillingSummaryPdf(stats);
      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(500));
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), equals('%PDF'));

      final pdfContent = String.fromCharCodes(pdfBytes);
      expect(pdfContent.contains('Arrears are included in bill amounts'), isFalse);
      expect(pdfContent.contains('Bills-13-10-2026'), isFalse);
    });
  });
}
