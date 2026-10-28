import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:printing/printing.dart';
import '../services/bill_print_evidence.dart';
import '../services/database_service.dart';

class BillPrintArchiveDialog extends StatefulWidget {
  const BillPrintArchiveDialog({super.key, this.archive});
  final BillPrintEvidenceArchive? archive;
  @override
  State<BillPrintArchiveDialog> createState() => _BillPrintArchiveDialogState();
}

class _BillPrintArchiveDialogState extends State<BillPrintArchiveDialog> {
  BillPrintEvidenceArchive? _archive;
  bool _busy = true, _cancel = false, _importing = false;
  String _status = 'Opening archive…', _summary = '';
  List<Map<String, Object?>> _files = [];
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _run(() async {
      await pdfrxFlutterInitialize();
      _archive = widget.archive ?? await BillPrintEvidenceArchive.instance();
      await _stats();
    });
  }

  Future<void> _stats() async {
    final s = await _archive!.stats();
    _files = await _archive!.library.files();
    _summary =
        '${s.files} stored PDFs | ${s.pages} indexed pages | ${s.review} pages need identity/period review';
  }

  void _progress(String message) {
    if (mounted) setState(() => _status = message);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _status = '$e';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  Future<void> _import() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose original printed bill PDFs folder',
    );
    if (folder == null || !mounted) return;
    _cancel = false;
    _importing = true;
    await _run(() async {
      final r = await _archive!.importFolder(
        folder,
        progress: _progress,
        cancelled: () => _cancel,
      );
      await _stats();
      _status =
          '${r.cancelled ? 'Stopped. Completed files were kept. ' : ''}${r.imported} PDFs added; ${r.skipped} identical files skipped. '
          '${r.errors.isEmpty ? '' : '\nFiles needing attention:\n${r.errors.join('\n')}'}';
    });
  }

  Future<void> _backup() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose evidence backup destination',
    );
    if (folder == null || !mounted) return;
    await _run(() async {
      _progress('Backing up original PDFs and index…');
      _status = 'Backup saved: ${await _archive!.backup(folder)}';
    });
  }

  Future<void> _importFiles() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final paths = picked.map((file) => file.path).whereType<String>().toList();
    if (paths.isEmpty || !mounted) return;
    _cancel = false;
    _importing = true;
    await _run(() async {
      final result = await _archive!.importFiles(
        paths,
        progress: _progress,
        cancelled: () => _cancel,
      );
      await _stats();
      _status =
          '${result.imported} PDFs added; ${result.skipped} identical files skipped. '
          '${result.cancelled ? 'Stopped. Completed files were kept.' : ''}\n${result.errors.join('\n')}';
    });
  }

  Future<void> _delete(Map<String, Object?> file) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this archived PDF?'),
        content: SelectableText(
          '${file['name']}\n${file['pages']} pages\nSHA-256: ${file['digest']}\n\nThis removes this stored PDF and its search index from the archive. The original source folder and consumer history are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete PDF'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _run(() async {
      await _archive!.library.deleteFile('${file['id']}');
      await _stats();
      _status = 'Deleted archived PDF: ${file['name']}';
    });
  }

  Future<void> _restore() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select evidence backup folder',
    );
    if (folder == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this evidence archive?'),
        content: Text(
          'Replace the stored evidence archive with $folder? Consumer bill history and payments are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      _progress('Verifying and restoring PDFs…');
      await _archive!.restore(folder);
      await _stats();
      _status = 'Evidence archive restored.';
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Printed bill evidence archive'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import a folder of original bill-print PDFs. The PDFs are copied into the app and indexed by connection, bill number and printed billing period. Different versions are retained; identical files are skipped.',
              ),
              const SizedBox(height: 12),
              const Text(
                'This archive does not add charges, restore bill history or mark payments. A print proves the bill was printed; it does not establish payment or responsibility for a missing record.',
              ),
              const SizedBox(height: 12),
              Text(_summary),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              SelectableText(_status),
              if (_files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Stored PDFs',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (_, index) {
                      final file = _files[index];
                      return ListTile(
                        dense: true,
                        title: Text('${file['name']}'),
                        subtitle: Text(
                          '${file['pages']} pages | Archived ${file['imported']}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Delete archived PDF',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _busy ? null : () => _delete(file),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_importing && _busy)
          TextButton(
            onPressed: () => setState(() => _cancel = true),
            child: const Text('Stop import'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: _busy || _archive == null ? null : _backup,
          child: const Text('Backup archive'),
        ),
        TextButton(
          onPressed: _busy || _archive == null ? null : _restore,
          child: const Text('Restore backup'),
        ),
        FilledButton.icon(
          onPressed: _busy || _archive == null ? null : _importFiles,
          icon: const Icon(Icons.upload_file),
          label: const Text('Import PDF files'),
        ),
        FilledButton.icon(
          onPressed: _busy || _archive == null ? null : _import,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Import PDF folder'),
        ),
      ],
    ),
  );
}

class BillPrintEvidenceDialog extends StatefulWidget {
  const BillPrintEvidenceDialog({
    super.key,
    required this.connectionNo,
    required this.consumerName,
    this.from,
    this.to,
    this.database,
    this.archive,
  });
  final String connectionNo, consumerName;
  final DateTime? from, to;
  final DatabaseService? database;
  final BillPrintEvidenceArchive? archive;
  @override
  State<BillPrintEvidenceDialog> createState() =>
      _BillPrintEvidenceDialogState();
}

class _BillPrintEvidenceDialogState extends State<BillPrintEvidenceDialog> {
  BillPrintEvidenceArchive? _archive;
  List<Map<String, Object?>> _rows = [];
  Set<String> _historyBills = {};
  late bool _allPeriods = widget.from == null || widget.to == null;
  bool _busy = true, _outputBusy = false;
  int _selected = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await pdfrxFlutterInitialize();
      _archive ??= widget.archive ?? await BillPrintEvidenceArchive.instance();
      final rows = await _archive!.find(
        widget.connectionNo,
        from: _allPeriods ? null : widget.from,
        to: _allPeriods ? null : widget.to,
      );
      final history = await (widget.database ?? DatabaseService.instance)
          .getBillHistory(widget.connectionNo);
      _historyBills = history.map((b) => b.billNo.trim().toUpperCase()).toSet();
      if (rows.isNotEmpty) await _archive!.verify(rows.first);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selected = 0;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(int index) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _archive!.verify(_rows[index]);
      if (mounted) {
        setState(() {
          _selected = index;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _output(bool print) async {
    setState(() => _outputBusy = true);
    try {
      final row = _rows[_selected];
      await _archive!.verify(row);
      final bytes = await _archive!.library.exportPages([row]);
      final safe = '${widget.connectionNo}_${row['bill_no']}'.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '_',
      );
      if (print) {
        await Printing.layoutPdf(
          name: '$safe.pdf',
          onLayout: (_) async => bytes,
        );
      } else {
        await FilePicker.saveFile(
          fileName: '$safe.pdf',
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _outputBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = _rows.isEmpty ? null : _rows[_selected];
    final present =
        row != null &&
        _historyBills.contains('${row['bill_no']}'.trim().toUpperCase());
    return Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: SizedBox(
        width: 1400,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Printed bills: ${widget.connectionNo} — ${widget.consumerName}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextButton.icon(
                    onPressed: row == null || _busy || _outputBusy
                        ? null
                        : () => _output(true),
                    icon: const Icon(Icons.print),
                    label: const Text('Print bill'),
                  ),
                  TextButton.icon(
                    onPressed: row == null || _busy || _outputBusy
                        ? null
                        : () => _output(false),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save bill PDF'),
                  ),
                  IconButton(
                    onPressed: _outputBusy
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close PDF evidence',
                  ),
                ],
              ),
            ),
            if (widget.from != null && widget.to != null)
              CheckboxListTile(
                dense: true,
                title: const Text('Show all archived periods'),
                value: _allPeriods,
                onChanged: _busy || _outputBusy
                    ? null
                    : (v) {
                        _allPeriods = v!;
                        _load();
                      },
              ),
            if (_busy || _outputBusy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (!_busy && _error == null && row == null) ...[
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No archived printed bill matches this connection and period. Import the original bill folder, or show all archived periods.',
                ),
              ),
              TextButton(
                onPressed: () async {
                  await showDialog<void>(
                    context: context,
                    builder: (_) => BillPrintArchiveDialog(archive: _archive),
                  );
                  if (mounted) _load();
                },
                child: const Text('Open evidence archive'),
              ),
            ],
            if (!_busy && _error == null && row != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonFormField<int>(
                  key: ValueKey('${row['file_id']}:${row['page']}'),
                  initialValue: _selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Archived bill / printed period',
                  ),
                  items: [
                    for (var i = 0; i < _rows.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          'Bill ${_rows[i]['bill_no']} | ${_rows[i]['period_from'] ?? 'Unconfirmed period'} — ${_rows[i]['period_to'] ?? ''} | ${_rows[i]['name']} p.${_rows[i]['page']} | ${_rows[i]['copies']} stored copies',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _outputBusy
                      ? null
                      : (v) {
                          if (v != null) _select(v);
                        },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  '${present ? 'Bill number present in current history.' : 'Printed bill found; bill number ABSENT from current history.'}\n'
                  'Source: ${row['name']} | Original page: ${row['page']} | Archived: ${row['imported']}\n'
                  'SHA-256 of original stored PDF: ${row['digest']}\n'
                  'The original print is shown below. Its existence alone does not confirm payment or who removed a record.',
                  style: TextStyle(
                    color: present
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
              ),
              Expanded(
                child: PdfViewer.file(
                  _archive!.library.filePath('${row['file_id']}'),
                  key: ValueKey('${row['file_id']}:${row['page']}'),
                  initialPageNumber: row['page'] as int,
                ),
              ),
            ] else
              const Spacer(),
          ],
        ),
      ),
    );
  }
}
