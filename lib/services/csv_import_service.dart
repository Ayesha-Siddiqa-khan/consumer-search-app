import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import '../models/consumer_model.dart';
import 'database_service.dart';

List<List<dynamic>> _decodeCsvIsolate(String csvContent) {
  String cleaned = csvContent;
  if (cleaned.startsWith('\ufeff')) {
    cleaned = cleaned.substring(1);
  }
  return csv.decode(cleaned);
}

class CsvImportService {
  static final CsvImportService instance = CsvImportService._internal();
  CsvImportService._internal() : _database = DatabaseService.instance;
  CsvImportService.forTesting(this._database);
  final DatabaseService _database;
  bool _importing = false;

  Future<T> _runImport<T>(Future<T> Function() task) async {
    if (_importing) {
      throw StateError(
        'An import is already running. Please wait for it to finish.',
      );
    }
    _importing = true;
    try {
      return await task();
    } finally {
      _importing = false;
    }
  }

  /// Import from bundled asset `assets/data/consumers.csv` (full replace)
  Future<int> importFromAsset({
    String assetPath = 'assets/data/consumers.csv',
    void Function(String status, double progress)? onProgress,
  }) => _runImport(() async {
    onProgress?.call('Loading dataset asset...', 0.05);
    final rawString = await rootBundle.loadString(assetPath);
    return await _parseAndInsertCsvString(rawString, onProgress: onProgress);
  });

  /// Import consumer CSV from a local file path (upsert mode)
  Future<ImportResult> importConsumerFile(
    String filePath, {
    void Function(String status, double progress)? onProgress,
  }) => _runImport(() async {
    onProgress?.call('Reading consumer CSV file...', 0.05);
    final file = File(filePath);
    final rawString = await file.readAsString(encoding: utf8);
    return await _parseAndUpsertConsumerCsv(rawString, onProgress: onProgress);
  });

  /// Import bills CSV from a local file path
  Future<ImportResult> importBillsFile(
    String filePath, {
    void Function(String status, double progress)? onProgress,
  }) => _runImport(() async {
    onProgress?.call('Reading bills CSV file...', 0.05);
    final file = File(filePath);
    final rawString = await file.readAsString(encoding: utf8);
    return await _parseAndApplyBillsCsv(rawString, onProgress: onProgress);
  });

  /// Legacy import from file (full replace — kept for bundled re-import)
  Future<int> importFromFile(
    String filePath, {
    void Function(String status, double progress)? onProgress,
  }) => _runImport(() async {
    onProgress?.call('Reading CSV file...', 0.05);
    final file = File(filePath);
    final rawString = await file.readAsString(encoding: utf8);
    return await _parseAndInsertCsvString(rawString, onProgress: onProgress);
  });

  /// Full replace import (used by bundled asset re-import)
  Future<int> _parseAndInsertCsvString(
    String csvContent, {
    void Function(String status, double progress)? onProgress,
  }) async {
    onProgress?.call('Parsing CSV rows...', 0.15);

    final rows = await compute(_decodeCsvIsolate, csvContent);

    if (rows.isEmpty) return 0;

    final headerRow = rows[0]
        .map((e) => e.toString().trim().replaceAll('\ufeff', ''))
        .toList();
    final consumers = _parseConsumerRows(
      headerRow,
      rows,
      onProgress: onProgress,
    );

    onProgress?.call('Saving 0 of ${consumers.length} to database...', 0.40);
    await _database.insertBatch(
      consumers,
      onProgress: (inserted, total) {
        final pct = 0.40 + (inserted / total) * 0.60;
        onProgress?.call('Saving $inserted of $total records...', pct);
      },
    );

    onProgress?.call('Completed! ${consumers.length} records imported.', 1.0);
    return consumers.length;
  }

  /// Upsert consumer CSV: update existing by connection_no, insert new
  Future<ImportResult> _parseAndUpsertConsumerCsv(
    String csvContent, {
    void Function(String status, double progress)? onProgress,
  }) async {
    onProgress?.call('Parsing consumer CSV rows...', 0.15);

    // Decode CSV in an isolate to avoid blocking UI
    final rows = await compute(_decodeCsvIsolate, csvContent);

    if (rows.length < 2) {
      throw const FormatException('The CSV has no data rows.');
    }

    final headerRow = rows[0]
        .map((e) => e.toString().trim().replaceAll('\ufeff', ''))
        .toList();
    final consumers = _parseConsumerRows(
      headerRow,
      rows,
      onProgress: onProgress,
    );

    onProgress?.call('Upserting 0 of ${consumers.length} records...', 0.40);
    final result = await _database.upsertBatch(
      consumers,
      onProgress: (processed, total) {
        final pct = 0.40 + (processed / total) * 0.60;
        onProgress?.call('Upserting $processed of $total records...', pct);
      },
    );

    final summary =
        'Import successful: ${result['updated']} updated, ${result['inserted']} new records added.';
    onProgress?.call(summary, 1.0);
    return ImportResult(
      inserted: result['inserted']!,
      updated: result['updated']!,
    );
  }

  /// Parse bills CSV and update matching consumer records
  Future<ImportResult> _parseAndApplyBillsCsv(
    String csvContent, {
    void Function(String status, double progress)? onProgress,
  }) async {
    onProgress?.call('Parsing bills CSV rows...', 0.15);

    // Decode CSV in an isolate to avoid blocking UI
    final rows = await compute(_decodeCsvIsolate, csvContent);

    if (rows.length < 2) {
      throw const FormatException('The CSV has no data rows.');
    }

    final headerRow = rows[0]
        .map((e) => e.toString().trim().replaceAll('\ufeff', ''))
        .toList();

    String headerKey(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    int getCol(List<String> names) {
      final keys = names.map(headerKey).toSet();
      final matches = <int>[];
      for (var i = 0; i < headerRow.length; i++) {
        if (keys.contains(headerKey(headerRow[i]))) matches.add(i);
      }
      if (matches.length > 1) {
        throw FormatException('Duplicate CSV column: ${names.first}.');
      }
      return matches.isEmpty ? -1 : matches.single;
    }

    final colConnNo = getCol(['Connection No', 'Connection Number', 'Conn No']);
    if (colConnNo < 0) {
      throw const FormatException(
        'Missing required column: Connection No. Choose a bills CSV with connection numbers.',
      );
    }
    final columns = {
      'total_bill': getCol(['Total Bill']),
      'fine': getCol(['Fine']),
      'after_due_date': getCol(['After Due Date']),
      'due_date': getCol(['Due Date']),
      'bill_status': getCol(['Status', 'Bill Status']),
      'amount_received': getCol(['Amount Received']),
    }..removeWhere((_, index) => index < 0);
    if (columns.isEmpty) {
      throw const FormatException(
        'No bill columns found. Expected Total Bill, Due Date, Status, or Amount Received.',
      );
    }

    onProgress?.call('Matching bill records to consumers...', 0.30);
    final billsByConnNo = <String, Map<String, String>>{};
    final conflicting = <String>{};
    var skipped = 0;
    var duplicates = 0;
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.every((v) => v.toString().trim().isEmpty)) continue;
      if (row.length != headerRow.length) {
        throw FormatException(
          'CSV row ${i + 1} has ${row.length} fields; expected ${headerRow.length}. Check commas and quoted values.',
        );
      }
      final rawConnNo = row[colConnNo]?.toString().trim() ?? '';
      final connNo = rawConnNo.toUpperCase();
      final isDivider = connNo.isEmpty ||
          connNo.startsWith('---') ||
          connNo.startsWith('===') ||
          connNo.contains('END OF') ||
          (connNo.isNotEmpty && connNo.replaceAll(RegExp(r'[\s\-_=]'), '').isEmpty);
      if (isDivider) {
        skipped++;
        continue;
      }
      final bill = {
        for (final entry in columns.entries)
          entry.key: row[entry.value].toString().trim(),
      };
      final previous = billsByConnNo[connNo];
      if (previous != null) {
        duplicates++;
        if (bill.entries.any((e) => previous[e.key] != e.value)) {
          conflicting.add(connNo);
        }
      } else {
        billsByConnNo[connNo] = bill;
      }
    }
    if (billsByConnNo.isEmpty) {
      throw const FormatException(
        'No usable connection numbers were found in the CSV.',
      );
    }
    // Conflicting bills are never silently selected by their row order.
    for (final conn in conflicting) {
      billsByConnNo.remove(conn);
    }
    final result = await _database.updateBillsForConnections(
      billsByConnNo,
      onProgress: (processed, total) => onProgress?.call(
        'Updating $processed of $total connections...',
        0.40 + (total == 0 ? 0 : processed / total) * 0.60,
      ),
    );
    final imported = ImportResult(
      inserted: 0,
      updated: result.updated,
      unmatched: result.unmatched,
      ambiguous: [...conflicting, ...result.ambiguous],
      skipped: skipped,
      duplicateRows: duplicates,
    );
    onProgress?.call(imported.summary, 1.0);
    return imported;
  }

  List<Consumer> _parseConsumerRows(
    List<String> headerRow,
    List<List<dynamic>> rows, {
    void Function(String status, double progress)? onProgress,
  }) {
    int getCol(List<String> possibleNames) {
      String key(String text) => text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final aliases = possibleNames.map(key).toSet();
      final matches = <int>[for (var i = 0; i < headerRow.length; i++) if (aliases.contains(key(headerRow[i]))) i];
      if (matches.length > 1) throw FormatException('Ambiguous duplicate column: ${possibleNames.first}');
      return matches.isEmpty ? -1 : matches.single;
    }

    final colSrNo = getCol(['Sr #', 'Sr#', 'Sr No', 'Serial', 'Sr.']);
    final colName = getCol(['Consumer Name', 'Name', 'Consumer']);
    final colFhName = getCol([
      'F/H Name',
      'FH Name',
      'Father Name',
      'Husband Name',
    ]);
    final colMobile = getCol(['Mobile', 'Phone', 'Cell', 'Mobile No']);
    final colSector = getCol(['Sector']);
    final colLocality = getCol(['Locality']);
    final colAddress = getCol(['Address']);
    final colOrderNo = getCol([
      'Order No. / Register No',
      'Order No',
      'Register No',
      'Reference No',
    ]);
    final colRateType = getCol(['Rate Type', 'RateType']);
    if (colRateType < 0 || colName < 0) {
      throw const FormatException('Choose a consumer master CSV with Consumer Name and Rate Type. Import bills using Import Bills File(s).');
    }
    final colConnNo = getCol(['Connection No.', 'Connection No', 'Conn No', 'Connection Number']);
    final colOldConnNo = getCol([
      'Old Connection No.',
      'Old Connection No',
      'Old Conn No',
      'Old Connection Number',
    ]);
    final colConnDate = getCol(['Connection Date', 'Conn Date', 'Date']);
    final colConnStatus = getCol(['Status', 'Connection Status']);
    final colConsumerStatus = getCol(['Consumer Status', 'Cons Status']);
    if (colConnNo < 0) {
      throw const FormatException('Missing Connection No or Connection Number column.');
    }

    String getVal(List<dynamic> row, int idx) {
      if (idx == -1 || idx >= row.length) return '';
      return row[idx]?.toString().trim() ?? '';
    }

    onProgress?.call('Constructing records...', 0.30);
    final consumers = <Consumer>[];

    for (int i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty || (row.length == 1 && row[0].toString().trim().isEmpty)) {
        continue;
      }

      final connNo = getVal(row, colConnNo);
      if (row.every((v) => v.toString().trim().isEmpty)) continue;
      final isDivider =
          connNo.startsWith('---') ||
          connNo.startsWith('===') ||
          connNo.toLowerCase().contains('end of') ||
          (connNo.isNotEmpty && connNo.replaceAll(RegExp(r'[\s\-_=]'), '').isEmpty);
      if (isDivider) {
        continue;
      }

      if (row.length != headerRow.length || connNo.isEmpty) {
        throw FormatException('Invalid consumer identity or column count at CSV row ${i + 1}.');
      }
      final srVal = getVal(row, colSrNo);
      final srNo = int.tryParse(srVal) ?? i;
      final rawDate = getVal(row, colConnDate);
      final formattedDate = Consumer.formatPakistaniDate(rawDate);

      consumers.add(
        Consumer(
          srNo: srNo,
          consumerName: getVal(row, colName),
          fatherHusbandName: getVal(row, colFhName),
          mobile: getVal(row, colMobile),
          sector: getVal(row, colSector),
          locality: getVal(row, colLocality),
          address: getVal(row, colAddress),
          orderNo: getVal(row, colOrderNo),
          rateType: getVal(row, colRateType),
          connectionNo: getVal(row, colConnNo),
          oldConnectionNo: getVal(row, colOldConnNo),
          connectionDate: formattedDate,
          connectionStatus: switch (getVal(row, colConnStatus).toLowerCase()) {
            'open' => 'Regular Connection',
            'new' => 'New Demand',
            _ => getVal(row, colConnStatus),
          },
          consumerStatus: getVal(row, colConsumerStatus),
        ),
      );
    }

    return consumers;
  }
}

class ImportResult {
  final int inserted;
  final int updated;
  final List<String> unmatched;
  final List<String> ambiguous;
  final int skipped;
  final int duplicateRows;
  const ImportResult({
    required this.inserted,
    required this.updated,
    this.unmatched = const [],
    this.ambiguous = const [],
    this.skipped = 0,
    this.duplicateRows = 0,
  });

  String get summary {
    final messages = <String>['$updated consumer records updated.'];
    if (unmatched.isNotEmpty) {
      messages.add(
        '${unmatched.length} connections not found: ${unmatched.take(10).join(', ')}${unmatched.length > 10 ? '...' : ''}.',
      );
    }
    if (ambiguous.isNotEmpty) {
      messages.add(
        '${ambiguous.length} connections skipped because of conflicting bills or duplicate consumer records: ${ambiguous.take(10).join(', ')}${ambiguous.length > 10 ? '...' : ''}.',
      );
    }
    if (skipped > 0) {
      messages.add('$skipped rows skipped: missing connection number.');
    }
    if (duplicateRows > 0) {
      messages.add('$duplicateRows repeated connection rows found.');
    }
    return messages.join(' ');
  }

  int get total => inserted + updated;
}
