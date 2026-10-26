import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:printing/printing.dart';

import '../services/database_service.dart';
import '../services/pdf_bill_library.dart';
import '../theme/app_theme.dart';
import '../widgets/searchable_select_field.dart';

class PdfBillsScreen extends StatefulWidget {
  const PdfBillsScreen({super.key});
  @override
  State<PdfBillsScreen> createState() => _PdfBillsScreenState();
}

class _PdfBillsScreenState extends State<PdfBillsScreen> {
  PdfBillLibrary? _library;
  final _query = TextEditingController();
  final _selected = <String, Map<String, Object?>>{};
  Timer? _debounce;
  List<Map<String, Object?>> _files = [], _mappings = [], _rows = [];
  List<String> _rates = [], _connectionStatuses = [];
  String _sector = '', _locality = '', _file = '', _searchBy = 'all';
  String _consumerStatus = '',
      _connectionStatus = '',
      _billStatus = '',
      _rate = '';
  bool _busy = false, _searching = false, _cancel = false, _importing = false;
  String _progress = 'Opening PDF bill library…';
  int _total = 0, _offset = 0, _searchVersion = 0;
  static const _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _run(() async {
      await pdfrxFlutterInitialize();
      _library = await PdfBillLibrary.instance();
      await _library!.attachConsumers(
        (await DatabaseService.instance.database).path,
      );
      _connectionStatuses = await DatabaseService.instance
          .getConnectionStatuses();
      await _reload();
    });
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 7)),
      );
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool cancellable = false,
  }) async {
    if (!mounted || _busy) return;
    _debounce?.cancel();
    ++_searchVersion;
    setState(() {
      _busy = true;
      _cancel = false;
      _importing = cancellable;
    });
    try {
      await action();
    } catch (e) {
      _message('$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _searching = false;
          _progress = '';
          _importing = false;
        });
      }
    }
  }

  void _setProgress(String value) {
    if (mounted) setState(() => _progress = value);
  }

  Future<void> _reload() async {
    _files = await _library!.files();
    _mappings = [
      ...await _library!.localities(),
      ...await _library!.db.rawQuery(
        'SELECT DISTINCT pdf_locality AS locality, pdf_sector AS sector FROM pages',
      ),
    ];
    _rates = (await _library!.db.rawQuery(
      "SELECT DISTINCT rate_type FROM pages WHERE rate_type <> '' ORDER BY rate_type",
    )).map((r) => '${r['rate_type']}').toList();
    if (!_files.any((f) => f['id'] == _file)) _file = '';
    _selected.clear();
    await _search(reset: true);
  }

  Future<void> _search({bool reset = false}) async {
    if (_library == null) return;
    if (reset) _offset = 0;
    final version = ++_searchVersion;
    if (mounted) setState(() => _searching = true);
    try {
      final result = await _library!.search(
        query: _query.text,
        locality: _locality,
        sector: _sector,
        fileId: _file,
        offset: _offset,
        searchBy: _searchBy,
        consumerStatus: _consumerStatus,
        connectionStatus: _connectionStatus,
        billStatus: _billStatus,
        rateType: _rate,
      );
      if (mounted && version == _searchVersion) {
        setState(() {
          _rows = result.rows;
          _total = result.total;
          _searching = false;
        });
      }
    } catch (e) {
      if (version == _searchVersion) {
        _message('Search failed: $e');
        if (mounted) setState(() => _searching = false);
      }
    }
  }

  void _filter(void Function() change) {
    setState(() {
      change();
      _selected.clear();
    });
    _search(reset: true);
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _import({
    bool folder = false,
    bool replaceAll = false,
    String? replaceId,
  }) async {
    List<String> paths;
    String? csvPath;
    if (folder) {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose the bill PDFs folder',
      );
      if (directory == null) return;
      final entries = await Directory(directory).list().toList();
      paths =
          entries
              .whereType<File>()
              .where((f) => p.extension(f.path).toLowerCase() == '.pdf')
              .map((f) => f.path)
              .toList()
            ..sort();
      if (paths.any((f) => p.basename(f).toLowerCase() != 'all bills.pdf')) {
        paths.removeWhere(
          (f) => p.basename(f).toLowerCase() == 'all bills.pdf',
        );
      }
      csvPath = entries
          .whereType<File>()
          .where((f) => p.basename(f.path).toLowerCase() == 'localities.csv')
          .firstOrNull
          ?.path;
    } else {
      if (replaceId != null) {
        final picked = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (picked?.path == null) return;
        paths = [picked!.path!];
      } else {
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (picked.isEmpty) return;
        paths = picked.map((f) => f.path).whereType<String>().toList();
      }
    }
    if (!mounted || paths.isEmpty) {
      _message('No PDFs found in this folder.');
      return;
    }
    if (!await _confirm(
      replaceAll ? 'Replace the PDF library?' : 'Import PDF bills?',
      '${paths.length} PDF file(s) will be copied and indexed.${csvPath != null ? '\nLocalities.csv will map locality and sector names.' : ''}\n${replaceAll
          ? 'All existing PDF bills will be replaced after successful indexing. Create a backup first if you need them.'
          : replaceId != null
          ? 'The selected file will be replaced after successful indexing.'
          : 'Existing files with the same filename will be updated. Other files will be kept.'}\nLarge PDFs can take several minutes.',
    )) {
      return;
    }
    await _run(() async {
      final result = await _library!.importPdfs(
        paths,
        replaceAll: replaceAll,
        replaceId: replaceId,
        csvPath: csvPath,
        progress: _setProgress,
        cancelled: () => _cancel,
      );
      await _reload();
      _message(
        '${result.imported} PDF file(s) imported; ${result.skipped} identical file(s) skipped.',
      );
    }, cancellable: true);
  }

  Future<void> _csv() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    final path = result?.path;
    if (path == null) return;
    await _run(() async {
      await _library!.importLocalities(path);
      await _reload();
      _message('Locality mappings updated.');
    });
  }

  Future<void> _backup() async {
    final destination = await FilePicker.getDirectoryPath(
      dialogTitle: 'Save PDF Bills backup inside this folder',
    );
    if (destination == null) return;
    await _run(() async {
      _setProgress('Copying PDFs and search index to backup…');
      final path = await _library!.backup(destination);
      _message('Complete PDF backup saved: $path');
    });
  }

  Future<void> _restore() async {
    final source = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select a PDF-Bills-Backup folder',
    );
    if (source == null || !mounted) return;
    if (!await _confirm(
      'Restore PDF Bills backup?',
      'This replaces the current PDF library and its locality list. Consumer and audit data stay unchanged. Keep a backup of your current PDFs if needed.',
    )) {
      return;
    }
    await _run(() async {
      await _library!.restore(source, progress: _setProgress);
      _resetFilters();
      await _reload();
      _message('PDF Bills backup restored.');
    });
  }

  void _resetFilters() {
    _sector = _locality = _file = _consumerStatus = _connectionStatus =
        _billStatus = _rate = '';
    _searchBy = 'all';
    _query.clear();
    _selected.clear();
  }

  Future<void> _output(
    List<Map<String, Object?>> rows, {
    bool print = false,
    bool filtered = false,
  }) async {
    if (rows.isEmpty && !filtered) {
      _message('Select bill pages first.');
      return;
    }
    await _run(() async {
      if (filtered) {
        rows = (await _library!.search(
          query: _query.text,
          locality: _locality,
          sector: _sector,
          fileId: _file,
          searchBy: _searchBy,
          consumerStatus: _consumerStatus,
          connectionStatus: _connectionStatus,
          billStatus: _billStatus,
          rateType: _rate,
          limit: -1,
        )).rows;
      }
      if (rows.isEmpty) {
        _message('No matching bill pages.');
        return;
      }
      _setProgress('Preparing ${rows.length} original bill page(s)…');
      final bytes = await _library!.exportPages(rows);
      if (print) {
        await Printing.layoutPdf(
          name: 'Bill Prints',
          onLayout: (_) async => bytes,
        );
      } else {
        final path = await FilePicker.saveFile(
          dialogTitle: 'Save bill pages',
          fileName: 'Bill-Prints.pdf',
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (path != null) {
          _message('Bill pages saved: $path');
        }
      }
    });
  }

  Future<void> _preview(Map<String, Object?> row) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: SizedBox(
          width: 1050,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${row['name']} — page ${row['page']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _output([row], print: true),
                      icon: const Icon(Icons.print),
                      label: const Text('Print this bill'),
                    ),
                    TextButton.icon(
                      onPressed: () => _output([row]),
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save this bill'),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                      tooltip: 'Close preview',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfViewer.file(
                  _library!.filePath('${row['file_id']}'),
                  initialPageNumber: row['page'] as int,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(Map<String, Object?> file) async {
    final locality = TextEditingController(text: '${file['locality']}');
    final sector = TextEditingController(text: '${file['sector']}');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${file['name']}'),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: locality,
                decoration: const InputDecoration(labelText: 'Locality'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: sector,
                decoration: const InputDecoration(labelText: 'Sector'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _run(() async {
        await _library!.updateMetadata(
          '${file['id']}',
          locality.text,
          sector.text,
        );
        await _reload();
      });
    }
    // Dialog routes retain controllers during their closing transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    locality.dispose();
    sector.dispose();
  }

  Future<void> _manage() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AlertDialog(
          title: const Text('Manage PDF files'),
          content: SizedBox(
            width: 850,
            height: 500,
            child: _files.isEmpty
                ? const Center(child: Text('No PDFs imported yet.'))
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      return ListTile(
                        title: Text('${f['name']}'),
                        subtitle: Text(
                          '${f['locality']} • ${f['sector']} • ${f['pages']} pages${f['unsearchable'] != 0 ? ' • ${f['unsearchable']} pages without searchable text' : ''}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit locality / sector',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await _edit(f);
                                      if (ctx.mounted) refresh(() {});
                                    },
                            ),
                            IconButton(
                              tooltip: 'Replace PDF',
                              icon: const Icon(Icons.upload_file),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await _import(replaceId: '${f['id']}');
                                      if (ctx.mounted) refresh(() {});
                                    },
                            ),
                            IconButton(
                              tooltip: 'Delete PDF',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      if (await _confirm(
                                        'Delete PDF?',
                                        'Remove ${f['name']} and its searchable pages from this library? The original upload is kept.',
                                      )) {
                                        await _run(() async {
                                          await _library!.deleteFile(
                                            '${f['id']}',
                                          );
                                          await _reload();
                                        });
                                        if (ctx.mounted) refresh(() {});
                                      }
                                    },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(String label, IconData icon, VoidCallback action) =>
      OutlinedButton.icon(
        onPressed: _busy || _library == null ? null : action,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
  Widget _select(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> change,
  ) => SearchableSelectField(
    label: label,
    value: value.isEmpty ? 'All $label' : value,
    allItemLabel: 'All $label',
    items: [
      'All $label',
      ...values.toSet().where((s) => s.isNotEmpty).toList()..sort(),
    ],
    width: 220,
    onChanged: (v) => _filter(() => change(v == 'All $label' ? '' : v)),
  );

  @override
  Widget build(BuildContext context) {
    final sectors = [
      ..._files,
      ..._mappings,
    ].map((f) => '${f['sector']}').toList();
    final localities = [..._files, ..._mappings]
        .where((f) => _sector.isEmpty || f['sector'] == _sector)
        .map((f) => '${f['locality']}')
        .toList();
    final blank = _files.fold<int>(0, (n, f) => n + (f['unsearchable'] as int));
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: AppTheme.primaryGreen,
          foregroundColor: Colors.white,
          title: const Text('PDF Bills'),
          actions: [
            IconButton(
              tooltip: 'Refresh library',
              onPressed: _busy ? null : () => _run(_reload),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button('Upload PDFs', Icons.upload_file, () => _import()),
                  _button(
                    'Import Folder + CSV',
                    Icons.drive_folder_upload,
                    () => _import(folder: true),
                  ),
                  _button('Localities CSV', Icons.table_view, _csv),
                  _button(
                    'Manage Files (${_files.length})',
                    Icons.folder_open,
                    _manage,
                  ),
                  _button(
                    'Replace All',
                    Icons.sync,
                    () => _import(replaceAll: true, folder: true),
                  ),
                  _button('Backup', Icons.backup_outlined, _backup),
                  _button('Restore Backup', Icons.restore, _restore),
                  _button('Delete All', Icons.delete_forever, () async {
                    if (await _confirm(
                      'Delete all PDF bills?',
                      'This removes all imported PDFs, their index and locality mappings. Create a PDF backup first if you need these bills later. Consumer and audit data stay unchanged.',
                    )) {
                      await _run(() async {
                        await _library!.clear();
                        _resetFilters();
                        await _reload();
                      });
                    }
                  }),
                ],
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _progress.isEmpty ? 'Working…' : _progress,
                          ),
                        ),
                        if (_importing)
                          TextButton(
                            onPressed: () => setState(() => _cancel = true),
                            child: Text(
                              _cancel ? 'Cancelling…' : 'Cancel import',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing: _busy,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 12,
                        children: [
                          _select('Sectors', _sector, sectors, (v) {
                            _sector = v;
                            _locality = '';
                          }),
                          _select(
                            'Localities',
                            _locality,
                            localities,
                            (v) => _locality = v,
                          ),
                          _select(
                            'Consumer Statuses',
                            _consumerStatus,
                            ['Active', 'In-Active'],
                            (v) => _consumerStatus = v,
                          ),
                          _select(
                            'Connection Statuses',
                            _connectionStatus,
                            _connectionStatuses,
                            (v) => _connectionStatus = v,
                          ),
                          _select('Bill Statuses', _billStatus, [
                            'Paid',
                            'Un-Paid',
                            'Expired',
                          ], (v) => _billStatus = v),
                          _select(
                            'Rate Types',
                            _rate,
                            _rates,
                            (v) => _rate = v,
                          ),
                          SizedBox(
                            width: 280,
                            child: DropdownButtonFormField<String>(
                              initialValue: _file,
                              key: ValueKey('file:$_file:${_files.length}'),
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'PDF file',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('All Files'),
                                ),
                                ..._files.map(
                                  (f) => DropdownMenuItem(
                                    value: '${f['id']}',
                                    child: Text(
                                      '${f['name']}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: (v) => _filter(() => _file = v ?? ''),
                            ),
                          ),
                          _button(
                            'Reset Filters',
                            Icons.filter_alt_off,
                            () => _filter(_resetFilters),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Status filters use current consumer-register values matched by connection number. All statuses includes unmatched PDFs.',
                        ),
                      ),
                    ),
                    if (blank > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '$blank page(s) have no searchable text. Browse by locality/file and preview them; scanned pages need OCR for text search.',
                          style: const TextStyle(color: Colors.deepOrange),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 200,
                            child: DropdownButtonFormField<String>(
                              initialValue: _searchBy,
                              key: ValueKey(_searchBy),
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Search By',
                              ),
                              items:
                                  const {
                                        'all': 'All Fields',
                                        'consumer_name': 'Consumer Name',
                                        'father_name': 'Father / Husband',
                                        'connection_no': 'Connection No',
                                        'old_connection_no':
                                            'Old Connection No',
                                        'bill_no': 'Bill No',
                                        'reference': 'Reference No',
                                        'mobile': 'Mobile',
                                        'address': 'Address',
                                      }.entries
                                      .map(
                                        (e) => DropdownMenuItem(
                                          value: e.key,
                                          child: Text(e.value),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (v) =>
                                  _filter(() => _searchBy = v ?? 'all'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _query,
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                labelText: 'Search bill PDFs',
                                hintText:
                                    'Name, connection, bill or reference number — words in any order',
                                suffixIcon: Icon(Icons.text_fields),
                              ),
                              onChanged: (_) {
                                _selected.clear();
                                _debounce?.cancel();
                                _debounce = Timer(
                                  const Duration(milliseconds: 300),
                                  () => _search(reset: true),
                                );
                              },
                              onSubmitted: (_) => _search(reset: true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '$_total bill pages • ${_selected.length} selected',
                          ),
                          _button(
                            'Print Selected',
                            Icons.print,
                            () =>
                                _output(_selected.values.toList(), print: true),
                          ),
                          _button(
                            'Save Selected PDF',
                            Icons.picture_as_pdf,
                            () => _output(_selected.values.toList()),
                          ),
                          _button(
                            'Print All Filtered',
                            Icons.local_printshop_outlined,
                            () => _output([], print: true, filtered: true),
                          ),
                          _button(
                            'Save All Filtered',
                            Icons.download_outlined,
                            () => _output([], filtered: true),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _selected.clear()),
                            child: const Text('Clear selection'),
                          ),
                        ],
                      ),
                    ),
                    if (_searching) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: _rows.isEmpty
                          ? Center(
                              child: Text(
                                _files.isEmpty
                                    ? 'Import a bill folder or upload PDFs to start searching.'
                                    : 'No bill pages match these filters.',
                              ),
                            )
                          : ListView.builder(
                              itemCount: _rows.length,
                              itemBuilder: (_, i) {
                                final row = _rows[i];
                                final key = '${row['file_id']}:${row['page']}';
                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 3,
                                  ),
                                  child: ListTile(
                                    leading: Checkbox(
                                      value: _selected.containsKey(key),
                                      onChanged: (v) => setState(() {
                                        if (v == true) {
                                          _selected[key] = row;
                                        } else {
                                          _selected.remove(key);
                                        }
                                      }),
                                    ),
                                    title: Text(
                                      '${row['consumer_name'] == '' ? row['name'] : row['consumer_name']}  •  Connection ${row['connection_no']}  •  Bill ${row['bill_no']}',
                                    ),
                                    subtitle: Text(
                                      '${row['locality']} • ${row['sector']}\n${row['name']} — page ${row['page']}  |  ${row['address']}',
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _preview(row),
                                    trailing: Wrap(
                                      children: [
                                        IconButton(
                                          tooltip: 'Preview bill',
                                          onPressed: () => _preview(row),
                                          icon: const Icon(
                                            Icons.visibility_outlined,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Print this bill page',
                                          onPressed: () =>
                                              _output([row], print: true),
                                          icon: const Icon(
                                            Icons.print_outlined,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Checkbox(
                            value:
                                _rows.isNotEmpty &&
                                _rows.every(
                                  (r) => _selected.containsKey(
                                    '${r['file_id']}:${r['page']}',
                                  ),
                                ),
                            onChanged: _rows.isEmpty
                                ? null
                                : (v) => setState(() {
                                    for (final row in _rows) {
                                      final key =
                                          '${row['file_id']}:${row['page']}';
                                      if (v == true) {
                                        _selected[key] = row;
                                      } else {
                                        _selected.remove(key);
                                      }
                                    }
                                  }),
                          ),
                          const Text('Select this page'),
                          const SizedBox(width: 24),
                          IconButton(
                            tooltip: 'Previous page',
                            onPressed: _offset == 0 || _searching
                                ? null
                                : () {
                                    _offset -= _pageSize;
                                    _search();
                                  },
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text(
                            '${_total == 0 ? 0 : _offset + 1}–${(_offset + _rows.length)} of $_total',
                          ),
                          IconButton(
                            tooltip: 'Next page',
                            onPressed:
                                _offset + _pageSize >= _total || _searching
                                ? null
                                : () {
                                    _offset += _pageSize;
                                    _search();
                                  },
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
