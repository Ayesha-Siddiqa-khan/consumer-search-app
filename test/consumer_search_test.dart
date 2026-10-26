import 'package:flutter_test/flutter_test.dart';
import 'package:consumer_search_engine/models/consumer_model.dart';
import 'package:consumer_search_engine/services/name_normalizer.dart';
import 'package:consumer_search_engine/services/smart_search_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Consumer Model & Date Format Tests', () {
    test('Strict Pakistani Date Format DD-MM-YYYY conversion', () {
      // Slash format: 01/07/2023 -> 01-07-2023
      expect(Consumer.formatPakistaniDate('01/07/2023'), equals('01-07-2023'));
      expect(Consumer.formatPakistaniDate('30/06/2023'), equals('30-06-2023'));
      expect(Consumer.formatPakistaniDate('9/3/2023'), equals('09-03-2023'));

      // Dash format: 2023-07-01 -> 01-07-2023
      expect(Consumer.formatPakistaniDate('2023-07-01'), equals('01-07-2023'));
      expect(Consumer.formatPakistaniDate('01-07-2023'), equals('01-07-2023'));

      // Empty or invalid handling
      expect(Consumer.formatPakistaniDate(''), equals('-'));
      expect(Consumer.formatPakistaniDate(null), equals('-'));
    });

    test('Consumer model serialization and deserialization', () {
      final consumer = Consumer(
        srNo: 1,
        consumerName: 'MUHAMMAD ALI',
        fatherHusbandName: 'ALI ASGHAR',
        mobile: '03148598216',
        sector: 'Waris Colony',
        locality: 'WARIS COLONY Zone B',
        address: 'WARIS COLONY 15/G MAIN ROAD',
        orderNo: '999',
        rateType: 'DOMESTIC (NEW CONNECTION)',
        connectionNo: '999',
        oldConnectionNo: '999',
        connectionDate: '01-07-2023',
        connectionStatus: 'Regular Connection',
        consumerStatus: 'Active',
      );

      final map = consumer.toMap();
      final revived = Consumer.fromMap(map);

      expect(revived.consumerName, equals('MUHAMMAD ALI'));
      expect(revived.fatherHusbandName, equals('ALI ASGHAR'));
      expect(revived.mobile, equals('03148598216'));
      expect(revived.connectionDate, equals('01-07-2023'));
      expect(revived.isActive, isTrue);
    });
  });

  group('SQLite In-Memory Query & Search Tests', () {
    late Database db;

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
          rateType TEXT,
          connection_no TEXT,
          old_connection_no TEXT,
          connection_date TEXT,
          connection_status TEXT,
          consumer_status TEXT
        );
      ''');
    });

    tearDown(() async {
      await db.close();
    });

    test('Insert and fast search query execution', () async {
      await db.insert('consumers', {
        'sr_no': 1,
        'consumer_name': 'ASLAM KHAN',
        'father_husband_name': 'TARIQ KHAN',
        'mobile': '03001234567',
        'sector': 'Model Town',
        'locality': 'Block A',
        'address': 'House 123',
        'order_no': 'ORD1',
        'rateType': 'DOMESTIC',
        'connection_no': 'CONN1001',
        'old_connection_no': 'OLD55',
        'connection_date': '12-05-2023',
        'connection_status': 'Regular Connection',
        'consumer_status': 'Active',
      });

      await db.insert('consumers', {
        'sr_no': 2,
        'consumer_name': 'MUHAMMAD ASLAM',
        'father_husband_name': 'ABDUL REHMAN',
        'mobile': '03219876543',
        'sector': 'Waris Colony',
        'locality': 'Zone B',
        'address': 'Street 4',
        'order_no': 'ORD2',
        'rateType': 'DOMESTIC',
        'connection_no': 'CONN1002',
        'old_connection_no': 'OLD56',
        'connection_date': '01-07-2023',
        'connection_status': 'Closed',
        'consumer_status': 'In-Active',
      });

      // Search for "Aslam"
      final results = await db.rawQuery(
        "SELECT * FROM consumers WHERE consumer_name LIKE ? ORDER BY CASE WHEN consumer_name = 'ASLAM KHAN' THEN 1 ELSE 2 END",
        ['%ASLAM%'],
      );

      expect(results.length, equals(2));
      expect(results.first['consumer_name'], equals('ASLAM KHAN'));
    });
  });

  group('Pakistani Name Normalization & Smart Search Parser Tests', () {
    test('NameNormalizer transliteration dictionary mappings', () {
      expect(NameNormalizer.normalize('Ismaeel'), equals('ISMAIL'));
      expect(NameNormalizer.normalize('shair'), equals('SHER'));
      expect(NameNormalizer.normalize('meher'), equals('MEHR'));
      expect(NameNormalizer.normalize('Mohammad Aslam'), equals('MUHAMMAD ASLAM'));
      expect(NameNormalizer.normalize('Mohd Ismaeel Shair'), equals('MUHAMMAD ISMAIL SHER'));
      expect(NameNormalizer.normalize('  ch.  tariq  '), equals('CHAUDHRY TARIQ'));
    });

    test('SmartSearchParser compound sector and name extraction', () {
      // Name + Sector
      final res1 = SmartSearchParser.parse('ASLAM ALI TOWN');
      expect(res1.hasSector, isTrue);
      expect(res1.detectedSector, equals('Ali Town'));
      expect(res1.cleanKeywords, equals('ASLAM'));

      // Sector + Name
      final res2 = SmartSearchParser.parse('FAROOQ COLONY MUHAMMAD ASLAM');
      expect(res2.hasSector, isTrue);
      expect(res2.detectedSector, equals('Farooq Colony'));
      expect(res2.cleanKeywords, equals('MUHAMMAD ASLAM'));

      // Gulberg alias
      final res3 = SmartSearchParser.parse('TARIQ GULBERG');
      expect(res3.hasSector, isTrue);
      expect(res3.detectedSector, equals('Gulberg Town 14/G'));
      expect(res3.cleanKeywords, equals('TARIQ'));

      // Name only without sector
      final res4 = SmartSearchParser.parse('FAHEEM ABBAS');
      expect(res4.hasSector, isFalse);
      expect(res4.cleanKeywords, equals('FAHEEM ABBAS'));

      // Asif Farooq Colony
      final res5 = SmartSearchParser.parse('ASIF FAROOQ COLONY');
      expect(res5.hasSector, isTrue);
      expect(res5.detectedSector, equals('Farooq Colony'));
      expect(res5.cleanKeywords, equals('ASIF'));

      // Asif Ali Town
      final res6 = SmartSearchParser.parse('ASIF ALI TOWN');
      expect(res6.hasSector, isTrue);
      expect(res6.detectedSector, equals('Ali Town'));
      expect(res6.cleanKeywords, equals('ASIF'));

      // Riaz
      final res7 = SmartSearchParser.parse('RIAZ');
      expect(res7.hasSector, isFalse);
      expect(res7.cleanKeywords, equals('RIAZ'));
    });
  });
}
