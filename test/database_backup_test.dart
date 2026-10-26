import 'dart:io';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/consumer_model.dart';
import 'package:consumer_search_engine/screens/settings_screen.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> fixture(
  String path, {
  bool optional = true,
  bool fts = false,
}) async {
  final db = await databaseFactoryFfi.openDatabase(path);
  final columns = {
    'consumers': Consumer.fromMap({}).toMap().keys,
    'bill_history': const BillHistory(connectionNo: '').toMap().keys,
  };
  for (final entry in columns.entries) {
    await db.execute(
      'CREATE TABLE ${entry.key} ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      '${entry.value.map((k) => '"$k" ${k == 'sr_no' && entry.key == 'consumers' ? 'INTEGER' : 'TEXT'}').join(', ')}'
      '${entry.key == 'bill_history' ? ', UNIQUE(connection_no, bill_no) ON CONFLICT REPLACE' : ''})',
    );
  }
  if (optional) {
    await db.execute(
      'CREATE TABLE voice_aliases (spoken TEXT PRIMARY KEY, corrected TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE bill_report_members (connection_no TEXT, bill_no TEXT, PRIMARY KEY(connection_no, bill_no))',
    );
    await db.execute(
      'CREATE TABLE bill_report_sources (name TEXT PRIMARY KEY, imported_at TEXT)',
    );
  }
  if (fts) {
    await db.execute(
      "CREATE VIRTUAL TABLE consumers_fts USING fts5(consumer_name, content='consumers', content_rowid='id')",
    );
  }
  await db.execute('PRAGMA user_version = 3');
  return db;
}

Future<void> seed(Database db, String prefix) async {
  await db.insert(
    'consumers',
    Consumer.fromMap({
      'consumer_name': '${prefix}NAME',
      'connection_no': '${prefix}001',
      'sr_no': 1,
    }).toMap(),
  );
  await db.insert(
    'bill_history',
    BillHistory(
      connectionNo: '${prefix}001',
      billNo: '${prefix}BILL',
      waterFee: '2400',
      amountReceived: '1200',
      totalBill: '2400',
      billingPeriod: '01/01/2026 - 30/06/2026',
      receiveDate: '01/03/2026',
    ).toMap(),
  );
  await db.insert('voice_aliases', {
    'spoken': '${prefix}SPOKEN',
    'corrected': '${prefix}NAME',
  });
  await db.insert('bill_report_members', {
    'connection_no': '${prefix}001',
    'bill_no': '${prefix}BILL',
  });
  await db.insert('bill_report_sources', {
    'name': '$prefix.csv',
    'imported_at': '2026-10-21',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SQLite backup replacement', () {
    late Directory folder;
    late Database active;
    late DatabaseService service;
    const tables = [
      'consumers',
      'bill_history',
      'voice_aliases',
      'bill_report_members',
      'bill_report_sources',
    ];

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('consumer-restore-test-');
      active = await fixture(p.join(folder.path, 'active.db'), fts: true);
      service = DatabaseService.forTesting(active);
      await seed(active, 'OLD');
      await active.execute(
        "INSERT INTO consumers_fts(consumers_fts) VALUES('rebuild')",
      );
    });
    tearDown(() async {
      await active.close();
      await folder.delete(recursive: true);
    });

    Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
      for (final table in tables) table: await active.query(table),
      'sequence': await active.query('sqlite_sequence'),
    };

    test(
      'replaces every dataset, preserves backup, rebuilds search and restores ID sequence',
      () async {
        final path = p.join(folder.path, 'backup with spaces.db');
        final backup = await fixture(path);
        await seed(backup, 'NEW');
        await backup.insert('consumers', {
          'consumer_name': 'DELETED',
          'connection_no': 'D',
        });
        await backup.delete(
          'consumers',
          where: 'connection_no = ?',
          whereArgs: ['D'],
        );
        final expected = {
          for (final table in tables) table: await backup.query(table),
        };
        await backup.close();
        final bytes = await File(path).readAsBytes();

        expect(await service.restoreDatabaseBackup(path), 1);
        for (final table in tables) {
          expect(await active.query(table), expected[table], reason: table);
        }
        expect(
          await active.rawQuery(
            "SELECT rowid FROM consumers_fts WHERE consumers_fts MATCH 'OLDNAME'",
          ),
          isEmpty,
        );
        expect(
          await active.rawQuery(
            "SELECT rowid FROM consumers_fts WHERE consumers_fts MATCH 'NEWNAME'",
          ),
          hasLength(1),
        );
        expect(await active.insert('consumers', {'consumer_name': 'AFTER'}), 3);
        expect(await File(path).readAsBytes(), bytes);
      },
    );

    test(
      'bad, unrelated, incompatible and newer backups leave current data unchanged',
      () async {
        final before = await snapshot();
        final invalid = File(p.join(folder.path, 'invalid.db'));
        await invalid.writeAsString('not a database');
        await expectLater(
          service.restoreDatabaseBackup(invalid.path),
          throwsFormatException,
        );
        final unrelated = await databaseFactoryFfi.openDatabase(
          p.join(folder.path, 'unrelated.db'),
        );
        await unrelated.execute('CREATE TABLE something_else (value TEXT)');
        await unrelated.close();
        await expectLater(
          service.restoreDatabaseBackup(unrelated.path),
          throwsFormatException,
        );
        final newer = await fixture(p.join(folder.path, 'newer.db'));
        await newer.execute('PRAGMA user_version = 99');
        await newer.close();
        await expectLater(
          service.restoreDatabaseBackup(newer.path),
          throwsFormatException,
        );
        final incompatible = await fixture(
          p.join(folder.path, 'incompatible.db'),
        );
        await incompatible.execute(
          'ALTER TABLE consumers ADD COLUMN future_field TEXT',
        );
        await incompatible.close();
        await expectLater(
          service.restoreDatabaseBackup(incompatible.path),
          throwsFormatException,
        );
        expect(await snapshot(), before);
      },
    );

    test(
      'a damaged SQLite file is rejected before records are replaced',
      () async {
        final before = await snapshot();
        final broken = File(p.join(folder.path, 'broken.db'));
        await broken.writeAsBytes([
          ...('SQLite format 3\u0000'.codeUnits),
          ...List.filled(200, 0),
        ]);
        await expectLater(
          service.restoreDatabaseBackup(broken.path),
          throwsA(anything),
        );
        expect(await snapshot(), before);
      },
    );

    test(
      'failure after deletes rolls back all tables and the search index',
      () async {
        final backup = await fixture(p.join(folder.path, 'rollback.db'));
        await seed(backup, 'NEW');
        await backup.close();
        final before = await snapshot();
        await active.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON bill_history BEGIN SELECT RAISE(ABORT, 'Simulated write failure'); END",
        );
        await expectLater(
          service.restoreDatabaseBackup(backup.path),
          throwsA(anything),
        );
        expect(await snapshot(), before);
        expect(
          await active.rawQuery(
            "SELECT rowid FROM consumers_fts WHERE consumers_fts MATCH 'OLDNAME'",
          ),
          hasLength(1),
        );
        await active.execute('DROP TRIGGER fail_restore');
        expect(await service.restoreDatabaseBackup(backup.path), 1);
      },
    );

    test(
      'absent optional tables clear old report selections and voice corrections',
      () async {
        final backup = await fixture(
          p.join(folder.path, 'older.db'),
          optional: false,
        );
        await backup.insert('consumers', {
          'consumer_name': 'NEW',
          'connection_no': 'NEW001',
        });
        await backup.close();
        expect(await service.restoreDatabaseBackup(backup.path), 1);
        for (final table in [
          'voice_aliases',
          'bill_report_members',
          'bill_report_sources',
        ]) {
          expect(await active.query(table), isEmpty);
        }
      },
    );

    test(
      'an empty app backup replaces existing records with an empty dataset',
      () async {
        final backup = await fixture(p.join(folder.path, 'empty.db'));
        await backup.close();
        expect(await service.restoreDatabaseBackup(backup.path), 0);
        for (final table in tables) {
          expect(await active.query(table), isEmpty);
        }
        expect(
          await active.rawQuery(
            "SELECT rowid FROM consumers_fts WHERE consumers_fts MATCH 'OLDNAME'",
          ),
          isEmpty,
        );
      },
    );

    test(
      'conflicting bill identities cannot silently discard backup records',
      () async {
        final backup = await fixture(p.join(folder.path, 'conflicting.db'));
        await seed(backup, 'NEW');
        await backup.execute(
          'CREATE TABLE duplicate_bills AS SELECT * FROM bill_history',
        );
        await backup.execute(
          'INSERT INTO duplicate_bills SELECT * FROM bill_history',
        );
        await backup.execute(
          'UPDATE duplicate_bills SET id = id + 100 WHERE rowid = 2',
        );
        await backup.execute('DROP TABLE bill_history');
        await backup.execute(
          'ALTER TABLE duplicate_bills RENAME TO bill_history',
        );
        await backup.close();
        final before = await snapshot();
        await expectLater(
          service.restoreDatabaseBackup(backup.path),
          throwsFormatException,
        );
        expect(await snapshot(), before);
      },
    );

    test('missing and active database paths are refused', () async {
      final before = await snapshot();
      final missing = p.join(folder.path, 'missing.db');
      await expectLater(
        service.restoreDatabaseBackup(missing),
        throwsFormatException,
      );
      expect(await File(missing).exists(), isFalse);
      await expectLater(
        service.restoreDatabaseBackup(active.path),
        throwsFormatException,
      );
      expect(await snapshot(), before);
    });

    test(
      'export includes committed WAL records and restores without the live WAL',
      () async {
        await active.rawQuery('PRAGMA journal_mode = WAL');
        await active.execute('PRAGMA wal_autocheckpoint = 0');
        await active.insert('consumers', {
          'consumer_name': 'WALONLY',
          'connection_no': 'WAL001',
        });
        final backupFile = File(p.join(folder.path, 'standalone.db'));
        await backupFile.writeAsBytes(await service.createDatabaseBackup());
        await active.delete(
          'consumers',
          where: 'connection_no = ?',
          whereArgs: ['WAL001'],
        );
        expect(await service.restoreDatabaseBackup(backupFile.path), 2);
        expect(
          await active.query(
            'consumers',
            where: 'connection_no = ?',
            whereArgs: ['WAL001'],
          ),
          hasLength(1),
        );
      },
    );
  });

  testWidgets(
    'replacement popup clearly warns and requires an explicit choice',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => result =
                    await confirmDatabaseBackupImport(context, 'sample.db'),
                child: const Text('Import'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(find.text('Replace all data with this backup?'), findsOneWidget);
      expect(find.textContaining('NOT be merged'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace All Data & Import'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    },
  );
}
