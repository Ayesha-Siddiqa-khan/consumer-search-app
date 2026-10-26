import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/bill_history_model.dart';
import '../models/history_bill_balance.dart';
import '../models/billing_audit_model.dart';
import '../services/bill_import_service.dart';
import '../services/database_service.dart';
import '../services/export_service.dart';
import '../theme/app_theme.dart';
import 'package:printing/printing.dart';
import 'copyable_text.dart';

class BillHistoryDialog extends StatefulWidget {
  final String initialConnectionNo;
  final DatabaseService? database;
  final VoidCallback? onHistoryChanged;

  const BillHistoryDialog({
    super.key,
    required this.initialConnectionNo,
    this.database,
    this.onHistoryChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required String connectionNo,
    DatabaseService? database,
    VoidCallback? onHistoryChanged,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => BillHistoryDialog(
        initialConnectionNo: connectionNo,
        database: database,
        onHistoryChanged: onHistoryChanged,
      ),
    );
  }

  @override
  State<BillHistoryDialog> createState() => _BillHistoryDialogState();
}

class _BillHistoryDialogState extends State<BillHistoryDialog> {
  late final TextEditingController _connCtrl;
  final ScrollController _horizontalScrollCtrl = ScrollController();

  bool _isLoading = false;
  bool _isImporting = false;
  bool _isGeneratingPdf = false;
  String _importStatus = '';
  double _importProgress = 0.0;

  Map<String, String>? _consumerDetail;
  List<BillHistory> _bills = [];
  BillingAuditEntry? _financialAudit;
  int _currentPage = 1;
  int _pageSize = 10;
  final List<int> _pageSizeOptions = [10, 20, 50, 100];
  final NumberFormat _currencyFormat = NumberFormat('#,##0.##');

  String _auditMoney(int? paisa) => paisa == null
      ? 'Needs review'
      : 'Rs. ${_currencyFormat.format(paisa / 100)}';

  @override
  void initState() {
    super.initState();
    _connCtrl = TextEditingController(text: widget.initialConnectionNo.trim());
    _loadHistory();
  }

  @override
  void dispose() {
    _connCtrl.dispose();
    _horizontalScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final connNo = _connCtrl.text.trim();
    if (connNo.isEmpty) return;

    setState(() {
      _isLoading = true;
      _currentPage = 1;
    });

    try {
      final database = widget.database ?? DatabaseService.instance;
      final detail = await database.getConsumerConnectionDetail(connNo);
      final rawList = await database.getBillHistory(connNo);
      final sortedList = List<BillHistory>.of(rawList)
        ..sort(compareHistoryBillsNewestFirst);
      final audit = await database.getBillingAudit(connectionNo: connNo);

      if (mounted) {
        setState(() {
          _consumerDetail = detail;
          _bills = sortedList;
          _financialAudit = audit.isEmpty ? null : audit.single;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading bill history: $e')),
        );
      }
    }
  }

  Future<void> _pickAndImportFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Select Bill History CSV File(s)',
      );

      if (result.isEmpty) return;

      final files = result
          .map((f) => f.path)
          .where((p) => p != null && p.isNotEmpty)
          .map((p) => File(p!))
          .toList();

      if (files.isEmpty) return;

      setState(() {
        _isImporting = true;
        _importProgress = 0.02;
        _importStatus = 'Selected ${files.length} file(s)...';
      });

      final importer = widget.database == null
          ? BillImportService.instance
          : BillImportService.forTesting(widget.database!);
      final summary = await importer.importBillHistoryFiles(
        files,
        isHistory: true,
        onProgress: (status, progress) {
          if (mounted) {
            setState(() {
              _importStatus = status;
              _importProgress = progress;
            });
          }
        },
      );

      if (summary.hasErrors) throw FormatException(summary.errors.join('; '));
      if (summary.inserted + summary.updated + summary.superseded > 0) {
        widget.onHistoryChanged?.call();
      }
      if (mounted) {
        setState(() {
          _isImporting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(summary.description),
            backgroundColor: AppTheme.primaryGreen,
            duration: const Duration(seconds: 4),
          ),
        );

        // Reload current view
        _loadHistory();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isImporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _printBillHistory() async {
    if (_bills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No bill history records available to print.'),
        ),
      );
      return;
    }

    setState(() => _isGeneratingPdf = true);
    try {
      final connNo = _connCtrl.text.trim();
      final pdfBytes = await ExportService.instance.generateBillHistoryPdf(
        connectionNo: connNo.isNotEmpty ? connNo : (_bills.first.connectionNo),
        consumerDetail: _consumerDetail,
        bills: _bills,
        audit: _financialAudit,
      );

      final dateStr = DateFormat('dd-MM-yyyy').format(DateTime.now());
      await Printing.layoutPdf(
        onLayout: (_) => pdfBytes,
        name: 'Bill_History_${connNo}_$dateStr.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate print document: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGeneratingPdf = false);
      }
    }
  }

  Future<void> _exportBillHistoryPdf() async {
    if (_bills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No bill history records available to export.'),
        ),
      );
      return;
    }

    setState(() => _isGeneratingPdf = true);
    try {
      final connNo = _connCtrl.text.trim();
      final pdfBytes = await ExportService.instance.generateBillHistoryPdf(
        connectionNo: connNo.isNotEmpty ? connNo : (_bills.first.connectionNo),
        consumerDetail: _consumerDetail,
        bills: _bills,
        audit: _financialAudit,
      );

      final dateStr = DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now());
      final defaultName = 'Bill_History_${connNo}_$dateStr.pdf';

      final saveUri = await FilePicker.saveFile(
        fileName: defaultName,
        bytes: pdfBytes,
        dialogTitle: 'Save Bill History PDF',
        allowedExtensions: ['pdf'],
        type: FileType.custom,
      );

      if (saveUri != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Bill History PDF saved successfully! ($saveUri)'),
            backgroundColor: AppTheme.primaryGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save PDF: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGeneratingPdf = false);
      }
    }
  }

  List<BillHistory> get _paginatedBills {
    final start = (_currentPage - 1) * _pageSize;
    if (start >= _bills.length) return [];
    final end = (start + _pageSize < _bills.length)
        ? start + _pageSize
        : _bills.length;
    return _bills.sublist(start, end);
  }

  int get _totalPages => (_bills.length / _pageSize).ceil();

  @override
  Widget build(BuildContext context) {
    final totalRecords = _bills.length;
    final startItem = totalRecords == 0
        ? 0
        : (_currentPage - 1) * _pageSize + 1;
    final endItem = (_currentPage * _pageSize < totalRecords)
        ? _currentPage * _pageSize
        : totalRecords;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: SelectionArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1250, maxHeight: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Window Title Bar (Matching Image 2)
              _buildDialogHeader(),

              if (_isImporting) _buildImportProgressIndicator(),

              // Main Scrollable Area
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Search & Actions Row
                      _buildSearchAndActionsRow(),
                      const SizedBox(height: 20),

                      // Connection Detail Box (Matching Image 2)
                      _buildConnectionDetailCard(),
                      const SizedBox(height: 24),

                      // Table or Loading or Empty State
                      if (_isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: AppTheme.primaryGreen,
                            ),
                          ),
                        )
                      else if (_bills.isEmpty)
                        _buildEmptyState()
                      else ...[
                        _buildBillsTable(),
                      ],
                    ],
                  ),
                ),
              ),

              // Pagination & Footer Bar (Matching Image 2)
              if (_bills.isNotEmpty)
                _buildPaginationFooter(startItem, endItem, totalRecords),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0), width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, color: AppTheme.primaryGreen, size: 22),
          const SizedBox(width: 10),
          const Text(
            'Water Sanitation Bill History',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF263238),
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.grey, size: 22),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildImportProgressIndicator() {
    return Container(
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.primaryGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _importStatus,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1B5E20),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${(_importProgress * 100).toInt()}%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B5E20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: _importProgress,
            backgroundColor: Colors.grey.shade300,
            color: AppTheme.primaryGreen,
            minHeight: 5,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndActionsRow() {
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.end,
      alignment: WrapAlignment.spaceBetween,
      children: [
        // Left side: Connection No text field and Show History button
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: const TextSpan(
                      text: 'Connection No ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF374151),
                      ),
                      children: [
                        TextSpan(
                          text: '*',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _connCtrl,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(5),
                          borderSide: const BorderSide(
                            color: Color(0xFFD0D5DD),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(5),
                          borderSide: const BorderSide(
                            color: AppTheme.primaryGreen,
                            width: 1.5,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _loadHistory(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Show History Button
            SizedBox(
              height: 40,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _loadHistory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF26522),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text(
                  'Show History',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),

        // Right side Action Buttons: Print History, Export PDF, and Upload Bill CSV(s)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Print History Button
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                onPressed: (_isGeneratingPdf || _bills.isEmpty)
                    ? null
                    : _printBillHistory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: _isGeneratingPdf
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.print, size: 16),
                label: const Text(
                  'Print History',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Export PDF Button
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                onPressed: (_isGeneratingPdf || _bills.isEmpty)
                    ? null
                    : _exportBillHistoryPdf,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC62828),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: const Icon(Icons.picture_as_pdf, size: 16),
                label: const Text(
                  'Export PDF',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Upload Bill CSV(s) button (Allows multiple CSV files!)
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                onPressed: _isImporting ? null : _pickAndImportFiles,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: const Icon(Icons.file_upload, size: 16),
                label: const Text(
                  'Upload Bill CSV(s)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConnectionDetailCard() {
    final detail = _consumerDetail;
    final connNo = detail?['connection_no'] ?? _connCtrl.text.trim();
    final sector =
        detail?['sector'] ?? (_bills.isNotEmpty ? _bills.first.sector : '-');
    final locality =
        detail?['locality'] ??
        (_bills.isNotEmpty ? _bills.first.locality : '-');
    final name =
        detail?['consumer_name'] ??
        (_bills.isNotEmpty ? _bills.first.consumerName : '-');
    final fhName =
        detail?['father_husband_name'] ??
        (_bills.isNotEmpty ? _bills.first.fatherHusbandName : '-');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
      ),
      child: Column(
        children: [
          // Section Title: Connection Detail (centered as in Image 2)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
              ),
            ),
            child: const Center(
              child: Text(
                'Connection Detail',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1F2937),
                ),
              ),
            ),
          ),

          // Detail rows (matching Image 2 layout)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Column(
              children: [
                _buildDetailRow('Connection No', connNo, isBoldValue: true),
                const SizedBox(height: 8),
                _buildDetailRow('Sector', sector.isNotEmpty ? sector : '-'),
                const SizedBox(height: 8),
                _buildDetailRow(
                  'Locality',
                  locality.isNotEmpty ? locality : '-',
                ),
                const SizedBox(height: 8),
                _buildDetailRow('Consumer Name', name.isNotEmpty ? name : '-'),
                const SizedBox(height: 8),
                _buildDetailRow(
                  'Consumer F/H Name',
                  fhName.isNotEmpty ? fhName : '-',
                ),

                if (_financialAudit != null) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Divider(color: Color(0xFFE5E7EB), height: 1),
                  ),
                  _buildFinancialSummaryCards(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinancialSummaryCards() {
    final audit = _financialAudit!;
    final remaining = latestHistoryBillBalance(_bills);
    final hasPending = remaining.amount == null || remaining.amount! > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 6,
            children: [
              const Text(
                'Financial Overview / مالیاتی تفصیل',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Text(
                'Paid: ${audit.paidBillCount} / ${audit.billCount} | Unpaid: ${audit.unpaidBillCount} | Expired (carried): ${audit.expiredBillCount}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF2E7D32)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 4
                  : constraints.maxWidth >= 550
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              final cards = [
                _buildFinancialMetricTile(
                  title: 'Generated Water Fee',
                  urduSubtitle: 'Sum of the Water Fee column',
                  amount: _auditMoney(audit.waterFee),
                  bgColor: Colors.white,
                  borderColor: const Color(0xFFD1D5DB),
                  textColor: const Color(0xFF1F2937),
                  icon: Icons.receipt_long,
                  iconColor: const Color(0xFF4B5563),
                ),
                _buildFinancialMetricTile(
                  title: 'Amount Received (water)',
                  urduSubtitle:
                      'Cash receipts: ${_auditMoney(audit.cashReceived)}; advance applied: ${_auditMoney(audit.advanceApplied)}',
                  amount: _auditMoney(audit.waterReceived),
                  bgColor: const Color(0xFFF0FDF4),
                  borderColor: const Color(0xFF86EFAC),
                  textColor: const Color(0xFF15803D),
                  icon: Icons.check_circle_outline,
                  iconColor: const Color(0xFF16A34A),
                ),
                _buildFinancialMetricTile(
                  title: 'Fine Collected',
                  urduSubtitle: 'Collected fines excluded from water receipts',
                  amount: _auditMoney(audit.fineCollected),
                  bgColor: const Color(0xFFFFFBEB),
                  borderColor: const Color(0xFFFCD34D),
                  textColor: const Color(0xFF92400E),
                  icon: Icons.payments_outlined,
                  iconColor: const Color(0xFFD97706),
                ),
                _buildFinancialMetricTile(
                  title: 'Remaining Balance',
                  urduSubtitle:
                      '${remaining.bill == null ? '' : 'Bill ${remaining.bill!.billNo}: '}${remaining.basis}',
                  amount: _auditMoney(remaining.amount),
                  bgColor: hasPending
                      ? const Color(0xFFFEF2F2)
                      : const Color(0xFFF0FDF4),
                  borderColor: hasPending
                      ? const Color(0xFFFCA5A5)
                      : const Color(0xFF86EFAC),
                  textColor: hasPending
                      ? const Color(0xFFB91C1C)
                      : const Color(0xFF15803D),
                  icon: hasPending
                      ? Icons.warning_amber_rounded
                      : Icons.verified,
                  iconColor: hasPending
                      ? const Color(0xFFDC2626)
                      : const Color(0xFF16A34A),
                ),
              ];
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final card in cards) SizedBox(width: width, child: card),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          if (audit.coverage?.hasWarning ?? false) ...[
            Container(
              key: const ValueKey('billing-coverage-warning'),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                border: Border.all(color: const Color(0xFFFCA5A5)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                audit.coverage!.warningText(_auditMoney),
                style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const Text(
            'Remaining Balance uses the latest bill, including carried arrears and any applicable late fine. '
            'Older expired bills are not added again. Amount Received excludes identified collected fines and other charges. '
            'Advance-credit applications are not new cash receipts. '
            'Detailed reconciliation is available on the Water Fee Audit page.',
            style: TextStyle(fontSize: 11),
          ),
          if (audit.excludedBillNumbers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Older bills replaced by newer period bills (excluded from totals): ${audit.excludedBillNumbers.join(', ')}.',
              style: const TextStyle(fontSize: 11),
            ),
          ],
          if (audit.advanceBalance > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Unapplied receipts / advance credit: ${_auditMoney(audit.advanceBalance)}.',
              style: const TextStyle(fontSize: 11),
            ),
          ],
          if (audit.confirmedPaymentCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Confirmed sector payment exception: ${audit.confirmedPaymentCount} July-December 2023 bill(s); '
              '${_auditMoney(audit.confirmedPaymentAdjustment)} included in receipts.',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFinancialMetricTile({
    required String title,
    required String urduSubtitle,
    required String amount,
    required Color bgColor,
    required Color borderColor,
    required Color textColor,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4B5563),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: CopyableText(
              amount,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            urduSubtitle,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: textColor.withAlpha(215),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    String label,
    String value, {
    bool isBoldValue = false,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 170,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF374151),
            ),
          ),
        ),
        Expanded(
          child: CopyableText(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isBoldValue ? FontWeight.bold : FontWeight.w500,
              color: const Color(0xFF111827),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBillsTable() {
    final paginated = _paginatedBills;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Scrollbar(
        controller: _horizontalScrollCtrl,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _horizontalScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(
              const Color(0xFF2E7D32),
            ), // Dark Green header matching Image 2
            headingRowHeight: 38,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 40,
            columnSpacing: 14,
            horizontalMargin: 12,
            columns: const [
              DataColumn(
                label: Text(
                  'Sr #',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Bill No.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Bill Type',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Billing Period',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Arrears',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Water Fee',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Sanitation',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Drainage',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Biling Fee',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Total Bill',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Fine',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'After Due Date',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Due Date',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Status',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Amount Received',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DataColumn(
                label: Text(
                  'Receive Date',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            rows: paginated.asMap().entries.map((entry) {
              final idx = entry.key;
              final b = entry.value;
              final displaySrNo = (_currentPage - 1) * _pageSize + idx + 1;
              final isEven = idx % 2 == 0;
              final isPaid =
                  b.status.toLowerCase().contains('paid') &&
                  !b.status.toLowerCase().contains('un');
              final isUnpaid =
                  b.status.toLowerCase().contains('un-paid') ||
                  b.status.toLowerCase().contains('unpaid');

              return DataRow(
                color: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.hovered)) {
                    return isPaid
                        ? const Color(0xFFDCEDC8)
                        : const Color(0xFFF1F5F9);
                  }
                  if (isPaid) {
                    return const Color(
                      0xFFE8F5E9,
                    ); // Light green background for paid bill row
                  }
                  return isEven ? Colors.white : const Color(0xFFF9FAFB);
                }),
                cells: [
                  DataCell(
                    CopyableText(
                      '$displaySrNo',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.billNo,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.billType,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.billingPeriod,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.arrears,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.waterFee,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.sanitation,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.drainage,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.billingFee,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.totalBill,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(b.fine, style: const TextStyle(fontSize: 11)),
                  ),
                  // After Due Date in bold red (Matching Image 2)
                  DataCell(
                    CopyableText(
                      b.afterDueDate,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFD32F2F),
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.dueDate,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  // Status styled with green for Paid / red for Un-Paid
                  DataCell(
                    CopyableText(
                      b.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isPaid
                            ? const Color(0xFF2E7D32)
                            : (isUnpaid
                                  ? const Color(0xFFD32F2F)
                                  : Colors.amber.shade900),
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.amountReceived,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(
                    CopyableText(
                      b.receiveDate,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 48,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              'No bill history found for Connection No: "${_connCtrl.text.trim()}"',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Upload one or more Bill History CSV files to populate historical bills.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _pickAndImportFiles,
              icon: const Icon(Icons.file_upload, size: 16),
              label: const Text('Upload Bill CSV(s) Now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaginationFooter(int startItem, int endItem, int totalRecords) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Items per page
          const Text(
            'Items per page: ',
            style: TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
          ),
          DropdownButton<int>(
            value: _pageSize,
            underline: const SizedBox(),
            isDense: true,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF111827),
              fontWeight: FontWeight.w600,
            ),
            items: _pageSizeOptions.map((sz) {
              return DropdownMenuItem<int>(value: sz, child: Text('$sz'));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _pageSize = val;
                  _currentPage = 1;
                });
              }
            },
          ),
          const SizedBox(width: 24),

          // 1 - 1 of 1
          Text(
            '$startItem - $endItem of $totalRecords',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF4B5563),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 14),

          // First page button
          IconButton(
            icon: const Icon(Icons.first_page, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: _currentPage > 1
                ? const Color(0xFF4B5563)
                : Colors.grey.shade300,
            onPressed: _currentPage > 1
                ? () => setState(() => _currentPage = 1)
                : null,
          ),
          const SizedBox(width: 8),

          // Prev page button
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: _currentPage > 1
                ? const Color(0xFF4B5563)
                : Colors.grey.shade300,
            onPressed: _currentPage > 1
                ? () => setState(() => _currentPage--)
                : null,
          ),
          const SizedBox(width: 8),

          // Next page button
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: _currentPage < _totalPages
                ? const Color(0xFF4B5563)
                : Colors.grey.shade300,
            onPressed: _currentPage < _totalPages
                ? () => setState(() => _currentPage++)
                : null,
          ),
          const SizedBox(width: 8),

          // Last page button
          IconButton(
            icon: const Icon(Icons.last_page, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: _currentPage < _totalPages
                ? const Color(0xFF4B5563)
                : Colors.grey.shade300,
            onPressed: _currentPage < _totalPages
                ? () => setState(() => _currentPage = _totalPages)
                : null,
          ),
        ],
      ),
    );
  }
}
