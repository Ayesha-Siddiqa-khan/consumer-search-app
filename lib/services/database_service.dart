import 'dart:io';
import 'dart:convert';
import '../models/bill_import_model.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/consumer_model.dart';
import '../models/bill_history_model.dart';
import '../models/billing_audit_model.dart';
import 'name_normalizer.dart';

typedef _AuditRows = ({
  List<Map<String, Object?>> consumers,
  List<Map<String, Object?>> bills,
  List<Map<String, Object?>> states,
  List<Map<String, Object?>> quarantine,
  String billGroup,
});

// Keep reconciliation and source-flag preparation off the desktop UI isolate.
List<BillingAuditEntry> _buildDatabaseAudit(_AuditRows rows) {
  final authoritativeHistory = {
    for (final row in rows.states)
      if (row['kind'] == 'history')
        '${row['connection_no']}'.trim().toUpperCase(),
  };
  final flags = {
    for (final row in rows.states)
      billIdentity('${row['connection_no']}', '${row['bill_no']}'): row['issues'],
  };
  final unallocated = <String>{};
  for (final row in rows.quarantine) {
    final key = '${row['connection_no']}'.trim().toUpperCase();
    if (authoritativeHistory.contains(key)) continue;
    final original =
        jsonDecode(row['row_json'] as String) as Map<String, dynamic>;
    if ((importAmountInPaisa(original['amount_received']) ?? 0) > 0) {
      unallocated.add(key);
    }
  }
  final consumers = [
    for (final consumer in rows.consumers)
      {
        ...consumer,
        'unallocated_receipt_review': unallocated.contains(
          '${consumer['connection_no']}'.trim().toUpperCase(),
        ),
      },
  ];
  final bills = [
    for (final bill in rows.bills)
      {
        ...bill,
        'import_issues': flags[billIdentity(
          '${bill['connection_no']}', '${bill['bill_no']}',
        )],
      },
  ];
  return buildBillingAudit(
    consumers: consumers,
    bills: bills,
    billGroup: rows.billGroup,
  );
}

class SearchResult {
  final List<Consumer> items;
  final int totalCount;
  final int page;
  final int pageSize;

  SearchResult({
    required this.items,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });

  int get totalPages => (totalCount / pageSize).ceil();
  bool get hasPreviousPage => page > 1;
  bool get hasNextPage => page < totalPages;
}

class BillUpdateResult {
  final int updated;
  final List<String> unmatched;
  final List<String> ambiguous;
  const BillUpdateResult(this.updated, this.unmatched, this.ambiguous);
}

class DatabaseService {
  static final DatabaseService instance = DatabaseService._internal();
  DatabaseService._internal();

  @visibleForTesting
  DatabaseService.forTesting(Database db) : _db = db;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      // Desktop SQLite initialization via FFI
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    String dbPath;
    if (kIsWeb) {
      dbPath = 'consumer_database.db';
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final docDir = await getApplicationSupportDirectory();
      await Directory(docDir.path).create(recursive: true);
      dbPath = p.join(docDir.path, 'consumer_database.db');
    } else {
      final defaultPath = await getDatabasesPath();
      dbPath = p.join(defaultPath, 'consumer_database.db');
    }

    return await openDatabase(
      dbPath,
      version: 3,
      onCreate: _createTables,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA busy_timeout = 60000');
      },
    );
  }

  Future<void> _createTables(Database db, int version) async {
    // Main Consumers table
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

    // High performance B-tree indexes
    await db.execute('CREATE INDEX idx_c_name ON consumers(consumer_name);');
    await db.execute(
      'CREATE INDEX idx_c_fh_name ON consumers(father_husband_name);',
    );
    await db.execute('CREATE INDEX idx_c_mobile ON consumers(mobile);');
    await db.execute('CREATE INDEX idx_c_sector ON consumers(sector);');
    await db.execute('CREATE INDEX idx_c_locality ON consumers(locality);');
    await db.execute('CREATE INDEX idx_c_conn_no ON consumers(connection_no);');
    await db.execute(
      'CREATE INDEX idx_c_old_conn_no ON consumers(old_connection_no);',
    );
    await db.execute(
      'CREATE INDEX idx_c_conn_status ON consumers(connection_status);',
    );
    await db.execute(
      'CREATE INDEX idx_c_cons_status ON consumers(consumer_status);',
    );
    await db.execute('CREATE INDEX idx_c_rate_type ON consumers(rate_type);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_c_bill_status ON consumers(bill_status);');

    // SQLite FTS5 Virtual Table for ultra-fast full-text and prefix search
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE consumers_fts USING fts5(
          consumer_name,
          father_husband_name,
          mobile,
          connection_no,
          old_connection_no,
          locality,
          sector,
          address,
          content='consumers',
          content_rowid='id'
        );
      ''');
    } catch (e) {
      debugPrint('FTS5 virtual table init fallback: $e');
    }

    // Bill History table for full historical water & sanitation billing records
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bill_history (
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
        created_at TEXT DEFAULT '',
        UNIQUE(connection_no, bill_no) ON CONFLICT REPLACE
      );
    ''');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_report_members (connection_no TEXT, bill_no TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_report_sources (name TEXT PRIMARY KEY, imported_at TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_import_state (connection_no TEXT, bill_no TEXT, as_of TEXT, source TEXT, kind TEXT, issues TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS data_import_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, kind TEXT, sources TEXT, summary TEXT, issues TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_history_quarantine (connection_no TEXT, bill_no TEXT, source TEXT, as_of TEXT, reason TEXT, row_json TEXT, state_json TEXT, archived_at TEXT, PRIMARY KEY(connection_no, bill_no, source))');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_conn_no ON bill_history(connection_no);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_bill_no ON bill_history(bill_no);');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add bill columns if they don't exist
      final columns = await db.rawQuery("PRAGMA table_info(consumers)");
      final existingCols = columns.map((c) => c['name'] as String).toSet();
      for (final col in [
        'total_bill',
        'fine',
        'after_due_date',
        'due_date',
        'bill_status',
        'amount_received',
      ]) {
        if (!existingCols.contains(col)) {
          await db.execute(
            "ALTER TABLE consumers ADD COLUMN $col TEXT DEFAULT ''",
          );
        }
      }
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS bill_history (
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
          created_at TEXT DEFAULT '',
          UNIQUE(connection_no, bill_no) ON CONFLICT REPLACE
        );
      ''');
      await db.execute('CREATE TABLE IF NOT EXISTS bill_report_members (connection_no TEXT, bill_no TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_report_sources (name TEXT PRIMARY KEY, imported_at TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_import_state (connection_no TEXT, bill_no TEXT, as_of TEXT, source TEXT, kind TEXT, issues TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS data_import_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, kind TEXT, sources TEXT, summary TEXT, issues TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_history_quarantine (connection_no TEXT, bill_no TEXT, source TEXT, as_of TEXT, reason TEXT, row_json TEXT, state_json TEXT, archived_at TEXT, PRIMARY KEY(connection_no, bill_no, source))');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_conn_no ON bill_history(connection_no);');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_bill_no ON bill_history(bill_no);');
    }
  }

  /// Bulk insert with fast transactions in chunks of 2,000 records
  Future<void> insertBatch(
    List<Consumer> consumers, {
    void Function(int inserted, int total)? onProgress,
  }) async {
    final db = await database;
    const chunkSize = 2000;
    int insertedCount = 0;

    for (int i = 0; i < consumers.length; i += chunkSize) {
      final end = (i + chunkSize < consumers.length)
          ? i + chunkSize
          : consumers.length;
      final chunk = consumers.sublist(i, end);

      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final item in chunk) {
          batch.insert('consumers', item.toMap());
        }
        await batch.commit(noResult: true);
      });

      insertedCount += chunk.length;
      if (onProgress != null) {
        onProgress(insertedCount, consumers.length);
      }
    }

    // Rebuild FTS index after bulk insert
    try {
      await db.execute(
        "INSERT INTO consumers_fts(consumers_fts) VALUES('rebuild');",
      );
    } catch (e) {
      debugPrint('FTS rebuild notice: $e');
    }
  }

  /// Upsert consumers: update existing by connection_no, insert new ones
  /// Returns a summary: {'updated': N, 'inserted': N}
  Future<Map<String, int>> upsertBatch(
    List<Consumer> consumers, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      var inserted = 0;
      var updated = 0;
      final existing = <String, Map<String, Object?>>{};
      for (final row in await txn.query('consumers')) {
        final key = '${row['connection_no'] ?? ''}'.trim().toUpperCase();
        if (existing.containsKey(key)) throw FormatException('Duplicate consumer connection already in database: $key');
        existing[key] = row;
      }
      final seen = <String>{};
      var batch = txn.batch();
      var processed = 0;
      for (final consumer in consumers) {
        final key = consumer.connectionNo.trim().toUpperCase();
        if (key.isEmpty || !seen.add(key)) throw FormatException('Missing or repeated consumer connection: $key');
        final data = consumer.toMap()..remove('id');
        data['connection_no'] = key;
        for (final field in ['total_bill', 'fine', 'after_due_date', 'due_date', 'bill_status', 'amount_received']) {
          data.remove(field);
        }
        final old = existing[key];
        if (old == null) {
          batch.insert('consumers', data);
          inserted++;
        } else {
          batch.update('consumers', data, where: 'id = ?', whereArgs: [old['id']]);
          updated++;
        }
        processed++;
        if (processed % 1000 == 0 || processed == consumers.length) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          onProgress?.call(processed, consumers.length);
        }
      }
      if ((await txn.rawQuery("SELECT 1 FROM sqlite_master WHERE name = 'consumers_fts'")).isNotEmpty) {
        await txn.execute("INSERT INTO consumers_fts(consumers_fts) VALUES('rebuild')");
      }
      return {'updated': updated, 'inserted': inserted};
    });
  }

  /// Update bill fields for consumers matching given connection numbers
  /// Returns count of updated records
  Future<BillUpdateResult> updateBillsForConnections(
    Map<String, Map<String, String>> billsByConnNo, {
    void Function(int processed, int total)? onProgress,
    bool overwriteExisting = true,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'consumers',
        columns: ['id', 'connection_no'],
      );
      final ids = <String, List<int>>{};
      for (final row in rows) {
        final key = (row['connection_no'] as String? ?? '')
            .trim()
            .toUpperCase();
        if (key.isNotEmpty) (ids[key] ??= []).add(row['id'] as int);
      }
      var updated = 0;
      var processed = 0;
      var pending = 0;
      var batch = txn.batch();
      final unmatched = <String>[];
      final ambiguous = <String>[];
      for (final entry in billsByConnNo.entries) {
        final key = entry.key.trim().toUpperCase();
        final matches = ids[key];
        if (matches == null) {
          unmatched.add(key);
        } else if (matches.length != 1) {
          ambiguous.add(key);
        } else {
          // Only columns present in the CSV are written; omitted fields survive.
          if (overwriteExisting) {
            batch.update(
              'consumers',
              entry.value,
              where: 'id = ?',
              whereArgs: [matches.single],
            );
            pending++;
          } else {
            batch.update(
              'consumers',
              entry.value,
              where: "id = ? AND (total_bill IS NULL OR total_bill = '' OR total_bill = '0')",
              whereArgs: [matches.single],
            );
            pending++;
          }
        }
        processed++;
        if (pending >= 500 || processed == billsByConnNo.length) {
          final counts = await batch.commit();
          updated += counts.fold<int>(0, (sum, count) => sum + (count as int));
          batch = txn.batch();
          pending = 0;
          onProgress?.call(processed, billsByConnNo.length);
        }
      }
      return BillUpdateResult(updated, unmatched, ambiguous);
    });
  }

  /// Ensure bill_history table exists
  Future<void> _ensureBillHistoryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bill_history (
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
        created_at TEXT DEFAULT '',
        UNIQUE(connection_no, bill_no) ON CONFLICT REPLACE
      );
    ''');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_report_members (connection_no TEXT, bill_no TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_report_sources (name TEXT PRIMARY KEY, imported_at TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_import_state (connection_no TEXT, bill_no TEXT, as_of TEXT, source TEXT, kind TEXT, issues TEXT, PRIMARY KEY(connection_no, bill_no))');
    await db.execute('CREATE TABLE IF NOT EXISTS data_import_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, kind TEXT, sources TEXT, summary TEXT, issues TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS bill_history_quarantine (connection_no TEXT, bill_no TEXT, source TEXT, as_of TEXT, reason TEXT, row_json TEXT, state_json TEXT, archived_at TEXT, PRIMARY KEY(connection_no, bill_no, source))');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_conn_no ON bill_history(connection_no);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bh_bill_no ON bill_history(bill_no);');
  }

  /// Update a bill by its stable connection/bill identity, never by status or row number.
  Future<int> insertOrUpdateBillHistoryBatch(
    List<BillHistory> bills, {
    void Function(int processed, int total)? onProgress,
    String? reportSource,
    bool resetReport = true,
    bool isHistory = false,
  }) async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    for (final bill in bills) {
      if (bill.connectionNo.trim().isEmpty || bill.billNo.trim().isEmpty) {
        throw const FormatException('Every bill needs a Connection No and Bill No.');
      }
    }
    return db.transaction((txn) async {
      final existing = await txn.query('bill_history', columns: ['id', 'connection_no', 'bill_no']);
      String key(String connection, String bill) => '${connection.trim().toUpperCase()}|${bill.trim().toUpperCase()}';
      final ids = {for (final row in existing) key(row['connection_no'] as String, row['bill_no'] as String): row['id']};
      final unique = {for (final bill in bills) key(bill.connectionNo, bill.billNo): bill};

      final hasExistingReport = (await txn.query('bill_report_sources', limit: 1)).isNotEmpty;
      final shouldUpdateReport = !isHistory || !hasExistingReport;

      if (reportSource != null && resetReport && shouldUpdateReport) {
        await txn.delete('bill_report_members');
        await txn.delete('bill_report_sources');
      }
      final batch = txn.batch();
      for (final entry in unique.entries) {
        final bill = entry.value;
        final data = bill.toMap()..remove('id');
        data['connection_no'] = bill.connectionNo.trim().toUpperCase();
        data['bill_no'] = bill.billNo.trim().toUpperCase();
        final id = ids[entry.key];
        if (id != null) {
          batch.update('bill_history', data, where: 'id = ?', whereArgs: [id]);
        } else {
          batch.insert('bill_history', data);
        }
        if (reportSource != null && shouldUpdateReport) {
          if (!isHistory || bill.srNo == '1' || bill.srNo == '1.0') {
            batch.insert('bill_report_members', {
              'connection_no': data['connection_no'], 'bill_no': data['bill_no'],
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
      }
      if (reportSource != null && shouldUpdateReport) {
        batch.insert('bill_report_sources', {'name': reportSource, 'imported_at': DateTime.now().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      onProgress?.call(unique.length, unique.length);
      return unique.length;
    });
  }

  /// One upload group is atomic, including the current consumer bill summaries.
  Future<BillMergeReport> mergeImportedBills(
    List<ImportedBill> incoming, {
    required bool isHistory,
    required List<String> sources,
    required BillMergeReport report,
    List<ImportedBill> superseded = const [],
    bool repairSourceConflicts = false,
    void Function(int, int)? onProgress,
  }) async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    return db.transaction((txn) async {
      final existing = <String, Map<String, Object?>>{
        for (final row in await txn.query('bill_history'))
          billIdentity('${row['connection_no']}', '${row['bill_no']}'): row,
      };
      final metadata = <String, Map<String, Object?>>{
        for (final row in await txn.query('bill_import_state'))
          billIdentity('${row['connection_no']}', '${row['bill_no']}'): row,
      };
      final masters = <String, List<Map<String, Object?>>>{};
      for (final row in await txn.query('consumers')) {
        masters
            .putIfAbsent(
              '${row['connection_no']}'.trim().toUpperCase(),
              () => [],
            )
            .add(row);
      }
      final incomingKeys = incoming.map((b) => b.key).toSet();
      Future<void> quarantine(Map<String, Object?> row, Map<String, Object?>? state, String reason, String source) async {
        await txn.insert('bill_history_quarantine', {
          'connection_no': row['connection_no'], 'bill_no': row['bill_no'],
          'source': source, 'as_of': state?['as_of'] ?? '', 'reason': reason,
          'row_json': jsonEncode(row), 'state_json': jsonEncode(state),
          'archived_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final repairKeys = <String>{};
      final reconciledConnections = <String>{};
      for (final item in superseded) {
        await quarantine(item.bill.toMap(), {'as_of': item.asOf, 'source': item.source},
          'Superseded by newer history snapshot for the same period', item.source);
        if (existing.containsKey(item.key) && !incomingKeys.contains(item.key)) repairKeys.add(item.key);
      }
      final retiredKeys = <String>{
        for (final row in await txn.query('bill_history_quarantine', where: "reason LIKE 'Superseded%'"))
          billIdentity('${row['connection_no']}', '${row['bill_no']}'),
      };
      for (final key in repairKeys) {
        final row = existing[key]!;
        final state = metadata[key];
        await quarantine(row, state, 'Superseded by newer history snapshot for the same period', '${state?['source'] ?? 'previous database'}');
        await txn.delete('bill_history', where: 'id = ?', whereArgs: [row['id']]);
        await txn.delete('bill_import_state', where: 'connection_no = ? AND bill_no = ?', whereArgs: [row['connection_no'], row['bill_no']]);
        await txn.delete('bill_report_members', where: 'connection_no = ? AND bill_no = ?', whereArgs: [row['connection_no'], row['bill_no']]);
        reconciledConnections.add('${row['connection_no']}'.trim().toUpperCase());
        existing.remove(key); metadata.remove(key);
        report.issue(key, 'Superseded history archived; excluded from active totals', '${state?['source'] ?? ''}');
      }
      final periodKeys = <String, Set<String>>{};
      for (final entry in existing.entries) {
        final period = historyPeriodIdentity(BillHistory.fromMap(entry.value));
        if (period != null) periodKeys.putIfAbsent(period, () => {}).add(entry.key);
      }
      final accepted = <String, Map<String, Object?>>{};
      final acceptedDates = <String, String>{};
      var batch = txn.batch();
      var processed = 0;
      for (final item in incoming) {
        final old = existing[item.key];
        final state = metadata[item.key];
        final conn = item.bill.connectionNo.trim().toUpperCase();
        final billNo = item.bill.billNo.trim().toUpperCase();
        if (state != null &&
            (item.asOf.compareTo('${state['as_of']}') < 0 ||
                (isHistory &&
                    item.asOf == state['as_of'] &&
                    state['kind'] == 'daily'))) {
          report.unchanged++;
          report.issue(item.key, 'Older snapshot ignored', item.source);
          continue;
        }
        if (retiredKeys.contains(item.key) && !isHistory) {
          report.held++;
          await quarantine(item.bill.toMap(), {'as_of': item.asOf, 'source': item.source},
            'Daily update refers to superseded bill number; receipt allocation needs review', 'daily review: ${item.source}');
          report.issue(item.key, 'Daily update for superseded bill held; no duplicate demand created', item.source);
          continue;
        }
        final period = historyPeriodIdentity(item.bill);
        if (old == null && period != null && isHistory) {
          final otherKeys = (periodKeys[period] ?? <String>{}).where((key) => !incomingKeys.contains(key)).toList();
          var blocked = false;
          for (final key in otherKeys) {
            final other = existing[key]!;
            final otherState = metadata[key];
            if (item.asOf.compareTo('${otherState?['as_of'] ?? ''}') > 0) {
              await quarantine(other, otherState, 'Superseded by newer history snapshot for the same period', '${otherState?['source'] ?? 'previous database'}');
              await txn.delete('bill_history', where: 'id = ?', whereArgs: [other['id']]);
              await txn.delete('bill_import_state', where: 'connection_no = ? AND bill_no = ?', whereArgs: [other['connection_no'],other['bill_no']]);
              await txn.delete('bill_report_members', where: 'connection_no = ? AND bill_no = ?', whereArgs: [other['connection_no'],other['bill_no']]);
              report.superseded++;
              reconciledConnections.add('${other['connection_no']}'.trim().toUpperCase());
              retiredKeys.add(key);existing.remove(key);metadata.remove(key);periodKeys[period]!.remove(key);
            } else { blocked = true; }
          }
          if (blocked) {
            report.held++;
            await quarantine(item.bill.toMap(), {'as_of': item.asOf},
              'Older or equal-date alternative bill number for an existing period; review required', item.source);
            report.issue(item.key, 'Alternative bill number for existing period held; active snapshot preserved', item.source);
            continue;
          }
        }
        final data = item.bill.toMap()..remove('id');
        if (old != null) {
          for (final field in data.keys.toList()) {
            if (!item.fields.contains(field) ||
                field == 'created_at' ||
                (!importMoneyFields.contains(field) &&
                    ['', '-', '--'].contains('${data[field]}'.trim()))) {
              data[field] = old[field];
            }
          }
          final oldReceipt = auditAmountInPaisa(old['amount_received']) ?? 0;
          final receipt = auditAmountInPaisa(data['amount_received']) ?? 0;
          if (receipt < oldReceipt ||
              ('${old['status']}'.toLowerCase() == 'paid' &&
                  '${data['status']}'.toLowerCase() != 'paid')) {
            report.held++;
            report.issue(
              item.key,
              'Payment regression held; existing payment preserved',
              item.source,
            );
            continue;
          }
        }
        data['connection_no'] = conn;
        data['bill_no'] = billNo;
        final reasons = <String>[];
        if ([
              'arrears',
              'total_bill',
              'after_due_date',
            ].any((field) => (importAmountInPaisa(data[field]) ?? 0) < 0) &&
            !hasConsistentAdvanceCredit(data)) {
          reasons.add(negativeCreditReviewIssue);
        }
        final master = masters[conn];
        if (master == null) {
          reasons.add('Connection missing from consumer master');
        }
        if (master != null && master.length != 1) {
          report.held++;
          report.issue(
            item.key,
            'Ambiguous duplicate consumer connection; bill held',
            item.source,
          );
          continue;
        }
        if (master?.length == 1 && '${data['consumer_name']}'.trim().isNotEmpty &&
            '${data['consumer_name']}'.trim().toUpperCase() != '${master!.single['consumer_name']}'.trim().toUpperCase()) {
          reasons.add('History name differs from consumer master; identity not reassigned');
        }
        for (final field in ['due_date', 'receive_date']) {
          final date = validImportDate('${data[field] ?? ''}');
          if (date == null) {
            if (!['', '-', '--'].contains('${data[field] ?? ''}')) {
              reasons.add('Invalid source $field');
            }
            data[field] = validImportDate('${old?[field] ?? ''}') ?? '-';
          } else {
            data[field] = date;
          }
        }
        if (old != null &&
            validImportDate(item.bill.receiveDate) == null &&
            (comparableBillValue('amount_received', data['amount_received']) !=
                    comparableBillValue(
                      'amount_received',
                      old['amount_received'],
                    ) ||
                '${state?['issues'] ?? ''}'.contains(
                  'Receipt amount changed without source receipt date',
                ))) {
          reasons.add(
            'Receipt amount changed without source receipt date; existing date retained',
          );
        }
        if ('${data['status']}'.toLowerCase() == 'paid' &&
            validImportDate('${data['receive_date']}') == null) {
          reasons.add('Paid receipt date missing');
        }
        if ('${data['billing_period'] ?? ''}'.trim().isEmpty) {
          reasons.add('Billing period missing; check possible reissue');
        }
        final same =
            old != null &&
            data.entries.every(
              (e) =>
                  comparableBillValue(e.key, e.value) ==
                  comparableBillValue(e.key, old[e.key]),
            );
        if (same) {
          report.unchanged++;
        } else if (old != null) {
          batch.update(
            'bill_history',
            data,
            where: 'id = ?',
            whereArgs: [old['id']],
          );
          report.updated++;
        } else {
          data['created_at'] = DateTime.now().toIso8601String();
          batch.insert('bill_history', data);
          report.inserted++;
        }
        batch.insert('bill_import_state', {
          'connection_no': conn,
          'bill_no': billNo,
          'as_of': item.asOf,
          'source': item.source,
          'kind': isHistory ? 'history' : 'daily',
          'issues': reasons.join('; '),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final reason in reasons) {
          report.issue(item.key, reason, item.source);
        }
        if (period != null) periodKeys.putIfAbsent(period, () => {}).add(item.key);
        accepted[item.key] = data;
        acceptedDates[item.key] = item.asOf;
        existing[item.key] = {...data, if (old != null) 'id': old['id']};
        processed++;
        if (processed % 1000 == 0) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          onProgress?.call(processed, incoming.length);
        }
      }
      await batch.commit(noResult: true);
      final latest = <String, Map<String, Object?>>{};
      for (final row in (isHistory ? existing.values : accepted.values)) {
        final conn = '${row['connection_no']}'.trim().toUpperCase();
        final previous = latest[conn];
        final number = BigInt.tryParse('${row['bill_no']}');
        final prevNumber = BigInt.tryParse('${previous?['bill_no']}');
        if (previous == null ||
            (number != null && prevNumber != null && number > prevNumber)) {
          latest[conn] = row;
        }
      }
      final latestDailyDates = <String, String>{};
      for (final state in metadata.values.where((m) => m['kind'] == 'daily')) {
        final conn = '${state['connection_no']}'.trim().toUpperCase();
        final date = '${state['as_of']}';
        if (date.compareTo(latestDailyDates[conn] ?? '') > 0) {
          latestDailyDates[conn] = date;
        }
      }
      batch = txn.batch();
      for (final entry in latest.entries) {
        final master = masters[entry.key];
        if (master?.length != 1) continue;
        final row = entry.value;
        if (isHistory && !repairSourceConflicts && !reconciledConnections.contains(entry.key) &&
            '${master!.single['total_bill'] ?? ''}'.trim().isNotEmpty &&
            (importAmountInPaisa(master.single['total_bill']) ?? 0) != 0) {
          continue;
        }
        if (!isHistory) {
          final incomingDate =
              acceptedDates[billIdentity(entry.key, '${row['bill_no']}')]!;
          if ((latestDailyDates[entry.key] ?? '').compareTo(incomingDate) > 0) {
            continue;
          }
        }
        if (!accepted.containsKey(billIdentity(entry.key, '${row['bill_no']}'))) {
          continue;
        }
        final fields = <String, Object?>{
          'total_bill': row['total_bill'],
          'fine': row['fine'],
          'after_due_date': row['after_due_date'],
          'due_date': row['due_date'],
          'bill_status': row['status'],
          'amount_received': row['amount_received'],
        };
        if (fields.entries.any(
          (e) =>
              comparableBillValue(e.key, e.value) !=
              comparableBillValue(e.key, master!.single[e.key]),
        )) {
          batch.update(
            'consumers',
            fields,
            where: 'id = ?',
            whereArgs: [master!.single['id']],
          );
          report.consumersUpdated++;
        }
      }
      final hasReport = (await txn.query(
        'bill_report_sources',
        limit: 1,
      )).isNotEmpty;
      String newest(Iterable<String> dates) => dates.fold('', (a, b) => a.compareTo(b) > 0 ? a : b);
      final canReplaceDailyReport = !isHistory && accepted.isNotEmpty &&
          newest(incoming.map((b) => b.asOf)).compareTo(newest(latestDailyDates.values)) >= 0;
      if (canReplaceDailyReport || (isHistory && !hasReport)) {
        batch.delete('bill_report_members');
        batch.delete('bill_report_sources');
        final members = isHistory ? latest.values : accepted.values;
        for (final row in members) {
          batch.insert('bill_report_members', {
            'connection_no': row['connection_no'],
            'bill_no': row['bill_no'],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final source in sources) {
          batch.insert('bill_report_sources', {
            'name': source,
            'imported_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      batch.insert('data_import_runs', {
        'created_at': DateTime.now().toIso8601String(),
        'kind': isHistory ? 'history' : 'daily',
        'sources': jsonEncode(sources),
        'summary': jsonEncode({
          'inserted': report.inserted,
          'updated': report.updated,
          'unchanged': report.unchanged,
          'held': report.held,
          'duplicate_rows': report.duplicateRows,
        }),
        'issues': jsonEncode(report.issues),
      });
      await batch.commit(noResult: true);
      onProgress?.call(incoming.length, incoming.length);
      return report;
    });
  }

  /// Get bill history for a specific connection number
  Future<List<BillHistory>> getBillHistory(String connectionNo) async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    final clean = connectionNo.trim();
    if (clean.isEmpty) return [];

    final rows = await db.query(
      'bill_history',
      where: 'LOWER(TRIM(connection_no)) = ?',
      whereArgs: [clean.toLowerCase()],
      orderBy: 'CAST(bill_no AS INTEGER) DESC, bill_no DESC, id DESC',
    );
    final master = await db.query(
      'consumers',
      columns: ['sector'],
      where: 'LOWER(TRIM(connection_no)) = ?',
      whereArgs: [clean.toLowerCase()],
      limit: 1,
    );
    final sector = '${master.isEmpty ? rows.isEmpty ? '' : rows.first['sector'] ?? '' : master.first['sector'] ?? ''}';
    return applyConfirmedSectorPayments(rows, sector).map(BillHistory.fromMap).toList();
  }

  /// Reconcile only generated bills, irrespective of the connection's age or rate.
  Future<List<BillingAuditEntry>> getBillingAudit({
    String billGroup = 'all',
    String? connectionNo,
  }) async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    final rows = await db.transaction((txn) async {
      final filter = connectionNo == null
          ? null
          : 'LOWER(TRIM(connection_no)) = ?';
      final args = connectionNo == null
          ? null
          : [connectionNo.trim().toLowerCase()];
      final consumers = await txn.query(
        'consumers',
        where: filter,
        whereArgs: args,
        columns: [
          'connection_no',
          'consumer_name',
          'father_husband_name',
          'sector',
          'locality',
          'address',
          'rate_type',
          'connection_date',
          'connection_status',
          'consumer_status',
          'bill_status',
        ],
        orderBy: 'id',
      );
      final bills = await txn.query(
        'bill_history',
        where: filter,
        whereArgs: args,
        columns: [
          'connection_no',
          'bill_no',
          'water_fee',
          'amount_received',
          'consumer_name',
          'father_husband_name',
          'sector',
          'locality',
          'status',
          'total_bill',
          'fine',
          'sanitation',
          'drainage',
          'billing_fee',
          'arrears',
          'bill_type',
          'billing_period',
          'due_date',
          'after_due_date',
        ],
        orderBy: 'id DESC',
      );
      final importStates = await txn.query(
        'bill_import_state',
        where: filter,
        whereArgs: args,
        columns: ['connection_no', 'bill_no', 'kind', 'issues'],
      );
      final quarantine = await txn.query(
        'bill_history_quarantine',
        columns: ['connection_no', 'row_json'],
        where:
            "reason LIKE 'Daily update refers to superseded%'${filter == null ? '' : ' AND $filter'}",
        whereArgs: args,
      );
      return (
        consumers: consumers,
        bills: bills,
        states: importStates,
        quarantine: quarantine,
        billGroup: billGroup,
      );
    });
    // Small, connection-scoped histories avoid isolate startup and copying costs.
    return rows.bills.length < 500
        ? _buildDatabaseAudit(rows)
        : compute(_buildDatabaseAudit, rows, debugLabel: 'billing-audit');
  }

  /// Get bill history total count
  Future<int> getBillHistoryCount() async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    final res = await db.rawQuery('SELECT COUNT(*) as count FROM bill_history');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Check if bill history exists for a connection
  Future<bool> hasBillHistory(String connectionNo) async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    final clean = connectionNo.trim();
    if (clean.isEmpty) return false;
    final res = await db.rawQuery(
      'SELECT 1 FROM bill_history WHERE LOWER(TRIM(connection_no)) = ? LIMIT 1',
      [clean.toLowerCase()],
    );
    return res.isNotEmpty;
  }

  /// Sync latest bill status and totals from bill_history to consumers table
  Future<void> syncLatestBillsToConsumers() async {
    final db = await database;
    await _ensureBillHistoryTable(db);
    try {
      await db.execute('''
        UPDATE consumers
        SET bill_status = (
          SELECT bh.status FROM bill_history bh
          WHERE bh.connection_no = consumers.connection_no
          ORDER BY CASE WHEN bh.sr_no = '1' THEN 0 ELSE 1 END, bh.id DESC
          LIMIT 1
        )
        WHERE (consumers.bill_status IS NULL OR consumers.bill_status = '')
          AND EXISTS (SELECT 1 FROM bill_history bh WHERE bh.connection_no = consumers.connection_no);
      ''');
    } catch (e) {
      debugPrint('Sync bill_status note: $e');
    }
  }

  /// Get consumer details by Connection No (from consumers table or bill_history)
  Future<Map<String, String>?> getConsumerConnectionDetail(String connectionNo) async {
    final db = await database;
    final clean = connectionNo.trim();
    if (clean.isEmpty) return null;

    // 1. Try from consumers table first
    final consumerRows = await db.query(
      'consumers',
      where: 'LOWER(TRIM(connection_no)) = ?',
      whereArgs: [clean.toLowerCase()],
      limit: 1,
    );
    if (consumerRows.isNotEmpty) {
      final r = consumerRows.first;
      return {
        'connection_no': (r['connection_no'] as String? ?? clean).trim(),
        'sector': (r['sector'] as String? ?? '').trim(),
        'locality': (r['locality'] as String? ?? '').trim(),
        'consumer_name': (r['consumer_name'] as String? ?? '').trim(),
        'father_husband_name': (r['father_husband_name'] as String? ?? '').trim(),
      };
    }

    // 2. Try from bill_history table
    await _ensureBillHistoryTable(db);
    final billRows = await db.query(
      'bill_history',
      where: 'LOWER(TRIM(connection_no)) = ?',
      whereArgs: [clean.toLowerCase()],
      limit: 1,
    );
    if (billRows.isNotEmpty) {
      final r = billRows.first;
      return {
        'connection_no': (r['connection_no'] as String? ?? clean).trim(),
        'sector': (r['sector'] as String? ?? '').trim(),
        'locality': (r['locality'] as String? ?? '').trim(),
        'consumer_name': (r['consumer_name'] as String? ?? '').trim(),
        'father_husband_name': (r['father_husband_name'] as String? ?? '').trim(),
      };
    }

    return null;
  }

  /// Advanced Search with Filters, Instant Fuzzy Prefix Matching and Pagination
  Future<SearchResult> searchConsumers({
    String? query,
    String? searchBy,
    String? sector,
    String? locality,
    String? consumerStatus,
    String? connectionStatus,
    String? rateType,
    String? billStatus,
    bool voiceNameSearch = false,
    int page = 1,
    int pageSize = 10,
  }) async {
    final db = await database;
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    // Filter by Sector
    if (sector != null && sector.trim().isNotEmpty && sector != 'All Sectors') {
      whereClauses.add('sector = ?');
      whereArgs.add(sector.trim());
    }

    // Filter by Locality
    if (locality != null &&
        locality.trim().isNotEmpty &&
        locality != 'All Localities') {
      whereClauses.add('locality = ?');
      whereArgs.add(locality.trim());
    }

    // Filter by Consumer Status (Active / In-Active)
    if (consumerStatus != null &&
        consumerStatus.trim().isNotEmpty &&
        consumerStatus != 'All Statuses') {
      if (consumerStatus.toLowerCase() == 'active') {
        whereClauses.add("LOWER(consumer_status) = 'active'");
      } else {
        whereClauses.add(
          "LOWER(consumer_status) LIKE '%inactive%' OR LOWER(consumer_status) LIKE '%in-active%'",
        );
      }
    }

    // Filter by Connection Status
    if (connectionStatus != null &&
        connectionStatus.trim().isNotEmpty &&
        connectionStatus != 'All Connection Statuses') {
      whereClauses.add('connection_status = ?');
      whereArgs.add(connectionStatus.trim());
    }

    // Filter by Rate Type
    if (rateType != null &&
        rateType.trim().isNotEmpty &&
        rateType != 'All Rate Types') {
      whereClauses.add('rate_type = ?');
      whereArgs.add(rateType.trim());
    }

    // Filter by Bill Status (Paid / Un-Paid / Expired)
    if (billStatus != null &&
        billStatus.trim().isNotEmpty &&
        billStatus != 'All Bills' &&
        billStatus != 'All Bill Statuses') {
      final cleanBill = billStatus.trim().toLowerCase();
      if (cleanBill == 'paid') {
        whereClauses.add("(LOWER(bill_status) = 'paid' OR (LOWER(bill_status) LIKE '%paid%' AND LOWER(bill_status) NOT LIKE '%un%'))");
      } else if (cleanBill == 'un-paid' || cleanBill == 'unpaid') {
        whereClauses.add("(LOWER(bill_status) LIKE '%un-paid%' OR LOWER(bill_status) LIKE '%unpaid%' OR LOWER(bill_status) LIKE '%expired%')");
      } else if (cleanBill == 'expired') {
        whereClauses.add("LOWER(bill_status) LIKE '%expired%'");
      } else {
        whereClauses.add("LOWER(bill_status) = ?");
        whereArgs.add(cleanBill);
      }
    }

    // Free-text Search (Multi-Token Cross-Field Search)
    final cleanQuery = query?.trim() ?? '';
    String? orderBy;

    if (cleanQuery.isNotEmpty) {
      final sanitized = cleanQuery.replaceAll("'", "''");
      final tokens = cleanQuery
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();

      if (searchBy != null && searchBy != 'all') {
        // Targeted Column Search
        final colMap = {
          'consumer_name': 'consumer_name',
          'father_husband_name': 'father_husband_name',
          'mobile': 'mobile',
          'connection_no': 'connection_no',
          'old_connection_no': 'old_connection_no',
          'address': 'address',
          'locality': 'locality',
          'order_no': 'order_no',
        };
        final targetCol = colMap[searchBy] ?? 'consumer_name';
        for (final token in tokens) {
          final variants = voiceNameSearch && targetCol == 'consumer_name'
              ? NameNormalizer.spellingVariants(token)
              : [token];
          whereClauses.add(
            '(${variants.map((_) => '$targetCol LIKE ?').join(' OR ')})',
          );
          whereArgs.addAll(variants.map((v) => '%$v%'));
        }
        orderBy =
            '''
          CASE
            WHEN $targetCol = '$sanitized' THEN 1
            WHEN $targetCol LIKE '$sanitized%' THEN 2
            WHEN $targetCol LIKE '%$sanitized%' THEN 3
            ELSE 4
          END, sr_no ASC
        ''';
      } else {
        // Multi-Token Smart Search across all relevant columns (AND between tokens, OR across fields)
        // This enables searching e.g. "aslam baldia" (finds Aslam in Baldia Colony)
        for (final token in tokens) {
          final tokenClause = '''
            (
              consumer_name LIKE ? OR
              father_husband_name LIKE ? OR
              connection_no LIKE ? OR
              old_connection_no LIKE ? OR
              mobile LIKE ? OR
              sector LIKE ? OR
              locality LIKE ? OR
              address LIKE ? OR
              order_no LIKE ? OR
              rate_type LIKE ?
            )
          ''';
          whereClauses.add(tokenClause);
          for (int i = 0; i < 10; i++) {
            whereArgs.add('%$token%');
          }
        }

        // Exact match & Cross-field ranking:
        // When multiple tokens exist (e.g. Aslam + Baldia), boost records matching both name and sector/locality
        String tokenBoost = '';
        if (tokens.length >= 2) {
          final t0 = tokens[0].replaceAll("'", "''");
          final t1 = tokens[1].replaceAll("'", "''");
          tokenBoost =
              '''
            WHEN consumer_name LIKE '%$t0%' AND (sector LIKE '%$t1%' OR locality LIKE '%$t1%') THEN 0
          ''';
        }

        orderBy =
            '''
          CASE
            $tokenBoost
            WHEN consumer_name = '$sanitized' THEN 1
            WHEN connection_no = '$sanitized' THEN 2
            WHEN old_connection_no = '$sanitized' THEN 3
            WHEN mobile = '$sanitized' THEN 4
            WHEN consumer_name LIKE '$sanitized%' THEN 5
            WHEN connection_no LIKE '$sanitized%' THEN 6
            WHEN father_husband_name LIKE '$sanitized%' THEN 7
            ELSE 8
          END, sr_no ASC
        ''';
      }
    } else {
      orderBy = 'sr_no ASC';
    }

    final whereString = whereClauses.isNotEmpty
        ? 'WHERE ${whereClauses.join(' AND ')}'
        : '';

    // Query Total Count
    final countSql = 'SELECT COUNT(*) as count FROM consumers $whereString';
    final countResult = await db.rawQuery(countSql, whereArgs);
    final totalCount = Sqflite.firstIntValue(countResult) ?? 0;

    // Query Paginated Data
    final offset = (page - 1) * pageSize;
    final dataSql =
        '''
      SELECT * FROM consumers
      $whereString
      ORDER BY $orderBy
      LIMIT $pageSize OFFSET $offset
    ''';

    final dataResult = await db.rawQuery(dataSql, whereArgs);
    final consumers = dataResult.map((m) => Consumer.fromMap(m)).toList();

    return SearchResult(
      items: consumers,
      totalCount: totalCount,
      page: page,
      pageSize: pageSize,
    );
  }

  /// Distinct Filter Dropdown Options
  Future<List<String>> getVoiceVocabulary({String? sector}) async {
    final db = await database;
    final rows = await db.query(
      'consumers',
      distinct: true,
      columns: ['consumer_name', 'father_husband_name'],
      where: sector == null ? null : 'sector = ?',
      whereArgs: sector == null ? null : [sector],
    );
    return rows
        .expand(
          (r) => [
            r['consumer_name'] as String? ?? '',
            r['father_husband_name'] as String? ?? '',
          ],
        )
        .toList();
  }

  Future<void> _ensureVoiceAliases(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS voice_aliases (
      spoken TEXT PRIMARY KEY, corrected TEXT NOT NULL
    )
  ''');

  Future<String?> getVoiceCorrection(String spoken) async {
    final db = await database;
    await _ensureVoiceAliases(db);
    final rows = await db.query(
      'voice_aliases',
      where: 'spoken = ?',
      whereArgs: [NameNormalizer.normalize(spoken)],
    );
    return rows.isEmpty ? null : rows.first['corrected'] as String;
  }

  Future<void> rememberVoiceCorrection(String spoken, String corrected) async {
    if (spoken.trim().isEmpty || corrected.trim().isEmpty) return;
    final db = await database;
    await _ensureVoiceAliases(db);
    await db.insert('voice_aliases', {
      'spoken': NameNormalizer.normalize(spoken),
      'corrected': corrected.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<String>> getSectors() async {
    final db = await database;
    final res = await db.rawQuery(
      "SELECT DISTINCT sector FROM consumers WHERE sector != '' AND sector IS NOT NULL ORDER BY sector ASC",
    );
    return res.map((r) => r['sector'] as String).toList();
  }

  Future<List<String>> getLocalities({String? sector}) async {
    final db = await database;
    if (sector != null && sector.trim().isNotEmpty && sector != 'All Sectors') {
      final res = await db.rawQuery(
        "SELECT DISTINCT locality FROM consumers WHERE sector = ? AND locality != '' AND locality IS NOT NULL ORDER BY locality ASC",
        [sector.trim()],
      );
      return res.map((r) => r['locality'] as String).toList();
    }
    final res = await db.rawQuery(
      "SELECT DISTINCT locality FROM consumers WHERE locality != '' AND locality IS NOT NULL ORDER BY locality ASC",
    );
    return res.map((r) => r['locality'] as String).toList();
  }

  Future<List<String>> getConnectionStatuses() async {
    final db = await database;
    final res = await db.rawQuery(
      "SELECT DISTINCT connection_status FROM consumers WHERE connection_status != '' AND connection_status IS NOT NULL ORDER BY connection_status ASC",
    );
    return res.map((r) => r['connection_status'] as String).toList();
  }

  Future<List<String>> getRateTypes() async {
    final db = await database;
    final res = await db.rawQuery(
      "SELECT DISTINCT rate_type FROM consumers WHERE rate_type != '' AND rate_type IS NOT NULL ORDER BY rate_type ASC",
    );
    return res.map((r) => r['rate_type'] as String).toList();
  }

  /// Database Statistics & Comprehensive Breakdown
  Future<Map<String, dynamic>> getStats() async {
    final db = await database;
    final totalRes = await db.rawQuery(
      'SELECT COUNT(*) as count FROM consumers',
    );
    final totalCount = Sqflite.firstIntValue(totalRes) ?? 0;

    final activeRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE LOWER(consumer_status) = 'active'",
    );
    final activeCount = Sqflite.firstIntValue(activeRes) ?? 0;
    final inactiveCount = Sqflite.firstIntValue(await db.rawQuery("SELECT COUNT(*) FROM consumers WHERE LOWER(REPLACE(TRIM(consumer_status), '-', '')) = 'inactive'")) ?? 0;
    final unknownConsumerStatus = totalCount - activeCount - inactiveCount;

    final sectorsRes = await db.rawQuery(
      'SELECT COUNT(DISTINCT sector) as count FROM consumers',
    );
    final sectorsCount = Sqflite.firstIntValue(sectorsRes) ?? 0;

    final localitiesRes = await db.rawQuery(
      'SELECT COUNT(DISTINCT locality) as count FROM consumers',
    );
    final localitiesCount = Sqflite.firstIntValue(localitiesRes) ?? 0;

    // Status breakdown
    final regularRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE LOWER(connection_status) LIKE '%regular%'",
    );
    final regularCount = Sqflite.firstIntValue(regularRes) ?? 0;

    final closedRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE LOWER(connection_status) LIKE '%closed%' OR LOWER(connection_status) LIKE '%dead%'",
    );
    final closedCount = Sqflite.firstIntValue(closedRes) ?? 0;

    final suspendedRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE LOWER(connection_status) LIKE '%suspend%'",
    );
    final suspendedCount = Sqflite.firstIntValue(suspendedRes) ?? 0;

    final newDemandRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE LOWER(connection_status) LIKE '%demand%'",
    );
    final newDemandCount = Sqflite.firstIntValue(newDemandRes) ?? 0;

    // Rate Type breakdown
    final commercialRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE UPPER(rate_type) LIKE '%COMMERCIAL%' OR UPPER(rate_type) LIKE '%COMERCIAL%'",
    );
    final commercialCount = Sqflite.firstIntValue(commercialRes) ?? 0;

    final privateRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE UPPER(rate_type) LIKE '%PRIVATE%'",
    );
    final privateCount = Sqflite.firstIntValue(privateRes) ?? 0;

    final domesticRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE UPPER(rate_type) LIKE '%DOMESTIC%' OR rate_type LIKE '%6 month jan26 to june26%'",
    );
    final domesticCount = Sqflite.firstIntValue(domesticRes) ?? 0;

    // Rate Type Regular Connections Breakdown
    final domesticRegularRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE (UPPER(rate_type) LIKE '%DOMESTIC%' OR rate_type LIKE '%6 month jan26 to june26%') AND LOWER(connection_status) LIKE '%regular%'",
    );
    final domesticRegularCount = Sqflite.firstIntValue(domesticRegularRes) ?? 0;

    final commercialRegularRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE (UPPER(rate_type) LIKE '%COMMERCIAL%' OR UPPER(rate_type) LIKE '%COMERCIAL%') AND LOWER(connection_status) LIKE '%regular%'",
    );
    final commercialRegularCount =
        Sqflite.firstIntValue(commercialRegularRes) ?? 0;

    final privateRegularRes = await db.rawQuery(
      "SELECT COUNT(*) as count FROM consumers WHERE UPPER(rate_type) LIKE '%PRIVATE%' AND LOWER(connection_status) LIKE '%regular%'",
    );
    final privateRegularCount = Sqflite.firstIntValue(privateRegularRes) ?? 0;

    final dbPath = db.path;
    int fileSizeBytes = 0;
    try {
      final file = File(dbPath);
      if (await file.exists()) {
        fileSizeBytes = await file.length();
      }
    } catch (_) {}

    final billHistoryCount = await getBillHistoryCount();

    // Every KPI uses the same set of distinct bills from the latest upload.
    await _ensureBillHistoryTable(db);
    final sources = await db.query('bill_report_sources');
    final rows = await db.rawQuery("""
      SELECT bh.* FROM bill_history bh
      JOIN bill_report_members m ON m.connection_no = UPPER(TRIM(bh.connection_no)) AND m.bill_no = UPPER(TRIM(bh.bill_no))
    """);
    final consumerTypes = await db.query('consumers', columns: ['connection_no', 'rate_type']);
    final categories = <String, Set<String>>{};
    for (final row in consumerTypes) {
      final connection = (row['connection_no'] as String? ?? '').trim().toUpperCase();
      final category = billingCategory(row['rate_type'] as String? ?? '');
      if (category != 'unknown') categories.putIfAbsent(connection, () => {}).add(category);
    }
    int cents(dynamic value) => ((double.tryParse((value ?? '0').toString().replaceAll(',', '').replaceAll(' ', '')) ?? 0) * 100).round();
    final billing = <String, dynamic>{};
    for (final prefix in ['', 'domestic', 'commercial', 'private', 'unknown']) {
      for (final metric in ['Count', 'Paid', 'PendingCount', 'Expired', 'Demand', 'Received', 'PaidAmount', 'UnpaidAmount', 'Arrears', 'Pending']) {
        billing['$prefix$metric'] = 0;
      }
    }
    final billedConnections = <String, Set<String>>{};
    for (final row in rows) {
      final matched = categories[(row['connection_no'] as String).trim().toUpperCase()];
      // Confirmed category rules survive imports and database resets.
      final category = billingCategoryOverrides[(row['connection_no'] as String).trim().toUpperCase()] ??
          (matched != null && matched.length == 1 ? matched.single : 'unknown');
      final status = (row['status'] as String? ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      final paid = status == 'paid';
      final demand = cents(row['total_bill']);
      final received = cents(row['amount_received']);
      for (final prefix in ['', category]) {
        billedConnections.putIfAbsent(prefix, () => {}).add((row['connection_no'] as String).trim().toUpperCase());
        void add(String field, int value) { billing['$prefix$field'] = (billing['$prefix$field'] as int) + value; }
        add('Count', 1);
        add('Demand', demand);
        add('Received', received);
        add('Arrears', cents(row['arrears']));
        add(paid ? 'Paid' : 'PendingCount', 1);
        add(paid ? 'PaidAmount' : 'UnpaidAmount', demand);
        if (status == 'expired') add('Expired', 1);
        // A paid bill is settled; late fees on it cannot offset another bill's debt.
        if (!paid) add('Pending', (demand - received).clamp(0, demand < 0 ? 0 : demand));
      }
    }
    for (final prefix in ['', 'domestic', 'commercial', 'private', 'unknown']) {
      for (final metric in ['Demand', 'Received', 'PaidAmount', 'UnpaidAmount', 'Arrears', 'Pending']) {
        billing['$prefix$metric'] = (billing['$prefix$metric'] as int) / 100;
      }
    }
    for (final prefix in ['', 'domestic', 'commercial', 'private', 'unknown']) {
      billing['${prefix}ConnectionCount'] = billedConnections[prefix]?.length ?? 0;
    }
    final totalBilledAmount = billing['Demand'] as double;
    final totalReceivedAmount = billing['Received'] as double;
    final recoveryRate = totalBilledAmount > 0 ? totalReceivedAmount / totalBilledAmount * 100 : 0.0;

    return {
      'total': totalCount,
      'active': activeCount,
      'inactive': inactiveCount,
      'unknownConsumerStatus': unknownConsumerStatus,
      'sectors': sectorsCount,
      'localities': localitiesCount,
      'regular': regularCount,
      'closed': closedCount,
      'suspended': suspendedCount,
      'newDemand': newDemandCount,
      'commercial': commercialCount,
      'privateSocieties': privateCount,
      'domestic': domesticCount,
      'domesticRegular': domesticRegularCount,
      'commercialRegular': commercialRegularCount,
      'privateSocietiesRegular': privateRegularCount,
      'billHistoryCount': billHistoryCount,
      'fileSizeBytes': fileSizeBytes,
      'dbPath': dbPath,
      ...billing,
      'billingSource': sources.isEmpty ? 'No bills file selected. Import a bills CSV to show its totals' : sources.map((r) => r['name']).join(', '),
      'billingImportedAt': sources.isEmpty ? null : sources.map((r) => r['imported_at'] as String).reduce((a, b) => a.compareTo(b) > 0 ? a : b),
      'totalBillsCount': billing['Count'],
      'paidBillsCount': billing['Paid'],
      'pendingBillsCount': billing['PendingCount'],
      'expiredBillsCount': billing['Expired'],
      'totalBilledAmount': totalBilledAmount,
      'totalReceivedAmount': totalReceivedAmount,
      'totalPendingAmount': billing['Pending'],
      'recoveryRate': recoveryRate,
      'domesticDemand': billing['domesticDemand'],
      'domesticReceived': billing['domesticReceived'],
      'domesticPaid': billing['domesticPaid'],
      'commercialDemand': billing['commercialDemand'],
      'commercialReceived': billing['commercialReceived'],
      'commercialPaid': billing['commercialPaid'],
      'privateDemand': billing['privateDemand'],
      'privateReceived': billing['privateReceived'],
      'privatePaid': billing['privatePaid'],
    };
  }

  /// Specialized Voice Search Query (matching consumer_name and father_husband_name)
  Future<List<Consumer>> searchByVoiceQuery({
    required String query,
    String? sector,
    int limit = 50,
  }) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final db = await database;
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    // Match consumer_name OR father_husband_name
    whereClauses.add('(consumer_name LIKE ? OR father_husband_name LIKE ?)');
    whereArgs.add('%$clean%');
    whereArgs.add('%$clean%');

    if (sector != null && sector.trim().isNotEmpty && sector != 'All Sectors') {
      whereClauses.add('sector = ?');
      whereArgs.add(sector.trim());
    }

    final whereString = whereClauses.join(' AND ');
    final sanitized = clean.replaceAll("'", "''");

    try {
      final results = await db.query(
        'consumers',
        where: whereString,
        whereArgs: whereArgs,
        orderBy:
            '''
          CASE
            WHEN consumer_name = '$sanitized' THEN 1
            WHEN consumer_name LIKE '$sanitized%' THEN 2
            WHEN consumer_name LIKE '%$sanitized%' THEN 3
            ELSE 4
          END, sr_no ASC
        ''',
        limit: limit,
      );

      return results.map((m) => Consumer.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error in searchByVoiceQuery: $e');
      return [];
    }
  }

  /// Get dynamic autocomplete suggestions (Consumer names, Connection numbers, Localities)
  Future<List<String>> getSuggestions(String query, {int limit = 8}) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final db = await database;
    final sanitized = clean.replaceAll("'", "''");

    try {
      if (RegExp(r'^[0-9]+$').hasMatch(clean)) {
        // Numeric search: suggest matching connection numbers
        final results = await db.rawQuery(
          '''
          SELECT DISTINCT connection_no AS val
          FROM consumers
          WHERE connection_no LIKE '$sanitized%'
          ORDER BY connection_no ASC
          LIMIT ?
        ''',
          [limit],
        );

        return results
            .map((row) => (row['val'] as String?)?.trim() ?? '')
            .where((val) => val.isNotEmpty)
            .toList();
      }

      final results = await db.rawQuery(
        '''
        SELECT DISTINCT consumer_name
        FROM consumers
        WHERE consumer_name LIKE '$sanitized%' 
           OR consumer_name LIKE '% $sanitized%' 
           OR consumer_name LIKE '%$sanitized%'
        ORDER BY
          CASE
            WHEN consumer_name LIKE '$sanitized%' THEN 0
            WHEN consumer_name LIKE '% $sanitized%' THEN 1
            ELSE 2
          END, consumer_name ASC
        LIMIT ?
      ''',
        [limit],
      );

      return results
          .map((row) => (row['consumer_name'] as String?)?.trim() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error getting suggestions: $e');
      return [];
    }
  }

  /// Create a complete, standalone SQLite backup of the current database.
  Future<Uint8List> createDatabaseBackup() async {
    final db = await database;
    final folder = await Directory.systemTemp.createTemp('consumer-backup-');
    try {
      final backup = File(p.join(folder.path, 'backup.db'));
      // Includes committed WAL data in a consistent, standalone SQLite file.
      await db.execute('VACUUM main INTO ?', [backup.path]);
      return await backup.readAsBytes();
    } finally {
      await folder.delete(recursive: true);
    }
  }

  /// Replace app records atomically; validation or copy errors roll everything back.
  Future<int> restoreDatabaseBackup(String path) async {
    final db = await database;
    final source = File(path);
    if (!await source.exists()) {
      throw const FormatException('The selected backup file does not exist.');
    }
    if (db.path != inMemoryDatabasePath &&
        await FileSystemEntity.identical(source.path, db.path)) {
      throw const FormatException(
        'Select an exported backup, not the active database.',
      );
    }
    final handle = await source.open();
    try {
      final header = await handle.read(16);
      if (String.fromCharCodes(header) != 'SQLite format 3\u0000') {
        throw const FormatException(
          'This file is not a SQLite database backup.',
        );
      }
    } finally {
      await handle.close();
    }

    await _ensureBillHistoryTable(db);
    await _ensureVoiceAliases(db);
    const tables = [
      'consumers',
      'bill_history',
      'voice_aliases',
      'bill_report_sources',
      'bill_report_members',
      'bill_import_state',
      'data_import_runs',
      'bill_history_quarantine',
    ];
    // Read only from the backup; every write below targets the main database.
    await db.execute('ATTACH DATABASE ? AS import_backup', [
      await source.resolveSymbolicLinks(),
    ]);
    try {
      return await db.transaction((txn) async {
        final version =
            Sqflite.firstIntValue(
              await txn.rawQuery('PRAGMA import_backup.user_version'),
            ) ??
            0;
        if (version > 3) {
          throw const FormatException(
            'This backup requires a newer version of the app.',
          );
        }
        final integrity = await txn.rawQuery(
          'PRAGMA import_backup.integrity_check',
        );
        if (integrity.length != 1 || integrity.single.values.single != 'ok') {
          throw const FormatException(
            'The backup is damaged. Existing data was not replaced.',
          );
        }
        final schema = await txn.rawQuery(
          "SELECT name, sql FROM import_backup.sqlite_master WHERE type = 'table'",
        );
        final sourceTables = {
          for (final row in schema) row['name']: row['sql'],
        };
        if (!sourceTables.containsKey('consumers') ||
            !sourceTables.containsKey('bill_history')) {
          throw const FormatException(
            'Select a SQLite backup exported by Consumer Search Engine.',
          );
        }
        final columns = <String, List<String>>{};
        final counts = <String, int>{};
        for (final table in tables.where(sourceTables.containsKey)) {
          if (!RegExp(
            r'^CREATE\s+TABLE\b',
            caseSensitive: false,
          ).hasMatch('${sourceTables[table]}'.trim())) {
            throw FormatException('Unsupported backup table: $table.');
          }
          final target = (await txn.rawQuery(
            'PRAGMA main.table_info("$table")',
          )).map((r) => r['name'] as String).toList();
          final incoming = (await txn.rawQuery(
            'PRAGMA import_backup.table_info("$table")',
          )).map((r) => r['name'] as String).toSet();
          if (target.isEmpty ||
              incoming.length != target.length ||
              !incoming.containsAll(target)) {
            throw FormatException(
              'The backup has an incompatible $table structure. Existing data was not replaced.',
            );
          }
          columns[table] = target;
          counts[table] = Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COUNT(*) FROM import_backup."$table"'),
          )!;
        }
        for (final table in tables.reversed) {
          await txn.delete(table);
        }
        await txn.delete('sqlite_sequence', where: 'name IN (?, ?)', whereArgs: ['consumers', 'bill_history']);
        for (final table in tables.where(columns.containsKey)) {
          final names = columns[table]!
              .map((c) => '"${c.replaceAll('"', '""')}"')
              .join(', ');
          await txn.execute(
            'INSERT INTO main."$table" ($names) SELECT $names FROM import_backup."$table"',
          );
          final copied = Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COUNT(*) FROM main."$table"'),
          );
          if (copied != counts[table]) {
            throw FormatException(
              'The backup contains conflicting $table records. Existing data was not replaced.',
            );
          }
        }
        if (sourceTables.containsKey('sqlite_sequence')) {
          await txn.delete(
            'sqlite_sequence',
            where: 'name IN (?, ?)',
            whereArgs: ['consumers', 'bill_history'],
          );
          await txn.execute(
            "INSERT INTO main.sqlite_sequence(name, seq) SELECT name, seq FROM import_backup.sqlite_sequence WHERE name IN ('consumers', 'bill_history')",
          );
        }
        final fts = await txn.rawQuery(
          "SELECT 1 FROM main.sqlite_master WHERE name = 'consumers_fts'",
        );
        if (fts.isNotEmpty) {
          await txn.execute(
            "INSERT INTO consumers_fts(consumers_fts) VALUES('rebuild')",
          );
        }
        return counts['consumers']!;
      });
    } finally {
      await db.execute('DETACH DATABASE import_backup');
    }
  }

  /// Clear / Wipe all data
  Future<void> clearDatabase() async {
    final db = await database;
    await db.transaction((txn) async {
      final tables = (await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
          .map((row) => row['name']).toSet();
      for (final table in ['bill_history_quarantine', 'data_import_runs', 'bill_import_state', 'bill_report_members', 'bill_report_sources', 'bill_history', 'voice_aliases', 'consumers']) {
        if (tables.contains(table)) await txn.delete(table);
      }
      // External-content FTS requires its own reset after the content rows are removed.
      if (tables.contains('consumers_fts')) {
        await txn.execute("INSERT INTO consumers_fts(consumers_fts) VALUES('delete-all')");
      }
      if (tables.contains('sqlite_sequence')) {
        await txn.delete('sqlite_sequence', where: 'name IN (?, ?)', whereArgs: ['consumers', 'bill_history']);
      }
    });
  }
}
