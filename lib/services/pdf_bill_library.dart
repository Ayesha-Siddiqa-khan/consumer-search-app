import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite/sqflite.dart';

import 'name_normalizer.dart';

/// CSV and PDF text are data only; neither is interpreted as commands.
Map<String, Map<String, String>> parsePdfLocalities(String source) {
  final rows = csv.decode(source.replaceFirst('\ufeff', ''));
  if (rows.isEmpty) throw const FormatException('The locality CSV is empty.');
  final headers = rows.first.map((v) => '$v'.trim().toLowerCase()).toList();
  for (final key in ['locality', 'sector', 'pdf filename']) {
    if (!headers.contains(key)) throw FormatException('CSV is missing $key.');
  }
  final result = <String, Map<String, String>>{};
  for (final row in rows.skip(1)) {
    String cell(String key) {
      final i = headers.indexOf(key);
      return i < row.length ? '${row[i]}'.trim() : '';
    }

    final file = cell('pdf filename');
    if (file.isEmpty) continue;
    result[file.toLowerCase()] = {
      'name': file,
      'locality': cell('locality'),
      'sector': cell('sector'),
    };
  }
  return result;
}

String pdfSearchText(String text) => NameNormalizer.normalize(text);

Map<String, String> parsePdfBill(String text) {
  final lines = text
      .split(RegExp(r'[\r\n]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  String value(String label) {
    final pattern = RegExp('^$label[\\s:#.]*(.*)\$', caseSensitive: false);
    for (var i = 0; i < lines.length; i++) {
      final match = pattern.firstMatch(lines[i]);
      if (match != null) {
        return match[1]!.trim().isNotEmpty
            ? match[1]!.trim()
            : (i + 1 < lines.length ? lines[i + 1] : '');
      }
    }
    return '';
  }

  final fields = {
    'consumer_name': value('Name'),
    'father_name': value(r'F/H\. Name'),
    'mobile': value('Mobile'),
    'address': value('Address'),
    'connection_no': value('Connection No'),
    'old_connection_no': value(r'Old Conn\.'),
    'bill_no': value('Bill No'),
    'reference': value('Reference'),
    'rate_type': value('Connection Type'),
    'pdf_locality': value('Locality'),
    'pdf_sector': value('Sector'),
  };
  return {
    ...fields,
    for (final field in fields.entries)
      '${field.key}_search': pdfSearchText(field.value),
  };
}

class PdfBillLibrary {
  PdfBillLibrary(this.root);
  final Directory root;
  Database? _database;
  bool _hasConsumers = false;
  static Future<PdfBillLibrary>? _instance;

  static Future<PdfBillLibrary> instance() => _instance ??= () async {
    final support = await getApplicationSupportDirectory();
    final library = PdfBillLibrary(
      Directory(p.join(support.path, 'pdf_bills')),
    );
    await library.open();
    return library;
  }();

  Future<void> open() async {
    await Directory(p.join(root.path, 'files')).create(recursive: true);
    _database = await openDatabase(
      p.join(root.path, 'library.db'),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE files (id TEXT PRIMARY KEY, name TEXT NOT NULL, digest TEXT NOT NULL, locality TEXT NOT NULL, sector TEXT NOT NULL, pages INTEGER NOT NULL, unsearchable INTEGER NOT NULL, imported TEXT NOT NULL)',
        );
        final fields = parsePdfBill(
          '',
        ).keys.map((key) => '$key TEXT NOT NULL').join(', ');
        await db.execute(
          'CREATE TABLE pages (file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE, page INTEGER NOT NULL, text TEXT NOT NULL, search TEXT NOT NULL, $fields, PRIMARY KEY(file_id,page))',
        );
        await db.execute(
          'CREATE TABLE localities (name TEXT PRIMARY KEY, locality TEXT NOT NULL, sector TEXT NOT NULL)',
        );
      },
    );
  }

  Database get db => _database!;
  Future<void> attachConsumers(String path) async {
    if (_hasConsumers) return;
    await db.execute('ATTACH DATABASE ? AS consumer_register', [path]);
    _hasConsumers = true;
  }

  Future<void> close() async => db.close();
  String filePath(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid PDF file identifier.');
    }
    return p.join(root.path, 'files', '$id.pdf');
  }

  Future<List<Map<String, Object?>>> files() =>
      db.query('files', orderBy: 'name COLLATE NOCASE');
  Future<List<Map<String, Object?>>> localities() =>
      db.query('localities', orderBy: 'locality COLLATE NOCASE');

  Future<void> importLocalities(String path) async {
    final mapping = parsePdfLocalities(await File(path).readAsString());
    await db.transaction((tx) => _applyLocalities(tx, mapping.values));
  }

  Future<void> _applyLocalities(
    DatabaseExecutor tx,
    Iterable<Map<String, String>> mappings,
  ) async {
    for (final m in mappings) {
      await tx.insert(
        'localities',
        m,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await tx.update(
        'files',
        {'locality': m['locality'], 'sector': m['sector']},
        where: 'name = ? COLLATE NOCASE',
        whereArgs: [m['name']],
      );
      final ids = await tx.query(
        'files',
        columns: ['id'],
        where: 'name = ? COLLATE NOCASE',
        whereArgs: [m['name']],
      );
      for (final row in ids) {
        await tx.update(
          'pages',
          {
            'pdf_locality': m['locality'],
            'pdf_sector': m['sector'],
            'pdf_locality_search': pdfSearchText(m['locality']!),
            'pdf_sector_search': pdfSearchText(m['sector']!),
          },
          where: 'file_id = ?',
          whereArgs: [row['id']],
        );
      }
    }
  }

  /// Staged copies and one transaction keep the old library intact on failure.
  Future<({int imported, int skipped})> importPdfs(
    List<String> paths, {
    bool replaceAll = false,
    bool preserveVersions = false,
    String? replaceId,
    String? csvPath,
    void Function(String)? progress,
    bool Function()? cancelled,
  }) async {
    if (paths.isEmpty) throw const FormatException('No PDF files selected.');
    final mapping = {
      if (!(replaceAll && csvPath != null))
        for (final m in await localities()) '${m['name']}'.toLowerCase(): m,
    };
    final incomingMapping = csvPath == null
        ? <String, Map<String, String>>{}
        : parsePdfLocalities(await File(csvPath).readAsString());
    mapping.addAll(incomingMapping);
    final staged = <Map<String, Object?>>[];
    final pages = <Map<String, Object?>>[];
    final existing = await files();
    final replaced = <String>{};
    if (replaceId != null &&
        (paths.length != 1 || !existing.any((f) => f['id'] == replaceId))) {
      throw const FormatException(
        'Select one PDF to replace an existing file.',
      );
    }
    final digests = <String>{
      if (!replaceAll)
        ...existing
            .where((f) => f['id'] != replaceId)
            .map((f) => '${f['digest']}'),
    };
    final names = <String>{};
    var skipped = 0;
    var committed = false;
    try {
      for (final path in paths) {
        if (cancelled?.call() == true) {
          throw const FormatException(
            'Import cancelled. Existing data was kept.',
          );
        }
        final name = p.basename(path);
        if (!names.add(name.toLowerCase()) && !preserveVersions) {
          throw FormatException(
            'Two selected PDFs have the same filename: $name. Import them separately.',
          );
        }
        if (p.extension(name).toLowerCase() != '.pdf') {
          throw FormatException('Not a PDF: $name');
        }
        progress?.call('Checking $name for duplicate content…');
        final digest = '${await sha256.bind(File(path).openRead()).first}';
        if (!digests.add(digest)) {
          if (replaceId != null) {
            throw const FormatException(
              'This PDF is already present as another file. The selected file was kept.',
            );
          }
          skipped++;
          continue;
        }
        if (replaceId != null) replaced.add(replaceId);
        if (!replaceAll && !preserveVersions) {
          replaced.addAll(
            existing
                .where(
                  (f) => '${f['name']}'.toLowerCase() == name.toLowerCase(),
                )
                .map((f) => '${f['id']}'),
          );
        }
        final id =
            '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
        final meta = mapping[name.toLowerCase()];
        final old = replaceId == null
            ? null
            : existing.where((f) => f['id'] == replaceId).firstOrNull;
        final row = <String, Object?>{
          'id': id,
          'name': name,
          'digest': digest,
          'locality':
              meta?['locality'] ??
              old?['locality'] ??
              p.basenameWithoutExtension(name),
          'sector': meta?['sector'] ?? old?['sector'] ?? '',
          'pages': 0,
          'unsearchable': 0,
          'imported': DateTime.now().toIso8601String(),
        };
        staged.add(row);
        progress?.call('Copying $name (${staged.length}/${paths.length})');
        await File(path).copy(filePath(id));
        if (preserveVersions &&
            '${await sha256.bind(File(filePath(id)).openRead()).first}' !=
                digest) {
          throw FormatException(
            'Source changed while copying $name. Import it again.',
          );
        }
        final document = await PdfDocument.openFile(
          filePath(id),
          passwordProvider: () async => null,
        );
        try {
          if (document.pages.isEmpty) {
            throw FormatException('$name has no pages.');
          }
          row['pages'] = document.pages.length;
          var blank = 0;
          for (final page in document.pages) {
            if (cancelled?.call() == true) {
              throw const FormatException(
                'Import cancelled. Existing data was kept.',
              );
            }
            final text = (await page.loadText())?.fullText ?? '';
            final fields = parsePdfBill(text);
            for (final key in ['locality', 'sector']) {
              final value =
                  '${meta?[key] ?? (fields['pdf_$key']!.isNotEmpty ? fields['pdf_$key'] : row[key])}';
              fields['pdf_$key'] = value;
              fields['pdf_${key}_search'] = pdfSearchText(value);
            }
            if (pdfSearchText(text).isEmpty) blank++;
            pages.add({
              'file_id': id,
              'page': page.pageNumber,
              'text': text,
              'search': pdfSearchText(text),
              ...fields,
            });
            if (page.pageNumber % 20 == 0 || page.pageNumber == 1) {
              progress?.call(
                'Indexing $name: page ${page.pageNumber}/${document.pages.length}',
              );
              await Future<void>.delayed(Duration.zero);
            }
          }
          row['unsearchable'] = blank;
        } finally {
          await document.dispose();
        }
      }
      if (cancelled?.call() == true) {
        throw const FormatException(
          'Import cancelled. Existing data was kept.',
        );
      }
      await db.transaction((tx) async {
        if (replaceAll) {
          await tx.delete('files');
          await tx.delete('localities');
        }
        for (final id in replaced) {
          await tx.delete('files', where: 'id = ?', whereArgs: [id]);
        }
        final batch = tx.batch();
        for (final row in mapping.values) {
          batch.insert(
            'localities',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in staged) {
          batch.insert('files', row);
        }
        for (final row in pages) {
          batch.insert('pages', row);
        }
        await batch.commit(noResult: true);
        await _applyLocalities(tx, incomingMapping.values);
      });
      committed = true;
    } finally {
      if (!committed) {
        for (final row in staged) {
          await _removeCopy('${row['id']}');
        }
      }
    }
    for (final old in existing) {
      if (replaceAll || replaced.contains(old['id'])) {
        await _removeCopy('${old['id']}');
      }
    }
    return (imported: staged.length, skipped: skipped);
  }

  Future<void> _removeCopy(String id) async {
    final file = File(filePath(id));
    // An orphaned owned copy is harmless; a committed database must stay usable.
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Windows viewer may still hold the file. */
    }
  }

  Future<void> updateMetadata(String id, String locality, String sector) async {
    await db.transaction((tx) async {
      final files = await tx.query(
        'files',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (files.isEmpty) {
        throw const FormatException('This PDF no longer exists.');
      }
      await tx.insert('localities', {
        'name': files.single['name'],
        'locality': locality.trim(),
        'sector': sector.trim(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update(
        'files',
        {'locality': locality.trim(), 'sector': sector.trim()},
        where: 'id = ?',
        whereArgs: [id],
      );
      await tx.update(
        'pages',
        {
          'pdf_locality': locality.trim(),
          'pdf_sector': sector.trim(),
          'pdf_locality_search': pdfSearchText(locality),
          'pdf_sector_search': pdfSearchText(sector),
        },
        where: 'file_id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<void> deleteFile(String id) async {
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
    await _removeCopy(id);
  }

  Future<void> clear() async {
    final old = await files();
    await db.transaction((tx) async {
      await tx.delete('files');
      await tx.delete('localities');
    });
    for (final row in old) {
      await _removeCopy('${row['id']}');
    }
  }

  Future<({List<Map<String, Object?>> rows, int total})> search({
    String query = '',
    String locality = '',
    String sector = '',
    String fileId = '',
    String searchBy = 'all',
    String consumerStatus = '',
    String connectionStatus = '',
    String billStatus = '',
    String rateType = '',
    int offset = 0,
    int limit = 50,
  }) async {
    final conditions = <String>[];
    final args = <Object?>[];
    for (final filter in {
      'b.pdf_locality': locality,
      'b.pdf_sector': sector,
      'f.id': fileId,
    }.entries) {
      if (filter.value.isNotEmpty) {
        conditions.add('${filter.key} = ?');
        args.add(filter.value);
      }
    }
    if (rateType.isNotEmpty) {
      conditions.add('b.rate_type = ?');
      args.add(rateType);
    }
    if (_hasConsumers) {
      for (final filter in {
        'c.consumer_status': consumerStatus,
        'c.connection_status': connectionStatus,
        'c.bill_status': billStatus,
      }.entries) {
        if (filter.value.isNotEmpty) {
          if (filter.key == 'c.bill_status' && filter.value == 'Un-Paid') {
            conditions.add(
              "lower(replace(c.bill_status, '-', '')) IN ('unpaid', 'expired')",
            );
          } else {
            conditions.add("lower(replace(${filter.key}, '-', '')) = ?");
            args.add(filter.value.toLowerCase().replaceAll('-', ''));
          }
        }
      }
    }
    // Same name-spelling normalization as consumer search; all words may occur in any order.
    for (final token in pdfSearchText(
      query,
    ).split(' ').where((t) => t.isNotEmpty)) {
      const columns = [
        'consumer_name',
        'father_name',
        'mobile',
        'address',
        'connection_no',
        'old_connection_no',
        'bill_no',
        'reference',
      ];
      if (columns.contains(searchBy)) {
        conditions.add('instr(b.${searchBy}_search, ?) > 0');
        args.add(token);
      } else {
        conditions.add(
          '(instr(b.search, ?) > 0 OR instr(b.pdf_locality_search || \' \' || b.pdf_sector_search || \' \' || upper(f.name), ?) > 0)',
        );
        args.addAll([token, token]);
      }
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final from =
        'FROM pages b JOIN files f ON f.id = b.file_id ${_hasConsumers ? 'LEFT JOIN consumer_register.consumers c ON c.id = (SELECT id FROM consumer_register.consumers WHERE connection_no = b.connection_no ORDER BY id DESC LIMIT 1)' : ''} $where';
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) $from', args),
        ) ??
        0;
    final rows = await db.rawQuery(
      'SELECT b.*, f.name, b.pdf_locality AS locality, b.pdf_sector AS sector $from ORDER BY f.name COLLATE NOCASE, b.page LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return (rows: rows, total: count);
  }

  /// Preserve original vectors/text: export only the requested source pages.
  Future<Uint8List> exportPages(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) {
      throw const FormatException('Select at least one bill page.');
    }
    final docs = <String, PdfDocument>{};
    final output = await PdfDocument.createNew(sourceName: 'Bills.pdf');
    try {
      for (final row in rows) {
        final id = '${row['file_id']}';
        docs[id] ??= await PdfDocument.openFile(filePath(id));
      }
      output.pages = [
        for (final row in rows)
          docs['${row['file_id']}']!.pages[(row['page'] as int) - 1],
      ];
      return await output.encodePdf();
    } finally {
      await output.dispose();
      for (final d in docs.values) {
        await d.dispose();
      }
    }
  }

  Future<String> backup(String destination) async {
    final target = Directory(
      p.join(
        destination,
        'PDF-Bills-Backup-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await target.create();
    try {
      await Directory(p.join(target.path, 'files')).create();
      for (final f in await files()) {
        await File(
          filePath('${f['id']}'),
        ).copy(p.join(target.path, 'files', '${f['id']}.pdf'));
      }
      final backupDb = p.join(target.path, 'library.db').replaceAll("'", "''");
      await db.execute("VACUUM INTO '$backupDb'");
      await File(p.join(target.path, 'README.txt')).writeAsString(
        'PDF Bills backup. Keep this entire folder together. Restore it from the PDF Bills page.',
      );
      return target.path;
    } catch (_) {
      // Leave a failed backup for diagnosis; it is never offered as a success.
      rethrow;
    }
  }

  Future<void> restore(
    String directory, {
    void Function(String)? progress,
  }) async {
    final source = await openDatabase(
      p.join(directory, 'library.db'),
      readOnly: true,
      singleInstance: false,
    );
    final staged = <String>[];
    final old = await files();
    var committed = false;
    try {
      if ((await source.rawQuery(
                'PRAGMA integrity_check',
              )).first.values.first !=
              'ok' ||
          (await source.rawQuery('PRAGMA user_version')).first.values.first !=
              1) {
        throw const FormatException(
          'Damaged or incompatible PDF Bills backup.',
        );
      }
      if ((await source.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
        throw const FormatException('Backup has missing file references.');
      }
      final files = await source.query('files');
      final pages = await source.query('pages');
      final mappings = await source.query('localities');
      final replacements = <String, String>{};
      for (final file in files) {
        final id = '${file['id']}';
        filePath(id); // Reject directory traversal in an untrusted backup.
        final name = p.join(directory, 'files', '$id.pdf');
        progress?.call('Validating ${file['name']}');
        if ('${await sha256.bind(File(name).openRead()).first}' !=
            file['digest']) {
          throw const FormatException(
            'A PDF in the backup is missing or has changed.',
          );
        }
        final doc = await PdfDocument.openFile(name);
        try {
          final count = file['pages'];
          final indexed = pages.where((r) => r['file_id'] == id).toList();
          if (count != doc.pages.length ||
              indexed.length != count ||
              indexed.any(
                (r) =>
                    r['page'] is! int ||
                    (r['page'] as int) < 1 ||
                    (r['page'] as int) > doc.pages.length,
              )) {
            throw const FormatException('Backup page index is incomplete.');
          }
        } finally {
          await doc.dispose();
        }
        final newId =
            '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
        replacements[id] = newId;
        staged.add(newId);
        await File(name).copy(filePath(newId));
      }
      await db.transaction((tx) async {
        await tx.delete('files');
        await tx.delete('localities');
        final batch = tx.batch();
        for (final row in files) {
          batch.insert('files', {...row, 'id': replacements[row['id']]});
        }
        for (final row in pages) {
          batch.insert('pages', {
            ...row,
            'file_id': replacements[row['file_id']],
            'search': pdfSearchText('${row['text']}'),
          });
        }
        for (final row in mappings) {
          batch.insert('localities', row);
        }
        await batch.commit(noResult: true);
      });
      committed = true;
    } finally {
      await source.close();
      if (!committed) {
        for (final id in staged) {
          await _removeCopy(id);
        }
      }
    }
    for (final row in old) {
      await _removeCopy('${row['id']}');
    }
  }
}
