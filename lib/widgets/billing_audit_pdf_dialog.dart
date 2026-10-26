import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import '../models/billing_audit_model.dart';
import '../services/export_service.dart';

class BillingAuditPdfDialog extends StatefulWidget {
  final List<BillingAuditEntry> entries;
  final String filterSummary;
  final Set<String>? initialColumnKeys;
  const BillingAuditPdfDialog({
    super.key,
    required this.entries,
    required this.filterSummary,
    this.initialColumnKeys,
  });

  @override
  State<BillingAuditPdfDialog> createState() => _BillingAuditPdfDialogState();
}

class _BillingAuditPdfDialogState extends State<BillingAuditPdfDialog> {
  late final _selected = Set<String>.of(
    widget.initialColumnKeys ?? ExportService.defaultBillingAuditPdfColumns,
  );
  bool _busy = false;

  Future<void> _export({bool print = false}) async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await ExportService.instance.generateBillingAuditPdf(
        entries: widget.entries,
        selectedColumnKeys: _selected,
        filterSummary: widget.filterSummary,
      );
      final name =
          'Water_Fee_Audit_${DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now())}.pdf';
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
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Audit PDF - choose columns'),
      content: SizedBox(
        width: 700,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Export all ${widget.entries.length} filtered connections in the current sort order.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(
                          () => _selected.addAll(
                            ExportService.billingAuditColumns.map((c) => c.key),
                          ),
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
              child: SingleChildScrollView(
                child: Wrap(
                  children: [
                    for (final column in ExportService.billingAuditColumns)
                      SizedBox(
                        width: 330,
                        child: CheckboxListTile(
                          title: Text(column.label),
                          dense: true,
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
