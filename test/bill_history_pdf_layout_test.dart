import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Inspect rendered content streams: a PDF signature alone misses blank tables.
List<String> contentStreams(Uint8List bytes) {
  final content = latin1.decode(bytes);
  return [
    for (final stream in RegExp(
      r'\bstream\r?\n(.*?)\r?\nendstream',
      dotAll: true,
    ).allMatches(content))
      ...(() {
        try {
          final decoded = latin1.decode(
            ZLibDecoder().convert(latin1.encode(stream[1]!)),
          );
          return decoded.contains('BT') && decoded.contains('ET')
              ? [decoded]
              : <String>[];
        } on FormatException {
          return <String>[];
        }
      })(),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final count in [1, 11, 18, 80]) {
    test(
      'history PDF renders all 16 columns for $count bills and paginates',
      () async {
        final bills = [
          for (var i = 0; i < count; i++)
            BillHistory(
              connectionNo: '90010045',
              billNo: '${7000000 + i}',
              billType: i.isEven ? 'Regular' : 'New Connection',
              billingPeriod: '01/07/2026 - 31/12/2026',
              arrears: '2640',
              waterFee: '2400',
              sanitation: '0',
              drainage: '0',
              billingFee: '0',
              totalBill: '5040',
              fine: '240',
              afterDueDate: '5280',
              dueDate: '29/08/2026',
              status: i.isEven ? 'Un-Paid' : 'Paid',
              amountReceived: i.isEven ? '0' : '5040',
              receiveDate: i.isEven ? '-' : '02/04/2026',
            ),
        ];
        final bytes = await ExportService.instance.generateBillHistoryPdf(
          connectionNo: '90010045',
          consumerDetail: {
            'consumer_name': 'ZULFIQAR ALI',
            'father_husband_name': 'MUHAMMAD UMAR',
            'sector': 'Ali Town',
            'locality': 'Ali town Zone A',
          },
          bills: bills,
        );
        final streams = contentStreams(bytes);
        final textBlocks = streams.fold<int>(
          0,
          (total, stream) =>
              total + RegExp(r'\bBT\s').allMatches(stream).length,
        );
        expect(
          textBlocks,
          greaterThanOrEqualTo(16 * (count + 1)),
          reason:
              'Every bill and the 16-column heading must actually be drawn.',
        );
        final pages = RegExp(
          r'/Type\s*/Page\b',
        ).allMatches(latin1.decode(bytes)).length;
        // Coverage notes may need an extra page; all 16-column rows must remain.
        if (count == 11) expect(pages, lessThanOrEqualTo(2));
        if (count == 80) {
          expect(pages, greaterThan(1));
          expect(
            streams
                .where(
                  (stream) => RegExp(r'\bBT\s').allMatches(stream).length >= 32,
                )
                .length,
            greaterThanOrEqualTo(pages),
            reason: 'Each page must draw headings and bill rows.',
          );
        }
        if (Platform.environment['HISTORY_PDF_PREVIEW'] == '1') {
          await Directory('tmp/pdfs').create(recursive: true);
          await File('tmp/pdfs/history-$count.pdf').writeAsBytes(bytes);
        }
      },
    );
  }
}
