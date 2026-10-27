import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../models/billing_audit_model.dart';
import '../models/audit_period_check.dart';
import '../services/export_service.dart';

class BillingAuditPdfDialog extends StatefulWidget {
  final List<BillingAuditEntry> entries;
  final String filterSummary;
  final Set<String>? initialColumnKeys;
  final Map<String, AuditPeriodCheck> periodChecks;
  final DateTime? periodFrom;
  final DateTime? periodTo;
  final String? selectedSector;
  final String? selectedLocality;
  const BillingAuditPdfDialog({
    super.key,
    required this.entries,
    required this.filterSummary,
    this.initialColumnKeys,
    this.periodChecks = const {},
    this.periodFrom,
    this.periodTo,
    this.selectedSector,
    this.selectedLocality,
  });

  @override
  State<BillingAuditPdfDialog> createState() => _BillingAuditPdfDialogState();
}

class _BillingAuditPdfDialogState extends State<BillingAuditPdfDialog> {
  final _columnScroll = ScrollController();
  late final _checks = widget.periodChecks.isNotEmpty
      ? widget.periodChecks
      : {
          for (final entry in widget.entries)
            entry.connectionNo: checkAuditPeriod(
              entry.periodBills,
              widget.periodFrom ?? DateTime(2023, 7, 1),
              widget.periodTo ?? auditBillingSessions(DateTime.now()).last.end,
            ),
        };
  late final _selected = Set<String>.of({
    ...?widget.initialColumnKeys,
    if (widget.initialColumnKeys == null)
      ...ExportService.defaultBillingAuditPdfColumns,
  });
  List<BillingAuditColumn> get _columns => [
    ...ExportService.billingAuditColumns,
    ...ExportService.auditPeriodColumns(_checks),
  ];
  bool _busy = false;
  @override
  void dispose() {
    _columnScroll.dispose();
    super.dispose();
  }

  Future<void> _export({bool print = false}) async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: widget.entries,
        selectedColumnKeys: _selected,
        filterSummary: widget.filterSummary,
        selectedSector: widget.selectedSector,
        periodChecks: _checks,
        periodFrom: widget.periodFrom,
        periodTo: widget.periodTo,
      );
      final name = ExportService.billingAuditPdfFileName(
        widget.entries,
        selectedSector: widget.selectedSector,
        selectedLocality: widget.selectedLocality,
      );
      final bool completed;
      if (print) {
        completed = await Printing.layoutPdf(
          onLayout: (_) => bytes,
          name: name,
        );
      } else {
        completed =
            await FilePicker.saveFile(
              fileName: name,
              bytes: bytes,
              dialogTitle: 'Save water fee audit PDF',
              type: FileType.custom,
              allowedExtensions: ['pdf'],
            ) !=
            null;
      }
      if (completed && mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 96).clamp(320.0, 1080.0).toDouble();
    final height = (size.height - 180).clamp(240.0, 680.0).toDouble();
    final columns = (width ~/ 260).clamp(2, 4);
    final tileWidth = (width - (columns - 1) * 8) / columns;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Audit PDF - choose columns'),
        content: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Export all ${widget.entries.length} filtered connections in the current sort order.',
              ),
              const SizedBox(height: 8),
              Text(
                'All ${_columns.length} report columns are available below.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _selected.addAll(_columns.map((c) => c.key)),
                          ),
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => setState(_selected.clear),
                    child: const Text('Clear all'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _selected.clear();
                            _selected.addAll(
                              ExportService.defaultBillingAuditPdfColumns,
                            );
                          }),
                    child: const Text('Reset defaults'),
                  ),
                ],
              ),
              Expanded(
                child: Scrollbar(
                  controller: _columnScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _columnScroll,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final column in _columns)
                          SizedBox(
                            width: tileWidth,
                            child: CheckboxListTile(
                              title: Text(column.label),
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _selected.contains(column.key),
                              onChanged: _busy
                                  ? null
                                  : (checked) => setState(() {
                                      if (checked == true) {
                                        _selected.add(column.key);
                                      } else {
                                        _selected.remove(column.key);
                                      }
                                    }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Text('${_selected.length} columns selected'),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            onPressed: _busy || _selected.isEmpty
                ? null
                : () => _export(print: true),
            icon: const Icon(Icons.print),
            label: const Text('Preview / print'),
          ),
          ElevatedButton.icon(
            onPressed: _busy || _selected.isEmpty ? null : () => _export(),
            icon: const Icon(Icons.save_alt),
            label: const Text('Save PDF'),
          ),
        ],
      ),
    );
  }
}
