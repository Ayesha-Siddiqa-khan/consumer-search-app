import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/bill_import_service.dart';
import '../services/csv_import_service.dart';
import '../services/database_service.dart';
import '../services/export_service.dart';
import '../widgets/pdf_export_dialog.dart';
import '../widgets/import_progress_dialog.dart';
import '../theme/app_theme.dart';

Future<bool> confirmDatabaseBackupImport(
  BuildContext context,
  String fileName,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace all data with this backup?'),
        content: SingleChildScrollView(
          child: Text(
            'Selected backup: $fileName\n\n'
            'Your existing consumers, bill history, report selections, and saved voice '
            'corrections will be removed and replaced with the data in this backup. '
            'The backup will NOT be merged with your current data.\n\n'
            'Export your current SQLite backup first if you want to keep it. '
            'Old CSV upload dates will be cleared after a successful import.\n\n'
            'Cancel leaves your current data unchanged.',
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Replace All Data & Import'),
          ),
        ],
      ),
    ) ??
    false;

class SettingsScreen extends StatefulWidget {
  final VoidCallback onDataChanged;

  const SettingsScreen({super.key, required this.onDataChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Natural serial sort: "bills (1).csv" before "bills (2).csv" before "bills (10).csv".
List<PlatformFile> sortFilesSerially(List<PlatformFile> files) {
  final copy = List<PlatformFile>.from(files);
  copy.sort((a, b) {
    final nameA = a.name.toLowerCase();
    final nameB = b.name.toLowerCase();
    final cmp = nameA.compareTo(nameB);
    if (cmp != 0) return cmp;
    // Break ties by looking for a trailing number: "file (2).csv"
    final numA = RegExp(r'\((\d+)\)').firstMatch(nameA)?.group(1);
    final numB = RegExp(r'\((\d+)\)').firstMatch(nameB)?.group(1);
    if (numA != null && numB != null) {
      return int.parse(numA).compareTo(int.parse(numB));
    }
    return 0;
  });
  return copy;
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = false;
  bool _isImporting = false;
  Map<String, dynamic>? _stats;
  String? _lastConsumerUpload;
  String? _lastHistoryUpload;
  String? _lastBillsUpload;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadTimestamps();
  }

  Future<void> _loadTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _lastConsumerUpload = prefs.getString('last_consumer_upload');
        _lastHistoryUpload = prefs.getString('last_history_upload');
        _lastBillsUpload = prefs.getString('last_bills_upload');
      });
    }
  }

  Future<void> _saveTimestamp(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final formatted = '${now.day.toString().padLeft(2, '0')} ${_monthName(now.month)} ${now.year}, ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
    await prefs.setString(key, formatted);
    _loadTimestamps();
  }

  String _monthName(int month) {
    const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return names[month - 1];
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    try {
      final stats = await DatabaseService.instance.getStats();
      if (mounted) {
        setState(() {
          _stats = stats;
        });
      }
    } catch (e, stack) {
      debugPrint('Error loading stats: $e\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _importCounts(String kind) {
    final run = (_stats?['latestImports'] as Map?)?[kind] as Map?;
    final number = NumberFormat.decimalPattern('en');
    String count(String key) => number.format(run?[key] ?? 0);
    return SizedBox(
      width: 270,
      child: Padding(
        padding: const EdgeInsets.only(top: 6, left: 4),
        child: SelectableText(
          [
            if (kind == 'history')
              'Stored history: ${number.format(_stats?['historyConnections'] ?? 0)} connections | ${number.format(_stats?['billHistoryCount'] ?? 0)} bills',
            if (run != null) ...[
              'Latest import: ${run['connections'] == null ? 'connection count not recorded' : '${count('connections')} connections'}',
              '${count('inserted')} new bills | ${count('updated')} updated bills',
              '${count('unchanged')} unchanged | ${count('held')} held for review',
              if (run['consumers_updated'] != null)
                '${count('consumers_updated')} consumer records updated',
            ] else
              'No saved ${kind == 'history' ? 'history import' : 'daily update'} report.',
          ].join('\n'),
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Future<void> _confirmClearDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('Confirm Clear Database'),
          ],
        ),
        content: const Text(
          'Are you sure you want to delete all consumers, bills, report selections, and saved voice corrections?\n\n'
          'This also clears import timestamps. Import your consumer and bills CSV files again to start fresh.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete All Data'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        await DatabaseService.instance.clearDatabase();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('database_manually_cleared', true);
        await prefs.remove('last_consumer_upload');
        await prefs.remove('last_bills_upload');
        await prefs.remove('last_history_upload');
        if (!mounted) return;
        setState(() {
          _lastConsumerUpload = null;
          _lastBillsUpload = null;
          _lastHistoryUpload = null;
        });
        await _loadStats();
        widget.onDataChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All consumers, bills, and report data cleared.'), backgroundColor: Colors.redAccent),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not clear all data: $e')));
        }
      }
    }
  }

  Future<void> _importCustomCsv() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Step 1: Consumer master CSV (any filename)',
    );
    if (file?.path == null || !mounted) return;
    await _showProgressDialog(
      title: 'Validating & Importing Consumer Master',
      task: (update) async {
        final result = await CsvImportService.instance.importConsumerFile(
          file!.path!,
          onProgress: update,
        );
        await _saveTimestamp('last_consumer_upload');
        return result.total;
      },
      showResult: (count) =>
          '$count consumer records processed. Existing bill history and payments preserved.',
    );
  }

  Future<void> _importBillsCsv() async {
    if (!await _checkImportOrder(daily: true)) return;
    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Step 3: Daily bills CSV (any filename)',
    );
    if (!mounted || selected.isEmpty) return;
    await _importSelectedBills(
      selected.where((f) => f.path != null).map((f) => File(f.path!)).toList(),
      isHistory: false,
    );
  }

  Future<void> _importBillsFromFolder() async {
    if (!await _checkImportOrder(daily: false)) return;
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Step 2: Choose full history folder (any name)',
    );
    if (!mounted || folder == null) return;
    final files = await Directory(folder)
        .list(recursive: true, followLinks: false)
        .where((f) => f is File && f.path.toLowerCase().endsWith('.csv'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No CSV files found in the selected folder.'),
        ),
      );
      return;
    }
    await _importSelectedBills(files, isHistory: true);
  }

  Future<bool> _checkImportOrder({required bool daily}) async {
    final stats = await DatabaseService.instance.getStats();
    final history = await DatabaseService.instance.getBillHistoryCount();
    if (!mounted) return false;
    if ((stats['total'] as int? ?? 0) == 0 || (daily && history == 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            daily
                ? 'Import the consumer master (1), then full history (2), before daily bills (3).'
                : 'Import the consumer master (1) before history (2).',
          ),
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> _importSelectedBills(
    List<File> files, {
    required bool isHistory,
  }) async {
    var selectedDate = DateTime.now();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(
            isHistory
                ? 'Step 2: Full bill history'
                : 'Step 3: Daily bill updates',
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${files.length} CSV file(s) selected. All files will be validated before saving.',
                ),
                const SizedBox(height: 12),
                Text(
                  isHistory
                      ? 'Repeated bills are collapsed. ISO snapshot dates in filenames are optional hints; newer snapshots take precedence. The date below applies to files without a date in their name. Equal-date conflicts are held for review.'
                      : 'Use the date of this downloaded snapshot. Existing bill periods and receipt dates are preserved when omitted. Missing payment dates are flagged. Older snapshots and payment regressions cannot undo saved payments.',
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: const Icon(Icons.calendar_today),
                  label: Text(
                    'Snapshot date: ${DateFormat('dd-MM-yyyy').format(selectedDate)}',
                  ),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: selectedDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) update(() => selectedDate = date);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Validate & Import'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    BillImportSummary? summary;
    final count = await _showProgressDialog(
      title: isHistory ? 'Importing Full History' : 'Applying Daily Updates',
      task: (update) async {
        summary = await BillImportService.instance.importBillHistoryFiles(
          files,
          isHistory: isHistory,
          repairSourceConflicts: isHistory,
          asOf: selectedDate,
          onProgress: update,
        );
        if (summary!.hasErrors) {
          throw FormatException(
            'No bill changes were saved. ${summary!.errors.join('; ')}',
          );
        }
        await _saveTimestamp(
          isHistory ? 'last_history_upload' : 'last_bills_upload',
        );
        return summary!.totalBills;
      },
      showResult: (_) => summary!.description,
    );
    if (mounted && count != null && summary != null) {
      await _showImportReport(summary!);
    }
  }

  Future<void> _showImportReport(BillImportSummary summary) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import reconciliation report'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: SelectableText(
              '${summary.description}\n\n${summary.issues.take(100).map((r) => "${r['connection_no']} / ${r['bill_no']}: ${r['reason']}").join('\n')}'
              '${summary.issues.length > 100 ? '\n\nShowing the first 100 notes. Export the CSV for every note.' : ''}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await FilePicker.saveFile(
                fileName:
                    'Import_Review_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
                bytes: Uint8List.fromList(
                  utf8.encode('\ufeff${summary.reviewCsv}'),
                ),
                type: FileType.custom,
                allowedExtensions: ['csv'],
                dialogTitle: 'Save complete import review report',
              );
            },
            child: const Text('Export review CSV'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _reviewLastImport() async {
    final db = await DatabaseService.instance.database;
    final exists = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE name = 'data_import_runs'",
    );
    final rows = exists.isEmpty
        ? <Map<String, Object?>>[]
        : await db.query('data_import_runs', orderBy: 'id DESC', limit: 1);
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No import report saved yet.')),
      );
      return;
    }
    final row = rows.single;
    final stats = jsonDecode(row['summary'] as String) as Map<String, dynamic>;
    final issues = (jsonDecode(row['issues'] as String) as List)
        .map((r) => Map<String, String>.from(r as Map))
        .toList();
    await _showImportReport(
      BillImportSummary(
        totalFiles: 0,
        totalBills: 0,
        totalConsumersUpdated: 0,
        fileNames: [],
        inserted: stats['inserted'] as int,
        updated: stats['updated'] as int,
        unchanged: stats['unchanged'] as int,
        held: stats['held'] as int,
      superseded: stats['superseded'] as int? ?? 0,
        duplicateRows: stats['duplicate_rows'] as int? ?? 0,
        issues: issues,
      ),
    );
  }

  Future<void> _exportCsvBackup() async {
    final savedPath = await ExportService.instance.exportCsvBackup();
    if (savedPath != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('CSV Backup saved: $savedPath'),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  Future<void> _exportDatabaseFile() async {
    final savedPath = await ExportService.instance.exportDatabaseBackup();
    if (savedPath != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('SQLite Database Backup saved: $savedPath'),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  Future<void> _importDatabaseFile() async {
    if (_isImporting || _isLoading) return;
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Import SQLite Backup (.db)',
        type: FileType.custom,
        allowedExtensions: ['db', 'sqlite', 'sqlite3'],
      );
      if (file?.path == null || !mounted) return;
      if (!await confirmDatabaseBackupImport(context, file!.name) || !mounted) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      // An intentionally empty restore must not seed the bundled CSV on restart.
      await prefs.setBool('database_manually_cleared', true);
      final count = await _showProgressDialog(
        title: 'Importing SQLite Backup',
        task: (update) async {
          update('Validating backup and replacing records...', 0.1);
          return DatabaseService.instance.restoreDatabaseBackup(file.path!);
        },
        showResult: (count) =>
            'SQLite backup imported. Replaced current data with $count consumers '
            'and the backup’s bill history, report selections, and saved corrections.',
      );
      if (count == null) return;
      try {
        for (final key in [
          'last_consumer_upload',
          'last_bills_upload',
          'last_history_upload',
        ]) {
          await prefs.remove(key);
        }
        await _loadTimestamps();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Backup imported, but old upload dates could not be cleared: $e',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import SQLite backup: $e')),
        );
      }
    }
  }

  Future<void> _exportAllPdf() async {
    final res = await DatabaseService.instance.searchConsumers(pageSize: 500);
    if (!mounted) return;
    PdfExportDialog.show(
      context: context,
      currentConsumers: res.items,
      totalFilteredCount: res.totalCount,
      filterSummary: 'Full Database Export',
    );
  }

  Future<int?> _showProgressDialog({
    required String title,
    required ImportTask task,
    String Function(int count)? showResult,
  }) async {
    if (_isImporting) return null;
    _isImporting = true;
    try {
      final count = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportProgressDialog(title: title, task: task),
      );
      if (!mounted || count == null) return null;
      await _loadStats();
      if (!mounted) return count;
      widget.onDataChanged();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(showResult?.call(count) ?? 'Successfully imported $count records!'),
        duration: const Duration(seconds: 10),
        backgroundColor: AppTheme.primaryGreen,
      ));
      return count;
    } finally { _isImporting = false; }
  }

  @override
  Widget build(BuildContext context) {
    final total = _stats?['total'] ?? 0;
    final active = _stats?['active'] ?? 0;
    final inactive = _stats?['inactive'] ?? 0;
    final sectors = _stats?['sectors'] ?? 0;
    final localities = _stats?['localities'] ?? 0;
    final fileSizeBytes = _stats?['fileSizeBytes'] ?? 0;
    final fileSizeMb = (fileSizeBytes / (1024 * 1024)).toStringAsFixed(2);
    final dbPath = _stats?['dbPath'] ?? 'N/A';

    final unknownConsumerStatus = _stats?['unknownConsumerStatus'] ?? 0;
    final statusUnavailable = unknownConsumerStatus > 0 && unknownConsumerStatus == (_stats?['total'] ?? 0);
    final regular = _stats?['regular'] ?? 0;
    final closed = _stats?['closed'] ?? 0;
    final suspended = _stats?['suspended'] ?? 0;
    final newDemand = _stats?['newDemand'] ?? 0;
    final commercial = _stats?['commercialCount'] ?? 0;
    final privateSocieties = _stats?['privateCount'] ?? 0;
    final domestic = _stats?['domesticCount'] ?? 0;
    final domesticRegular = _stats?['domesticConnectionCount'] ?? 0;
    final commercialRegular = _stats?['commercialConnectionCount'] ?? 0;
    final privateSocietiesRegular = _stats?['privateConnectionCount'] ?? 0;

    final totalBillsCount = _stats?['totalBillsCount'] ?? 0;
    final paidBillsCount = _stats?['paidBillsCount'] ?? 0;
    final pendingBillsCount = _stats?['pendingBillsCount'] ?? 0;
    final expiredBillsCount = _stats?['expiredBillsCount'] ?? 0;
    final totalBilledAmount = (_stats?['totalBilledAmount'] as num?)?.toDouble() ?? 0.0;
    final totalReceivedAmount = (_stats?['totalReceivedAmount'] as num?)?.toDouble() ?? 0.0;
    final totalPendingAmount = (_stats?['totalPendingAmount'] as num?)?.toDouble() ?? 0.0;
    final recoveryRate = (_stats?['recoveryRate'] as num?)?.toDouble() ?? 0.0;


    // If hot-reloaded while viewing screen and new keys are missing, auto-fetch immediately
    if (!_isLoading && (_stats == null || !_stats!.containsKey('billingImportedAt'))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isLoading) {
          _loadStats();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('System Settings & Database Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Statistics',
            onPressed: _loadStats,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Overview Header
                      const Text(
                        'Database Overview & Statistics',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.darkGreen,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Metric Cards Row 1: Consumer Counts
                      Row(
                        children: [
                          Expanded(child: _metricCard('Total Records', _formatNumber(total), Icons.people, AppTheme.primaryGreen)),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('Active Consumers', statusUnavailable ? 'Not provided' : _formatNumber(active), Icons.check_circle, Colors.teal)),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('In-Active', statusUnavailable ? 'Not provided' : _formatNumber(inactive), Icons.cancel, Colors.orange.shade800)),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('Sectors / Localities', '${_formatNumber(sectors)} / ${_formatNumber(localities)}', Icons.location_city, Colors.blueGrey)),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Metric Cards Row 2: Connection Statuses (Regular, Closed, Suspended, New Demand)
                      Row(
                        children: [
                          Expanded(child: _metricCard('Regular Connection', _formatNumber(regular), Icons.verified, const Color(0xFF1B5E20))),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('Closed / Dead', _formatNumber(closed), Icons.block, const Color(0xFFC62828))),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('Suspended', _formatNumber(suspended), Icons.pause_circle_outline, const Color(0xFFE65100))),
                          const SizedBox(width: 12),
                          Expanded(child: _metricCard('New Demand', _formatNumber(newDemand), Icons.fiber_new, const Color(0xFF1565C0))),
                        ],
                      ),
                      const SizedBox(height: 20),

                      if (unknownConsumerStatus > 0)
                        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('${_formatNumber(unknownConsumerStatus)} records have no Consumer Status. Import a consumer master with that column for Active / Inactive counts.')),

                      // Section: Category Totals & Collections
                      const Divider(height: 28),
                      Row(
                        children: [
                          const Icon(Icons.category_rounded, color: AppTheme.darkGreen, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Category Totals & Collections',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.darkGreen,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Bills in the selected CSV only; a connection may have more than one bill.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 12),

                      // Metric Cards Row 3: Rate Categories (Domestic, Commercial, Private Societies)
                      Row(
                        children: [
                          Expanded(
                            child: _metricCard(
                              'Domestic Bills',
                              _formatNumber(domestic),
                              Icons.home,
                              Colors.teal.shade700,
                              subtitle: '${_formatNumber(domesticRegular)} Billed Connections',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _metricCard(
                              'Commercial Bills',
                              _formatNumber(commercial),
                              Icons.store,
                              Colors.indigo.shade700,
                              subtitle: '${_formatNumber(commercialRegular)} Billed Connections',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _metricCard(
                              'Private Societies Bills',
                              _formatNumber(privateSocieties),
                              Icons.apartment,
                              Colors.deepPurple.shade700,
                              subtitle: '${_formatNumber(privateSocietiesRegular)} Billed Connections',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      _billingBreakdown(),
                      const SizedBox(height: 20),

                      // Section: Imported Bills & Revenue Collections Overview
                      const Divider(height: 28),
                      Row(
                        children: [
                          const Icon(Icons.receipt_long_rounded, color: AppTheme.darkGreen, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Imported Bills & Revenue Collections Overview',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.darkGreen,
                            ),
                          ),
                          const Spacer(),
                          if (_stats?['billingImportedAt'] != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.green.shade200),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.history, size: 14, color: Colors.green.shade800),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Last Imported: ${DateFormat('dd MMM yyyy, h:mm a').format(DateTime.parse(_stats!['billingImportedAt'] as String).toLocal())}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.green.shade900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Source: ${_stats?['billingSource'] ?? 'No bills imported'}. Arrears are already included in demand.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 12),

                      // Metric Cards Row 5: 4 KPI Cards for Imported Bills
                      Row(
                        children: [
                          // 1. Total Billed Demand / Income
                          Expanded(
                            child: _metricCard(
                              'Total Billed Demand',
                              _formatRupees(totalBilledAmount),
                              Icons.assessment_rounded,
                              const Color(0xFF1565C0),
                              subtitle: '${_formatNumber(totalBillsCount)} bills in report',
                            ),
                          ),
                          const SizedBox(width: 12),

                          // 2. Total Collected / Received
                          Expanded(
                            child: _metricCard(
                              'Total Received / Collected',
                              _formatRupees(totalReceivedAmount),
                              Icons.check_circle_outline_rounded,
                              const Color(0xFF1B5E20),
                              subtitle: '${_formatNumber(paidBillsCount)} bills marked Paid',
                            ),
                          ),
                          const SizedBox(width: 12),

                          // 3. Pending / Outstanding Balance
                          Expanded(
                            child: _metricCard(
                              'Pending / Outstanding Amount',
                              _formatRupees(totalPendingAmount),
                              Icons.pending_actions_rounded,
                              const Color(0xFFC62828),
                              subtitle: '${_formatNumber(pendingBillsCount)} Pending Bills (${_formatNumber(expiredBillsCount)} Expired)',
                            ),
                          ),
                          const SizedBox(width: 12),

                          // 4. Overall Recovery Rate
                          Expanded(
                            child: _metricCard(
                              'Revenue Recovery Rate',
                              '${recoveryRate.toStringAsFixed(1)}%',
                              Icons.pie_chart_rounded,
                              const Color(0xFF6A1B9A),
                              subtitle: 'Actual receipts / billed demand',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Recovery Progress Strip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.trending_up, size: 16, color: AppTheme.primaryGreen),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Collection Recovery Progress',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade800,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${_formatRupees(totalReceivedAmount)} of ${_formatRupees(totalBilledAmount)} (${recoveryRate.toStringAsFixed(1)}%)',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primaryGreen,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: totalBilledAmount > 0
                                    ? (totalReceivedAmount / totalBilledAmount).clamp(0.0, 1.0)
                                    : 0.0,
                                minHeight: 8,
                                backgroundColor: Colors.red.shade100,
                                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryGreen),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '● Received: ${_formatNumber(paidBillsCount)} Bills (${_formatRupees(totalReceivedAmount)})',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF1B5E20),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '● Outstanding: ${_formatNumber(pendingBillsCount)} Bills (${_formatRupees(totalPendingAmount)})',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.red.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Database Storage Info Card
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.storage_rounded, color: AppTheme.primaryGreen),
                                  SizedBox(width: 8),
                                  Text(
                                    'SQLite Storage Information',
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const Divider(height: 20),
                              _infoLine('Database Size:', '$fileSizeMb MB'),
                              _infoLine('Bill History Records:', '${_stats?['billHistoryCount'] ?? 0} distinct bills stored (all imports)'),
                              _infoLine('File Location:', dbPath),
                              _infoLine('Search Engine Indexing:', 'SQLite FTS5 Full-Text Search + Multi B-Tree Indexes active'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Date Format Compliance Card
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.calendar_month, color: AppTheme.primaryGreen),
                                  SizedBox(width: 8),
                                  Text(
                                    'Pakistani Date Format Standard',
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const Divider(height: 20),
                              _infoLine('Standard Format:', 'DD-MM-YYYY (e.g. 17-09-2026)'),
                              _infoLine('Language:', 'English (Official Government Standards)'),
                              _infoLine('System Compliance:', 'All dates in consumer tables and dossier views are normalized to DD-MM-YYYY.'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Data Operations & Controls
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.admin_panel_settings, color: AppTheme.primaryGreen),
                                  SizedBox(width: 8),
                                  Text(
                                    'Data Management Actions',
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const Divider(height: 20),
                              const Text('First time: 1, then 2, then 3. Afterwards, repeat step 3. Any filename is accepted; columns identify the data.'),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade800),
                                        icon: const Icon(Icons.upload_file),
                                        label: const Text('1. Import Consumer Master CSV'),
                                        onPressed: _importCustomCsv,
                                      ),
                                      if (_lastConsumerUpload != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Last uploaded: $_lastConsumerUpload',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                          ),
                                        )
                                      else
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Not yet uploaded',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                                          ),
                                        ),
                                    ],
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF26522)),
                                        icon: const Icon(Icons.folder_special),
                                        label: const Text('2. Import Full History Folder'),
                                        onPressed: _importBillsFromFolder,
                                      ),
                                      if (_lastHistoryUpload != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Last uploaded: $_lastHistoryUpload',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                          ),
                                        )
                                      else
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Browse any folder name; includes subfolders',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                          ),
                                        ),
                                      _importCounts('history'),
                                    ],
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700),
                                        icon: const Icon(Icons.receipt_long),
                                        label: const Text('3. Update Daily Bills CSV'),
                                        onPressed: _importBillsCsv,
                                      ),
                                      if (_lastBillsUpload != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Last uploaded: $_lastBillsUpload',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                          ),
                                        )
                                      else
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4, left: 4),
                                          child: Text(
                                            'Not yet uploaded',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                                          ),
                                        ),
                                      _importCounts('daily'),
                                    ],
                                  ),
                                  OutlinedButton.icon(icon: const Icon(Icons.fact_check), label: const Text('Review Last Import'), onPressed: _reviewLastImport),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB71C1C)),
                                    icon: const Icon(Icons.picture_as_pdf),
                                    label: const Text('Export Database to PDF...'),
                                    onPressed: _exportAllPdf,
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade800),
                                    icon: const Icon(Icons.file_download),
                                    label: const Text('Export CSV Backup (.csv)'),
                                    onPressed: _exportCsvBackup,
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade800),
                                    icon: const Icon(Icons.storage),
                                    label: const Text('Export SQLite Backup (.db)'),
                                    onPressed: _exportDatabaseFile,
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade600),
                                    icon: const Icon(Icons.restore),
                                    label: const Text('Import SQLite Backup (.db)'),
                                    onPressed: _importDatabaseFile,
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
                                    icon: const Icon(Icons.delete_forever),
                                    label: const Text('Delete / Clear All Data'),
                                    onPressed: _confirmClearDatabase,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  String _formatNumber(num value) {
    return NumberFormat('#,##0').format(value);
  }

  String _formatRupees(double amount) {
    return 'Rs. ${NumberFormat('#,##0').format(amount.round())}';
  }

  Future<void> _exportBillingSummary({required bool print}) async {
    if (_stats == null) return;
    try {
      final bytes = await ExportService.instance.generateBillingSummaryPdf(Map<String, dynamic>.from(_stats!));
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Category Totals and Collections', dynamicLayout: false);
      } else {
        await FilePicker.saveFile(fileName: 'category_totals_and_collections.pdf', bytes: bytes,
          dialogTitle: 'Save Billing Summary PDF', type: FileType.custom, allowedExtensions: ['pdf']);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export billing summary: $e')));
    }
  }

  Widget _billingBreakdown() {
    final entries = <String, String>{
      'domestic': 'Domestic', 'commercial': 'Commercial',
      'private': 'Private Societies',
      if ((_stats?['unknownCount'] as int? ?? 0) > 0) 'unknown': 'Unclassified',
      '': 'Total',
    };
    String amount(String key) => _formatRupees((_stats?[key] as num? ?? 0).toDouble());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Bills and collections from the report source below'),
        OutlinedButton.icon(onPressed: () => _exportBillingSummary(print: false), icon: const Icon(Icons.picture_as_pdf), label: const Text('Save PDF')),
        OutlinedButton.icon(onPressed: () => _exportBillingSummary(print: true), icon: const Icon(Icons.print), label: const Text('Print PDF')),
      ]),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          border: TableBorder.all(color: Colors.teal.shade200),
          headingRowColor: WidgetStatePropertyAll(Colors.teal.shade800),
          headingTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          dataRowMinHeight: 48,
          dataRowMaxHeight: 60,
          columnSpacing: 18,
          columns: [for (final label in ['Category', 'Bills', 'Paid bills amount', 'Unpaid / expired amount', 'Arrears (included)', 'Amount received']) DataColumn(label: Text(label))],
          rows: [for (final entry in entries.entries) DataRow(color: WidgetStatePropertyAll(entry.key.isEmpty ? Colors.teal.shade100 : entry.key == 'commercial' ? Colors.blue.shade50 : entry.key == 'private' ? Colors.purple.shade50 : Colors.teal.shade50), cells: [
            DataCell(Text(entry.value, style: const TextStyle(fontWeight: FontWeight.bold))),
            DataCell(Text(_formatNumber(_stats?['${entry.key}Count'] ?? 0))),
            DataCell(Text(amount('${entry.key}PaidAmount'), style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.w600))),
            DataCell(Text(amount('${entry.key}UnpaidAmount'), style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600))),
            DataCell(Text(amount('${entry.key}Arrears'), style: TextStyle(color: Colors.deepOrange.shade800, fontWeight: FontWeight.w600))),
            DataCell(Text(amount('${entry.key}Received'), style: TextStyle(color: Colors.blue.shade800, fontWeight: FontWeight.w600))),
          ])],
        ),
      ),
      if ((_stats?['unknownCount'] as int? ?? 0) > 0)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('Unclassified bills have no unique category in the consumer list. Import the matching consumer master to classify them.')),
    ]);
  }

  Widget _metricCard(
    String title,
    String val,
    IconData icon,
    Color color, {
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            val,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),

            ),
          ],
        ],
      ),
    );
  }

  Widget _infoLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
            ),
          ),
        ],
      ),
    );
  }
}
