import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import '../models/bill_history_model.dart';
import '../models/bill_import_model.dart';
import 'database_service.dart';

class BillImportSummary {
  final int totalFiles;
  final int totalBills;
  final int totalConsumersUpdated;
  final List<String> fileNames;
  final List<String> errors;
  final int inserted;
  final int updated;
  final int unchanged;
  final int held;
  final int duplicateRows;
  final int superseded;
  final List<Map<String, String>> issues;

  const BillImportSummary({
    required this.totalFiles,
    required this.totalBills,
    required this.totalConsumersUpdated,
    required this.fileNames,
    this.errors = const [],
    this.inserted = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.held = 0,
    this.duplicateRows = 0,
    this.superseded = 0,
    this.issues = const [],
  });

  String get description =>
      '$inserted new, $updated updated, $unchanged unchanged, $held held for review. '
      '$duplicateRows repeated source rows collapsed. $superseded superseded bills archived. ${issues.length} review notes.';
  String get reviewCsv => csv.encode([
    ['Connection No', 'Bill No', 'Reason', 'Source'],
    for (final row in issues)
      [row['connection_no'], row['bill_no'], row['reason'], row['source']],
  ]);

  bool get hasErrors => errors.isNotEmpty;
}

class BillImportService {
  static final BillImportService instance = BillImportService._internal();
  BillImportService._internal() : _database = DatabaseService.instance;
  BillImportService.forTesting(this._database);
  final DatabaseService _database;

  bool _importing = false;

  /// File names are optional date hints, never a requirement or record identity.
  static String snapshotDate(String name, DateTime fallback) {
    final match = RegExp(r'(20\d{2})-(\d{2})-(\d{2})').firstMatch(name);
    if (match != null &&
        validImportDate('${match[3]}/${match[2]}/${match[1]}') != null) {
      return match[0]!;
    }
    return fallback.toIso8601String().substring(0, 10);
  }

  Future<BillImportSummary> importBillHistoryFiles(
    List<File> files, {
    void Function(String status, double progress)? onProgress,
    bool isHistory = false,
    DateTime? asOf,
    bool repairSourceConflicts = false,
  }) async {
    if (_importing) throw StateError('A bill import is already running.');
    _importing = true;
    var currentSource = '';
    try {
      if (files.isEmpty) throw const FormatException('No files selected.');
      final selected = <String, ImportedBill>{};
      final conflicting = <String>{};
      final report = BillMergeReport();
      final superseded = <ImportedBill>[];
      var rowsRead = 0;
      final sourceNames = <String>[];
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final source = file.uri.pathSegments.last;
        currentSource = source;
        if (!await file.exists()) {
          throw FormatException('File not found: $source');
        }
        onProgress?.call(
          'Validating ${index + 1}/${files.length}: $source',
          index / files.length * .55,
        );
        final raw = await file.readAsString(encoding: utf8);
        final rows = await compute(_decodeBillsCsv, raw);
        if (rows.length < 2) throw FormatException('No bill rows in $source');
        final headers = rows.first.map((v) => v.toString().trim()).toList();
        final fields = <String>{};
        final bills = _parseBillRows(headers, rows, fields: fields);
        if (isHistory && !fields.contains('billing_period')) {
          throw FormatException(
            '$source is not a history CSV (Billing Period missing).',
          );
        }
        // Explicit dates take precedence for daily uploads. History can contain mixed snapshots.
        final date = isHistory
            ? snapshotDate(source, asOf ?? DateTime.now())
            : (asOf ?? DateTime.now()).toIso8601String().substring(0, 10);
        sourceNames.add(source);
        for (final bill in bills) {
          rowsRead++;
          final candidate = ImportedBill(bill, fields, date, source);
          final old = selected[candidate.key];
          if (old == null || date.compareTo(old.asOf) > 0) {
            selected[candidate.key] = candidate;
            conflicting.remove(candidate.key);
          } else if (date == old.asOf && !candidate.agreesWith(old)) {
            conflicting.add(candidate.key);
          }
        }
      }
      for (final key in conflicting) {
        report.held++;
        report.issue(
          key,
          'Conflicting rows for the same snapshot date; bill held',
          selected[key]!.source,
        );
        selected.remove(key);
      }
      if (isHistory) {
        final latestByPeriod = <String, String>{};
        for (final item in selected.values) {
          final period = historyPeriodIdentity(item.bill);
          if (period != null &&
              item.asOf.compareTo(latestByPeriod[period] ?? '') > 0) {
            latestByPeriod[period] = item.asOf;
          }
        }
        for (final item in selected.values.toList()) {
          final period = historyPeriodIdentity(item.bill);
          if (period != null &&
              item.asOf.compareTo(latestByPeriod[period]!) < 0) {
            superseded.add(item);
            selected.remove(item.key);
            report.issue(
              item.key,
              'Superseded by newer history for the same connection, bill type and period; archived',
              item.source,
            );
          }
        }
      }
      report.superseded = superseded.length;
      report.duplicateRows =
          rowsRead - selected.length - conflicting.length - superseded.length;
      onProgress?.call(
        'Validated all files. Saving unique bills atomically...',
        .6,
      );
      final saved = await _database.mergeImportedBills(
        selected.values.toList(),
        isHistory: isHistory,
        sources: sourceNames,
        report: report,
        superseded: superseded,
        repairSourceConflicts: repairSourceConflicts,
        onProgress: (done, total) => onProgress?.call(
          'Saving $done/$total unique bills...',
          .6 + .4 * (total == 0 ? 1 : done / total),
        ),
      );
      return BillImportSummary(
        totalFiles: files.length,
        totalBills: selected.length,
        totalConsumersUpdated: saved.consumersUpdated,
        fileNames: sourceNames,
        inserted: saved.inserted,
        updated: saved.updated,
        unchanged: saved.unchanged,
        held: saved.held,
        superseded: saved.superseded,
        issues: saved.issues,
        duplicateRows:
            rowsRead - selected.length - conflicting.length - superseded.length,
      );
    } catch (error, stack) {
      debugPrint('Bill upload rolled back: $error\n$stack');
      return BillImportSummary(
        totalFiles: 0,
        totalBills: 0,
        totalConsumersUpdated: 0,
        fileNames: [],
        errors: ['$currentSource: $error'],
      );
    } finally {
      _importing = false;
    }
  }

  List<BillHistory> _parseBillRows(
    List<String> headerRow,
    List<List<dynamic>> rows, {
    void Function(String status, double progress)? onProgress,
    required Set<String> fields,
  }) {
    String normalize(String h) =>
        h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normalized = headerRow.map(normalize).toList();
    if (normalized.toSet().length != normalized.length) {
      throw const FormatException('Duplicate CSV headers.');
    }
    int getCol(List<String> possibleNames) {
      String key(String text) =>
          text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final aliases = possibleNames.map(key).toSet();
      final matches = <int>[
        for (var i = 0; i < headerRow.length; i++)
          if (aliases.contains(key(headerRow[i]))) i,
      ];
      if (matches.length > 1) {
        throw FormatException(
          'Ambiguous duplicate column: ${possibleNames.first}',
        );
      }
      return matches.isEmpty ? -1 : matches.single;
    }

    final colConnNo = getCol(['Connection No', 'Connection No.', 'Conn No']);
    final colSector = getCol(['Sector']);
    final colLocality = getCol(['Locality']);
    final colConsumerName = getCol([
      'Consumer Name',
      'Name',
      'Consumer Name / F/H Name',
    ]);
    final colFhName = getCol([
      'Consumer F/H Name',
      'F/H Name',
      'FH Name',
      'Father Name',
    ]);
    final colSrNo = getCol(['Sr #', 'Sr#', 'Sr No', 'Serial', 'Sr.']);
    final colBillNo = getCol(['Bill No.', 'Bill No', 'BillNo']);
    final colBillType = getCol(['Bill Type', 'BillType', 'Type']);
    final colBillingPeriod = getCol([
      'Billing Period',
      'BillingPeriod',
      'Period',
    ]);
    final colArrears = getCol(['Arrears']);
    final colWaterFee = getCol(['Water Fee', 'WaterFee']);
    final colSanitation = getCol(['Sanitation', 'Sanitation Fee']);
    final colDrainage = getCol(['Drainage']);
    final colBillingFee = getCol(['Billing Fee', 'BillingFee', 'Biling Fee']);
    final colTotalBill = getCol(['Total Bill', 'TotalBill']);
    final colFine = getCol(['Fine']);
    final colAfterDueDate = getCol(['After Due Date', 'AfterDueDate']);
    final colDueDate = getCol(['Due Date', 'DueDate']);
    final colStatus = getCol(['Status', 'Bill Status']);
    final colAmountReceived = getCol(['Amount Received', 'AmountReceived']);
    final colReceiveDate = getCol(['Receive Date', 'ReceiveDate']);

    fields.addAll({
      if (colConnNo >= 0) 'connection_no',
      if (colSector >= 0) 'sector',
      if (colLocality >= 0) 'locality',
      if (colConsumerName >= 0) 'consumer_name',
      if (colFhName >= 0) 'father_husband_name',
      if (colSrNo >= 0) 'sr_no',
      if (colBillNo >= 0) 'bill_no',
      if (colBillType >= 0) 'bill_type',
      if (colBillingPeriod >= 0) 'billing_period',
      if (colArrears >= 0) 'arrears',
      if (colWaterFee >= 0) 'water_fee',
      if (colSanitation >= 0) 'sanitation',
      if (colDrainage >= 0) 'drainage',
      if (colBillingFee >= 0) 'billing_fee',
      if (colTotalBill >= 0) 'total_bill',
      if (colFine >= 0) 'fine',
      if (colAfterDueDate >= 0) 'after_due_date',
      if (colDueDate >= 0) 'due_date',
      if (colStatus >= 0) 'status',
      if (colAmountReceived >= 0) 'amount_received',
      if (colReceiveDate >= 0) 'receive_date',
    });

    String getVal(List<dynamic> row, int idx, [String defaultVal = '']) {
      if (idx == -1 || idx >= row.length) return defaultVal;
      final val = row[idx]?.toString().trim() ?? '';
      return val.isEmpty ? defaultVal : val;
    }

    String getMoney(List<dynamic> row, int column) {
      final value = getVal(row, column, '0');
      return {'-', '--', 'n/a'}.contains(value.toLowerCase()) ? '0' : value;
    }

    if (colConnNo < 0 ||
        colBillNo < 0 ||
        colTotalBill < 0 ||
        colStatus < 0 ||
        colAmountReceived < 0) {
      throw const FormatException(
        'Required bills columns: Connection No, Bill No, Total Bill, Status, Amount Received.',
      );
    }

    final bills = <BillHistory>[];
    final totalRows = rows.length - 1;

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty ||
          (row.length == 1 && row[0].toString().trim().isEmpty)) {
        continue;
      }

      // Skip row if completely empty/whitespace
      if (row.every((c) => c == null || c.toString().trim().isEmpty)) {
        continue;
      }

      final connNo = getVal(row, colConnNo);
      final billNo = getVal(row, colBillNo);

      // Skip separator / divider rows (e.g. "--- End of 99010334 (NAME) ---" or "--------------------")
      final isDivider =
          connNo.startsWith('---') ||
          connNo.startsWith('===') ||
          connNo.toLowerCase().contains('end of') ||
          (connNo.isNotEmpty &&
              connNo.replaceAll(RegExp(r'[\s\-_=]'), '').isEmpty) ||
          billNo.startsWith('---') ||
          billNo.startsWith('===') ||
          (billNo.isNotEmpty &&
              billNo.replaceAll(RegExp(r'[\s\-_=]'), '').isEmpty);

      if (isDivider) {
        continue;
      }

      if (row.length != headerRow.length || connNo.isEmpty || billNo.isEmpty) {
        throw FormatException(
          'Invalid bill identity or column count at CSV row ${i + 1}.',
        );
      }
      for (final column in [
        colTotalBill,
        colAmountReceived,
        colArrears,
        colWaterFee,
        colFine,
        colSanitation,
        colDrainage,
        colBillingFee,
        colAfterDueDate,
      ]) {
        if (column < 0) continue;
        final rawValue = getVal(
          row,
          column,
          '0',
        ).replaceAll(',', '').replaceAll(' ', '');
        final value =
            (rawValue == '-' ||
                rawValue == '--' ||
                rawValue.toLowerCase() == 'n/a')
            ? '0'
            : rawValue;
        final amount = double.tryParse(value);
        if (amount == null ||
            !amount.isFinite ||
            importAmountInPaisa(value) == null ||
            (amount < 0 &&
                ![
                  colArrears,
                  colTotalBill,
                  colAfterDueDate,
                ].contains(column))) {
          throw FormatException(
            'Invalid ${headerRow[column]} at CSV row ${i + 1}.',
          );
        }
      }

      if (!{'paid', 'unpaid', 'expired'}.contains(
        getVal(row, colStatus).toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''),
      )) {
        throw FormatException('Invalid bill status at row ${i + 1}.');
      }
      bills.add(
        BillHistory(
          connectionNo: connNo,
          sector: getVal(row, colSector),
          locality: getVal(row, colLocality),
          consumerName: getVal(row, colConsumerName),
          fatherHusbandName: getVal(row, colFhName),
          srNo: getVal(row, colSrNo),
          billNo: getVal(row, colBillNo),
          billType: getVal(row, colBillType),
          billingPeriod: getVal(row, colBillingPeriod),
          arrears: getMoney(row, colArrears),
          waterFee: getMoney(row, colWaterFee),
          sanitation: getMoney(row, colSanitation),
          drainage: getMoney(row, colDrainage),
          billingFee: getMoney(row, colBillingFee),
          totalBill: getMoney(row, colTotalBill),
          fine: getMoney(row, colFine),
          afterDueDate: getMoney(row, colAfterDueDate),
          dueDate: getVal(row, colDueDate, '-'),
          status: getVal(row, colStatus, 'Un-Paid'),
          amountReceived: getMoney(row, colAmountReceived),
          receiveDate: getVal(row, colReceiveDate, '-'),
          createdAt: DateTime.now().toIso8601String(),
        ),
      );

      if (i % 2000 == 0) {
        onProgress?.call('Parsing row $i of $totalRows...', i / totalRows);
      }
    }

    return bills;
  }
}

List<List<dynamic>> _decodeBillsCsv(String text) =>
    csv.decode(text.replaceFirst(RegExp(r'^\ufeff'), ''));
