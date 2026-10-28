import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/bill_amount.dart';
import 'pdf_bill_library.dart';

/// Only the printed Billing Period is evidence; issue, due and history dates
/// must never be substituted for an unrecognized period.
Map<String, Object?> parsePrintedBillEvidence(String text) {
  String date(int y, int m, int d) =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
  String? parsed(String raw) {
    final values = raw.split(RegExp(r'[/\-]')).map(int.parse).toList();
    final result = DateTime.utc(values[2], values[1], values[0]);
    return result.year == values[2] &&
            result.month == values[1] &&
            result.day == values[0]
        ? date(result.year, result.month, result.day)
        : null;
  }

  final match = RegExp(
    r'Billing\s*Period\s*:?\s*(\d{1,2}[/\-]\d{1,2}[/\-]\d{4})\s*(?:TO|[-–])\s*(\d{1,2}[/\-]\d{1,2}[/\-]\d{4})',
    caseSensitive: false,
  ).firstMatch(text);
  String? from = match == null ? null : parsed(match[1]!);
  String? to = match == null ? null : parsed(match[2]!);
  if (from == null || to == null) {
    final months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ];
    final short = RegExp(
      r'Billing\s*Period\s*:?\s*([A-Za-z]{3})\s+(\d{4}|\d{2})\s*[-–]\s*([A-Za-z]{3})\s+(\d{4}|\d{2})',
      caseSensitive: false,
    ).firstMatch(text);
    if (short != null) {
      final m1 = months.indexOf(short[1]!.toLowerCase()) + 1;
      final m2 = months.indexOf(short[3]!.toLowerCase()) + 1;
      int year(String s) => int.parse(s) + (s.length == 2 ? 2000 : 0);
      if (m1 > 0 && m2 > 0) {
        from = date(year(short[2]!), m1, 1);
        to = date(
          year(short[4]!),
          m2,
          DateTime.utc(year(short[4]!), m2 + 1, 0).day,
        );
      }
    }
  }
  if (from != null && to != null && from.compareTo(to) > 0) {
    from = null;
    to = null;
  }
  int? amount(String label) {
    final value = RegExp(
      '(?:^|[\\r\\n])$label\\s*(?:Rs\\.?\\s*)?([\\d,]+(?:\\.\\d{1,2})?)',
      caseSensitive: false,
    ).firstMatch(text);
    return value == null ? null : auditAmountInPaisa(value[1]);
  }

  return {
    'period_from': from,
    'period_to': to,
    'printed_water_fee': amount('Water Fee'),
    'printed_arrears': amount('Arrears'),
    'printed_payable': amount('PAYABLE WITHIN DUE DATE'),
  };
}

class BillPrintEvidenceArchive {
  BillPrintEvidenceArchive(this.library);
  final PdfBillLibrary library;
  static Future<BillPrintEvidenceArchive>? _instance;
  static Future<BillPrintEvidenceArchive> instance() => _instance ??= () async {
    final root = await getApplicationSupportDirectory();
    final archive = BillPrintEvidenceArchive(
      PdfBillLibrary(Directory(p.join(root.path, 'bill_print_evidence'))),
    );
    await archive.open();
    return archive;
  }();
  bool _importing = false;
  Future<void> open() async {
    await library.open();
    await library.db.execute(
      'CREATE TABLE IF NOT EXISTS evidence (file_id TEXT NOT NULL, page INTEGER NOT NULL, period_from TEXT, period_to TEXT, printed_water_fee INTEGER, printed_arrears INTEGER, printed_payable INTEGER, PRIMARY KEY(file_id,page), FOREIGN KEY(file_id,page) REFERENCES pages(file_id,page) ON DELETE CASCADE)',
    );
    await library.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_print_connection ON pages(connection_no, bill_no)',
    );
    await library.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_print_period ON evidence(period_from, period_to)',
    );
    await indexPending();
  }

  Future<void> indexPending({void Function(String)? progress}) async {
    while (true) {
      final pending = await library.db.rawQuery(
        'SELECT b.file_id,b.page,b.text FROM pages b LEFT JOIN evidence e ON e.file_id=b.file_id AND e.page=b.page WHERE e.file_id IS NULL LIMIT 250',
      );
      if (pending.isEmpty) return;
      await library.db.transaction((tx) async {
        final batch = tx.batch();
        for (final row in pending) {
          batch.insert('evidence', {
            'file_id': row['file_id'],
            'page': row['page'],
            ...parsePrintedBillEvidence('${row['text']}'),
          });
        }
        await batch.commit(noResult: true);
      });
      progress?.call('Indexing printed billing periods…');
    }
  }

  Future<({int imported, int skipped, bool cancelled, List<String> errors})>
  importFolder(
    String folder, {
    void Function(String)? progress,
    bool Function()? cancelled,
  }) async {
    final paths = await Directory(folder)
        .list(recursive: true, followLinks: false)
        .where((e) => e is File && p.extension(e.path).toLowerCase() == '.pdf')
        .map((e) => e.path)
        .toList();
    return importFiles(paths, progress: progress, cancelled: cancelled);
  }

  Future<({int imported, int skipped, bool cancelled, List<String> errors})>
  importFiles(
    List<String> paths, {
    void Function(String)? progress,
    bool Function()? cancelled,
  }) async {
    if (_importing) throw StateError('An archive import is already running.');
    _importing = true;
    var imported = 0, skipped = 0;
    final errors = <String>[];
    try {
      final files = paths.map(File.new).toList();
      if (files.isEmpty) {
        throw const FormatException(
          'No PDFs selected or found in this folder.',
        );
      }
      // Smaller locality PDFs first; retain merged files too, since they may
      // contain additional bills. Exact byte duplicates are skipped by digest.
      final lengths = <String, int>{
        for (final file in files) file.path: await file.length(),
      };
      files.sort((a, b) => lengths[a.path]!.compareTo(lengths[b.path]!));
      for (var i = 0; i < files.length; i++) {
        if (cancelled?.call() == true) break;
        try {
          final result = await library.importPdfs(
            [files[i].path],
            preserveVersions: true,
            cancelled: cancelled,
            progress: (s) =>
                progress?.call('File ${i + 1}/${files.length}: $s'),
          );
          imported += result.imported;
          skipped += result.skipped;
          await indexPending(progress: progress);
        } catch (e) {
          if (cancelled?.call() == true) break;
          errors.add('${p.basename(files[i].path)}: $e');
        }
      }
      return (
        imported: imported,
        skipped: skipped,
        cancelled: cancelled?.call() == true,
        errors: errors,
      );
    } finally {
      _importing = false;
    }
  }

  Future<({int files, int pages, int review})> stats() async {
    final rows = await library.db.rawQuery(
      "SELECT (SELECT count(*) FROM files) AS files, count(*) AS pages, coalesce(sum(CASE WHEN b.connection_no='' OR b.bill_no='' OR e.period_from IS NULL THEN 1 ELSE 0 END),0) AS review FROM pages b LEFT JOIN evidence e ON e.file_id=b.file_id AND e.page=b.page",
    );
    final r = rows.single;
    return (
      files: r['files'] as int,
      pages: r['pages'] as int,
      review: r['review'] as int,
    );
  }

  Future<List<Map<String, Object?>>> find(
    String connection, {
    DateTime? from,
    DateTime? to,
  }) async {
    String iso(DateTime d) => d.toIso8601String().substring(0, 10);
    final rows = await library.db.rawQuery(
      'SELECT b.*,e.period_from,e.period_to,e.printed_water_fee,e.printed_arrears,e.printed_payable,f.name,f.digest,f.imported FROM pages b JOIN evidence e ON e.file_id=b.file_id AND e.page=b.page JOIN files f ON f.id=b.file_id WHERE trim(b.connection_no)=? COLLATE NOCASE ${from != null && to != null ? 'AND e.period_from<=? AND e.period_to>=?' : ''} ORDER BY f.pages,b.page',
      [
        connection.trim(),
        if (from != null && to != null) ...[iso(to), iso(from)],
      ],
    );
    final unique = <String, Map<String, Object?>>{};
    for (final r in rows) {
      // Keep every variant in the archive; select a convenient original page
      // for each bill/session and show how many stored copies support it.
      final pageDigest = sha256.convert(
        utf8.encode('${r['text']}'.replaceAll(RegExp(r'\s+'), ' ').trim()),
      );
      final key =
          '${r['bill_no']}|${r['period_from']}|${r['period_to']}|$pageDigest';
      final identity = '${r['bill_no']}'.isEmpty
          ? '${r['file_id']}:${r['page']}'
          : key;
      final old = unique[identity];
      if (old == null) {
        unique[identity] = {...r, 'copies': 1};
      } else {
        old['copies'] = (old['copies'] as int) + 1;
      }
    }
    return unique.values.toList()
      ..sort((a, b) => '${b['period_from']}'.compareTo('${a['period_from']}'));
  }

  Future<void> verify(Map<String, Object?> row) async {
    final digest =
        '${await sha256.bind(File(library.filePath('${row['file_id']}')).openRead()).first}';
    if (digest != row['digest']) {
      throw const FormatException(
        'Archived PDF has changed. Restore a verified backup before using it as evidence.',
      );
    }
  }

  Future<String> backup(String folder) async {
    final path = await library.backup(folder);
    await File(p.join(path, 'README.txt')).writeAsString(
      'Printed bill evidence archive: original PDFs, checksums and searchable index. Restore from the Water Fee Audit printed-bill archive. This does not restore or modify consumer bill history.',
    );
    return path;
  }

  Future<void> restore(String folder) async {
    await library.restore(folder);
    await indexPending();
  }
}
