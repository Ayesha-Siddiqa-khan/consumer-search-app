import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import '../models/consumer_model.dart';
import '../services/database_service.dart';
import '../services/export_service.dart';
import '../theme/app_theme.dart';

class PdfExportDialog extends StatefulWidget {
  final List<Consumer> currentConsumers;
  final int totalFilteredCount;
  final String? filterSummary;
  final String? searchQuery;
  final String? searchBy;
  final String? sector;
  final String? locality;
  final String? consumerStatus;
  final String? connectionStatus;
  final String? rateType;
  final String? billStatus;
  final Set<String>? initialSelectedColumnKeys;

  const PdfExportDialog({
    super.key,
    required this.currentConsumers,
    required this.totalFilteredCount,
    this.filterSummary,
    this.searchQuery,
    this.searchBy,
    this.sector,
    this.locality,
    this.consumerStatus,
    this.connectionStatus,
    this.rateType,
    this.billStatus,
    this.initialSelectedColumnKeys,
  });

  static void show({
    required BuildContext context,
    required List<Consumer> currentConsumers,
    required int totalFilteredCount,
    String? filterSummary,
    String? searchQuery,
    String? searchBy,
    String? sector,
    String? locality,
    String? consumerStatus,
    String? connectionStatus,
    String? rateType,
    String? billStatus,
    Set<String>? initialSelectedColumnKeys,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => PdfExportDialog(
        currentConsumers: currentConsumers,
        totalFilteredCount: totalFilteredCount,
        filterSummary: filterSummary,
        searchQuery: searchQuery,
        searchBy: searchBy,
        sector: sector,
        locality: locality,
        consumerStatus: consumerStatus,
        connectionStatus: connectionStatus,
        rateType: rateType,
        billStatus: billStatus,
        initialSelectedColumnKeys: initialSelectedColumnKeys,
      ),
    );
  }

  @override
  State<PdfExportDialog> createState() => _PdfExportDialogState();
}

class _PdfExportDialogState extends State<PdfExportDialog> {
  late Set<String> _selectedKeys;
  bool _exportAllFiltered = false;
  bool _isGenerating = false;
  String _generationStatus = '';

  @override
  void initState() {
    super.initState();
    // Default to passed keys or default 9 PDF columns
    if (widget.initialSelectedColumnKeys != null && widget.initialSelectedColumnKeys!.isNotEmpty) {
      _selectedKeys = Set<String>.from(widget.initialSelectedColumnKeys!);
    } else {
      _selectedKeys = Set<String>.from(ExportService.defaultPdfColumnKeys);
    }
  }

  void _selectAll() {
    setState(() {
      _selectedKeys = ExportService.availableColumns.map((c) => c.key).toSet();
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedKeys.clear();
    });
  }

  Future<List<Consumer>> _getConsumersToExport() async {
    if (_exportAllFiltered) {
      setState(() => _generationStatus = 'Fetching all ${widget.totalFilteredCount} records from database...');
      // Fetch all records without artificial cap!
      final fetchLimit = widget.totalFilteredCount > 0 ? widget.totalFilteredCount : 50000;
      final res = await DatabaseService.instance.searchConsumers(
        query: widget.searchQuery,
        searchBy: widget.searchBy,
        sector: widget.sector,
        locality: widget.locality,
        consumerStatus: widget.consumerStatus,
        connectionStatus: widget.connectionStatus,
        rateType: widget.rateType,
        billStatus: widget.billStatus,
        page: 1,
        pageSize: fetchLimit,
      );
      return res.items;
    }
    return widget.currentConsumers;
  }

  Future<void> _previewAndPrint() async {
    if (_selectedKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one column to export.')),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _generationStatus = 'Preparing records for PDF...';
    });

    final consumers = await _getConsumersToExport();
    setState(() => _generationStatus = 'Generating PDF for ${consumers.length} consumers...');

    final pdfBytes = await ExportService.instance.generateConsumerPdf(
      consumers: consumers,
      selectedColumnKeys: _selectedKeys,
      sector: widget.sector,
      billStatus: widget.billStatus,
      filterSummary: widget.filterSummary,
    );

    setState(() => _isGenerating = false);

    if (mounted) {
      Navigator.of(context).pop();
      await Printing.layoutPdf(
        onLayout: (_) => pdfBytes,
        name: 'Consumer_Report_${DateFormat('dd-MM-yyyy').format(DateTime.now())}.pdf',
      );
    }
  }

  Future<void> _downloadPdf() async {
    if (_selectedKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one column to export.')),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _generationStatus = 'Preparing records for PDF...';
    });

    final consumers = await _getConsumersToExport();
    setState(() => _generationStatus = 'Rendering PDF pages for ${consumers.length} consumers...');

    final pdfBytes = await ExportService.instance.generateConsumerPdf(
      consumers: consumers,
      selectedColumnKeys: _selectedKeys,
      sector: widget.sector,
      billStatus: widget.billStatus,
      filterSummary: widget.filterSummary,
    );

    setState(() => _isGenerating = false);

    final defaultName = 'Consumer_Report_${DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now())}.pdf';

    final saveUri = await FilePicker.saveFile(
      fileName: defaultName,
      bytes: pdfBytes,
      dialogTitle: 'Save Consumer PDF Report',
      allowedExtensions: ['pdf'],
      type: FileType.custom,
    );

    if (mounted) {
      Navigator.of(context).pop();
      if (saveUri != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF saved successfully! ($saveUri)'),
            backgroundColor: AppTheme.primaryGreen,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: AppTheme.primaryGreen,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.picture_as_pdf, color: Colors.white, size: 24),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Export to PDF - Column Selection',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Select columns to include in the PDF report',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Controls Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Text(
                    '${_selectedKeys.length} of ${ExportService.availableColumns.length} columns selected',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.select_all, size: 16),
                    label: const Text('Select All', style: TextStyle(fontSize: 12)),
                    onPressed: _selectAll,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.deselect, size: 16),
                    label: const Text('Deselect All', style: TextStyle(fontSize: 12)),
                    onPressed: _deselectAll,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Columns Grid (Checkboxes)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: ExportService.availableColumns.map((col) {
                        final isChecked = _selectedKeys.contains(col.key);
                        return FilterChip(
                          avatar: Icon(
                            isChecked ? Icons.check_circle : Icons.circle_outlined,
                            size: 16,
                            color: isChecked ? AppTheme.primaryGreen : Colors.grey,
                          ),
                          label: Text(col.label),
                          selected: isChecked,
                          selectedColor: AppTheme.primaryGreen.withAlpha(25),
                          checkmarkColor: AppTheme.primaryGreen,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedKeys.add(col.key);
                              } else {
                                _selectedKeys.remove(col.key);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    // Export Scope Option
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Export Scope',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<bool>(
                              segments: [
                                ButtonSegment<bool>(
                                  value: false,
                                  icon: const Icon(Icons.description, size: 16),
                                  label: Text('Current Page (${widget.currentConsumers.length} records)'),
                                ),
                                ButtonSegment<bool>(
                                  value: true,
                                  icon: const Icon(Icons.library_books, size: 16),
                                  label: Text('All Records (${widget.totalFilteredCount})'),
                                ),
                              ],
                              selected: {_exportAllFiltered},
                              onSelectionChanged: (newSelection) {
                                setState(() {
                                  _exportAllFiltered = newSelection.first;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_isGenerating) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryGreen.withAlpha(15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.primaryGreen.withAlpha(60)),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryGreen),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _generationStatus,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.darkGreen),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Footer with Actions
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFFF9FAFB),
                border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _isGenerating ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade800),
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.print, size: 16),
                    label: const Text('Preview & Print'),
                    onPressed: _isGenerating ? null : _previewAndPrint,
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: const Text('Download PDF'),
                    onPressed: _isGenerating ? null : _downloadPdf,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
