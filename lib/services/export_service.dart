import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/consumer_model.dart';
import '../models/bill_history_model.dart';
import '../models/history_bill_balance.dart';
import '../models/billing_audit_model.dart';
import 'database_service.dart';

class ColumnOption {
  final String key;
  final String label;
  final String Function(Consumer) valueGetter;

  const ColumnOption({
    required this.key,
    required this.label,
    required this.valueGetter,
  });
}

class BillingAuditColumn {
  final String key;
  final String label;
  final String Function(BillingAuditEntry) value;
  final double width;
  const BillingAuditColumn(this.key, this.label, this.value, {this.width = 1});
}

class ExportService {
  static final ExportService instance = ExportService._internal();
  ExportService._internal();

  Future<Uint8List> generateBillingSummaryPdf(Map<String, dynamic> stats) async {
    final document = pw.Document();
    final number = NumberFormat('#,##0.##');
    final categories = {
      'domestic': 'Domestic', 'commercial': 'Commercial', 'private': 'Private Societies',
      if ((stats['unknownCount'] as num? ?? 0) > 0) 'unknown': 'Unclassified',
      '': 'Total',
    };
    const headers = ['Category', 'Bills', 'Paid bills amount', 'Unpaid / expired amount', 'Arrears (included)', 'Amount received'];
    document.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      theme: pw.ThemeData.withFont(base: pw.Font.helvetica(), bold: pw.Font.helveticaBold()),
      build: (_) => [
        pw.Text('Category Totals & Collections', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.Text('Generated: ${DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 18),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.black, width: 0.6),
          columnWidths: const {
            0: pw.FlexColumnWidth(1.25),
            1: pw.FlexColumnWidth(0.6),
            2: pw.FlexColumnWidth(1.35),
            3: pw.FlexColumnWidth(1.45),
            4: pw.FlexColumnWidth(1.35),
            5: pw.FlexColumnWidth(1.35),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEEEEEE)),
              children: [
                for (final label in headers)
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Text(
                      label,
                      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
                    ),
                  ),
              ],
            ),
            for (final entry in categories.entries)
              pw.TableRow(
                decoration: entry.key.isEmpty
                    ? const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF7F7F7))
                    : const pw.BoxDecoration(color: PdfColors.white),
                children: [
                  for (final value in [
                    entry.value,
                    number.format(stats['${entry.key}Count'] ?? 0),
                    for (final field in ['PaidAmount', 'UnpaidAmount', 'Arrears', 'Received'])
                      'Rs. ${number.format(stats['${entry.key}$field'] ?? 0)}'
                  ])
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 24),
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Text(
                        value,
                        style: pw.TextStyle(
                          fontSize: entry.key.isEmpty ? 12 : 11.5,
                          fontWeight: entry.key.isEmpty ? pw.FontWeight.bold : pw.FontWeight.normal,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ],
    ));
    return document.save();
  }

  static String formatAmountWithoutDecimals(String val) {
    final trimmed = val.trim();
    if (trimmed.isEmpty || trimmed == '-') return '-';
    final clean = trimmed.replaceAll(',', '');
    final numVal = double.tryParse(clean);
    if (numVal != null) {
      if (numVal == numVal.roundToDouble()) {
        return NumberFormat('#,##0').format(numVal.toInt());
      }
      return NumberFormat('#,##0.##').format(numVal);
    }
    if (trimmed.endsWith('.00')) {
      return trimmed.substring(0, trimmed.length - 3);
    }
    if (trimmed.endsWith('.0')) {
      return trimmed.substring(0, trimmed.length - 2);
    }
    return trimmed;
  }

  static final List<ColumnOption> availableColumns = [
    ColumnOption(key: 'sr_no', label: 'Sr #', valueGetter: (c) => c.srNo.toString()),
    ColumnOption(key: 'consumer_name', label: 'Consumer Name', valueGetter: (c) => c.consumerName),
    ColumnOption(key: 'father_husband_name', label: 'F/H Name', valueGetter: (c) => c.fatherHusbandName),
    ColumnOption(key: 'total_bill', label: 'Total Bill', valueGetter: (c) => formatAmountWithoutDecimals(c.totalBill)),
    ColumnOption(key: 'mobile', label: 'Mobile', valueGetter: (c) => c.mobile),
    ColumnOption(key: 'connection_no', label: 'Connection No', valueGetter: (c) => c.connectionNo),
    ColumnOption(key: 'old_connection_no', label: 'Old Conn No', valueGetter: (c) => c.oldConnectionNo),
    ColumnOption(key: 'sector', label: 'Sector', valueGetter: (c) => c.sector),
    ColumnOption(key: 'locality', label: 'Locality', valueGetter: (c) => c.locality),
    ColumnOption(key: 'address', label: 'Address', valueGetter: (c) => c.address),
    ColumnOption(key: 'rate_type', label: 'Rate Type', valueGetter: (c) => c.rateType),
    ColumnOption(key: 'order_no', label: 'Order / Reg No', valueGetter: (c) => c.orderNo),
    ColumnOption(key: 'connection_date', label: 'Date (DD-MM-YYYY)', valueGetter: (c) => c.connectionDate),
    ColumnOption(key: 'connection_status', label: 'Status', valueGetter: (c) => c.connectionStatus),
    ColumnOption(key: 'consumer_status', label: 'Consumer Status', valueGetter: (c) => c.consumerStatus),
    ColumnOption(key: 'bill_status', label: 'Bill Status', valueGetter: (c) => c.billStatus),
    ColumnOption(key: 'amount_received', label: 'Amt Received', valueGetter: (c) => formatAmountWithoutDecimals(c.amountReceived)),
    ColumnOption(key: 'due_date', label: 'Due Date', valueGetter: (c) => c.dueDate),
    ColumnOption(key: 'fine', label: 'Fine', valueGetter: (c) => formatAmountWithoutDecimals(c.fine)),
    ColumnOption(key: 'after_due_date', label: 'After Due Date', valueGetter: (c) => formatAmountWithoutDecimals(c.afterDueDate)),
  ];

  /// Default 7 columns selected by user preference for PDF Export (Sector is shown in header)
  static const Set<String> defaultPdfColumnKeys = {
    'sr_no',
    'consumer_name',
    'father_husband_name',
    'mobile',
    'connection_no',
    'old_connection_no',
    'after_due_date',
  };

  /// Computes active columns based on user selection, custom order, and active sector filter
  List<ColumnOption> getActiveColumns({
    required Set<String> selectedColumnKeys,
    List<String>? orderedColumnKeys,
    String? sector,
  }) {
    final hasSpecificSector = sector != null &&
        sector.trim().isNotEmpty &&
        sector.trim().toLowerCase() != 'all' &&
        !sector.trim().toLowerCase().startsWith('all sector');

    final effectiveSelectedKeys = Set<String>.from(selectedColumnKeys);
    if (hasSpecificSector) {
      // Sector is already shown in the top header banner, exclude from table columns
      effectiveSelectedKeys.remove('sector');
    }

    final colMap = {for (var col in availableColumns) col.key: col};
    if (orderedColumnKeys != null && orderedColumnKeys.isNotEmpty) {
      final ordered = orderedColumnKeys
          .where((k) => effectiveSelectedKeys.contains(k) && colMap.containsKey(k))
          .map((k) => colMap[k]!)
          .toList();
      final remaining = availableColumns
          .where((col) => effectiveSelectedKeys.contains(col.key) && !ordered.contains(col))
          .toList();
      return [...ordered, ...remaining];
    } else {
      return availableColumns
          .where((col) => effectiveSelectedKeys.contains(col.key))
          .toList();
    }
  }

  /// Generate PDF with only user-selected columns and optional custom ordering
  Future<Uint8List> generateConsumerPdf({
    required List<Consumer> consumers,
    required Set<String> selectedColumnKeys,
    List<String>? orderedColumnKeys,
    String? sector,
    String? billStatus,
    String reportTitle = 'Consumer List Report',
    String? filterSummary,
  }) async {
    final pdfDoc = pw.Document();

    final hasSpecificSector = sector != null &&
        sector.trim().isNotEmpty &&
        sector.trim().toLowerCase() != 'all' &&
        !sector.trim().toLowerCase().startsWith('all sector');
    final cleanSector = hasSpecificSector ? sector.trim() : '';

    final hasSpecificBillStatus = billStatus != null &&
        billStatus.trim().isNotEmpty &&
        billStatus.trim().toLowerCase() != 'all' &&
        !billStatus.trim().toLowerCase().startsWith('all bill');
    final cleanBillStatus = hasSpecificBillStatus ? billStatus.trim() : '';

    String effectiveTitle;
    if (hasSpecificSector) {
      if (hasSpecificBillStatus) {
        effectiveTitle = '$cleanSector - $cleanBillStatus Bill List';
      } else {
        effectiveTitle = '$cleanSector - Bill List';
      }
    } else {
      if (hasSpecificBillStatus) {
        effectiveTitle = '$cleanBillStatus Bill List';
      } else {
        effectiveTitle = reportTitle;
      }
    }

    final activeColumns = getActiveColumns(
      selectedColumnKeys: selectedColumnKeys,
      orderedColumnKeys: orderedColumnKeys,
      sector: sector,
    );

    String? cleanFilterSummary = filterSummary;
    if (cleanFilterSummary != null && cleanFilterSummary.isNotEmpty) {
      final parts = cleanFilterSummary.split('•').map((s) => s.trim()).where((s) {
        final lower = s.toLowerCase();
        if (hasSpecificSector && lower.startsWith('sector:')) return false;
        if (hasSpecificBillStatus && lower.startsWith('bill:')) return false;
        return s.isNotEmpty;
      }).toList();
      cleanFilterSummary = parts.isNotEmpty ? parts.join(' • ') : null;
    }

    // Format current date in strict Pakistani format DD-MM-YYYY
    final now = DateTime.now();
    final pakistaniDate = DateFormat('dd-MM-yyyy').format(now);
    final printTime = DateFormat('HH:mm:ss').format(now);

    final fontData = await PdfGoogleFonts.robotoRegular();
    final fontBold = await PdfGoogleFonts.robotoBold();

    final totalRecords = consumers.length;

    // Dynamically calculate page chunks to fit maximum possible rows per page
    // Total printable A4 landscape height: 559.28 pt (595.28 - 2 * 18 margins).
    // On Page 1: Header Banner (~41pt) + Filter summary (~16pt) + Spacing (6pt) + Table Header (21pt) + Footer (20pt) = ~104pt.
    // Usable height for data rows on Page 1: ~455 pt.
    // On Page 2+: No banner/filters/spacing! Only Table Header (21pt) + Footer (20pt) = ~41pt. Usable height for data rows on Page 2+: ~518 pt.
    final pageChunks = <List<Consumer>>[];
    if (consumers.isEmpty) {
      pageChunks.add([]);
    } else {
      int i = 0;
      while (i < consumers.length) {
        final isFirstPage = pageChunks.isEmpty;
        final maxTableHeight = isFirstPage ? 430.0 : 495.0;

        double currentTableHeight = 0;
        final chunk = <Consumer>[];

        while (i < consumers.length) {
          final c = consumers[i];
          final isMultiLine = c.consumerName.length > 24 ||
              c.fatherHusbandName.length > 24 ||
              c.address.length > 30;
          final rowCost = isMultiLine ? 29.0 : 18.5;

          if (chunk.isNotEmpty && (currentTableHeight + rowCost > maxTableHeight)) {
            break;
          }
          chunk.add(c);
          currentTableHeight += rowCost;
          i++;
        }
        pageChunks.add(chunk);
      }
    }

    final totalPages = pageChunks.length;
    final pageStartSerials = <int>[];
    int runningSerial = 1;
    for (final chunk in pageChunks) {
      pageStartSerials.add(runningSerial);
      runningSerial += chunk.length;
    }

    for (int pageIdx = 0; pageIdx < totalPages; pageIdx++) {
      final pageRecords = pageChunks[pageIdx];
      final startSerial = pageStartSerials[pageIdx];
      final rowCount = pageRecords.length;

      // Expand rows vertically so smaller result sets fill the page gracefully
      final double rowVerticalPad;
      if (rowCount > 0 && rowCount <= 14) {
        rowVerticalPad = ((410.0 / rowCount - 12.0) / 2).clamp(3.5, 11.0);
      } else if (rowCount <= 18) {
        rowVerticalPad = ((430.0 / rowCount - 12.0) / 2).clamp(3.5, 7.0);
      } else {
        rowVerticalPad = 3.5;
      }
      final double headerVerticalPad = rowVerticalPad >= 9.0 ? 6.0 : 4.0;

      pdfDoc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(18),
          theme: pw.ThemeData.withFont(base: fontData, bold: fontBold),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                // Header Banner: Only rendered on the first page as requested!
                if (pageIdx == 0) ...[
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      border: pw.Border.all(color: PdfColors.black, width: 1.5),
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                    ),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Expanded(
                          child: pw.Text(
                            effectiveTitle,
                            style: pw.TextStyle(
                              color: PdfColors.black,
                              fontSize: 14,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ),
                        pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: [
                            pw.Text(
                              'Date: $pakistaniDate',
                              style: pw.TextStyle(
                                color: PdfColors.black,
                                fontSize: 10,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.SizedBox(height: 2),
                            pw.Text(
                              'Time: $printTime | Records: $totalRecords',
                              style: const pw.TextStyle(
                                color: PdfColors.black,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (cleanFilterSummary != null && cleanFilterSummary.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Filters: $cleanFilterSummary',
                      style: const pw.TextStyle(fontSize: 10, color: PdfColors.black),
                    ),
                  ],
                  pw.SizedBox(height: 6),
                ],

                // Continuous Table
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.black, width: 0.6),
                  columnWidths: {
                    for (int i = 0; i < activeColumns.length; i++)
                      i: activeColumns[i].key == 'sr_no'
                          ? const pw.FixedColumnWidth(28)
                          : activeColumns[i].key == 'address'
                              ? const pw.FlexColumnWidth(2.2)
                              : activeColumns[i].key == 'consumer_name'
                                  ? const pw.FlexColumnWidth(2.2)
                                  : activeColumns[i].key == 'father_husband_name'
                                      ? const pw.FlexColumnWidth(2.0)
                                      : activeColumns[i].key == 'mobile'
                                          ? const pw.FlexColumnWidth(1.4)
                                          : activeColumns[i].key == 'connection_no'
                                              ? const pw.FlexColumnWidth(1.4)
                                              : activeColumns[i].key == 'old_connection_no'
                                                  ? const pw.FlexColumnWidth(1.1)
                                                  : activeColumns[i].key == 'total_bill'
                                                      ? const pw.FlexColumnWidth(1.3)
                                                      : activeColumns[i].key == 'after_due_date'
                                                          ? const pw.FlexColumnWidth(1.3)
                                                          : activeColumns[i].key == 'sector'
                                                              ? const pw.FlexColumnWidth(1.4)
                                                              : const pw.FlexColumnWidth(1.1),
                  },
                  children: [
                    // Table Header Row (Light gray background, solid black borders, 10pt bold)
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(
                        color: PdfColor.fromInt(0xFFEEEEEE),
                      ),
                      children: activeColumns.map((col) {
                        return pw.Container(
                          padding: pw.EdgeInsets.symmetric(horizontal: 4, vertical: headerVerticalPad),
                          child: pw.Text(
                            col.label,
                            style: pw.TextStyle(
                              color: PdfColors.black,
                              fontSize: 10,
                              fontWeight: pw.FontWeight.bold,
                            ),
                            overflow: pw.TextOverflow.clip,
                          ),
                        );
                      }).toList(),
                    ),

                    // Table Data Rows (Pure white background, crisp black text)
                    ...pageRecords.asMap().entries.map((entry) {
                      final rowIndex = entry.key;
                      final c = entry.value;
                      final globalSerial = startSerial + rowIndex;

                      return pw.TableRow(
                        decoration: const pw.BoxDecoration(
                          color: PdfColors.white,
                        ),
                        children: activeColumns.map((col) {
                          final String val;
                          if (col.key == 'sr_no') {
                            val = globalSerial.toString();
                          } else {
                            val = col.valueGetter(c);
                          }

                          return pw.Container(
                            padding: pw.EdgeInsets.symmetric(horizontal: 4, vertical: rowVerticalPad),
                            child: pw.Text(
                              val.isNotEmpty ? val : '-',
                              style: const pw.TextStyle(
                                fontSize: 9.5,
                                color: PdfColors.black,
                              ),
                              maxLines: 2,
                              overflow: pw.TextOverflow.clip,
                            ),
                          );
                        }).toList(),
                      );
                    }),
                  ],
                ),

                pw.Spacer(),

                // Footer (Crisp top border, 10pt black text)
                pw.Container(
                  padding: const pw.EdgeInsets.only(top: 4),
                  decoration: const pw.BoxDecoration(
                    border: pw.Border(top: pw.BorderSide(color: PdfColors.black, width: 0.5)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.end,
                    children: [
                      pw.Text(
                        'Page ${pageIdx + 1} of ${totalPages > 0 ? totalPages : 1}',
                        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.black),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );
    }

    return await pdfDoc.save();
  }

  /// Generate a complete, paginated B&W bill history, independent of UI pagination.
  Future<Uint8List> generateBillHistoryPdf({
    required String connectionNo,
    required Map<String, String>? consumerDetail,
    required List<BillHistory> bills,
    BillingAuditEntry? audit,
  }) async {
    final summary =
        audit ??
        buildBillingAudit(
          consumers: [
            {...?consumerDetail, 'connection_no': connectionNo},
          ],
          bills: bills.map((bill) => bill.toMap()).toList(),
        ).single;
    final remaining = latestHistoryBillBalance(bills);
    String money(int? paisa) => paisa == null
        ? 'Needs review'
        : 'Rs. ${NumberFormat('#,##0.##').format(paisa / 100)}';
    final pdfDoc = pw.Document();
    final fontData = await PdfGoogleFonts.robotoRegular();
    final fontBold = await PdfGoogleFonts.robotoBold();
    final consumerName = consumerDetail?['consumer_name'] ?? '-';
    final fhName = consumerDetail?['father_husband_name'] ?? '-';
    final sector = consumerDetail?['sector'] ?? '-';
    final locality = consumerDetail?['locality'] ?? '-';

    pw.Widget info(String label, String value) => pw.RichText(
      text: pw.TextSpan(
        style: const pw.TextStyle(fontSize: 10),
        children: [
          pw.TextSpan(
            text: '$label ',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.TextSpan(text: value),
        ],
      ),
    );
    pw.Widget cell(String value, {bool header = false}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      alignment: pw.Alignment.center,
      child: pw.Text(
        value.isEmpty ? '-' : value,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );

    pdfDoc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        maxPages: bills.length + 2,
        theme: pw.ThemeData.withFont(base: fontData, bold: fontBold),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Text(
                  'Connection No: $connectionNo  |  Consumer: $consumerName',
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ),
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 4),
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(width: 0.5)),
          ),
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ),
        build: (_) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 6,
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(width: 0.8),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(3),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Connection No:', connectionNo),
                      pw.SizedBox(height: 3),
                      info('Consumer:', consumerName),
                      pw.SizedBox(height: 3),
                      info('F/H Name:', fhName),
                      pw.SizedBox(height: 3),
                      info('Locality:', '$locality, $sector'),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                flex: 5,
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    color: const PdfColor.fromInt(0xFFF7F7F7),
                    border: pw.Border.all(width: 0.8),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(3),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Generated Water Fee:', money(summary.waterFee)),
                      pw.SizedBox(height: 3),
                      info('Amount Received (water):', money(summary.waterReceived)),
                      pw.SizedBox(height: 3),

                      info('Fine Collected:', money(summary.fineCollected)),
                      pw.SizedBox(height: 3),
                      info('Remaining Balance:', money(remaining.amount)),
                      pw.SizedBox(height: 3),
                      info(
                        'Bills:',
                        '${summary.paidBillCount} paid / ${summary.unpaidBillCount} unpaid / ${summary.expiredBillCount} expired (carried)',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Remaining Balance: ${remaining.bill == null ? '' : 'bill ${remaining.bill!.billNo}, '}${remaining.basis}. '
            'The latest bill includes carried arrears; older expired bills are not added again. '
            'Amount Received excludes identified collected fines and other charges. Detailed reconciliation is available on Water Fee Audit.',
            style: const pw.TextStyle(fontSize: 8),
          ),
          pw.Text('Advance applied (not new cash): ${money(summary.advanceApplied)}; unapplied receipts / advance credit: ${money(summary.advanceBalance)}. '
            'Older overlapping bills excluded: ${summary.excludedBillNumbers.isEmpty ? 'None' : summary.excludedBillNumbers.join(', ')}.',
            style: const pw.TextStyle(fontSize: 8)),
          if (summary.confirmedPaymentCount > 0)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                'Confirmed sector payment exception: ${summary.confirmedPaymentCount} July-December 2023 bill(s); '
                '${money(summary.confirmedPaymentAdjustment)} included in receipts. '
                'Already-Paid bills and receipt dates are unchanged.',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 8),
          // A direct MultiPage child lets the table split at measured row heights.
          if (summary.coverage?.hasWarning ?? false)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(summary.coverage!.warningText(money),
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.red)),
            ),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: const {
              0: pw.FixedColumnWidth(22),
              1: pw.FixedColumnWidth(46),
              2: pw.FixedColumnWidth(60),
              3: pw.FlexColumnWidth(1.9),
              4: pw.FlexColumnWidth(0.9),
              5: pw.FlexColumnWidth(0.9),
              6: pw.FlexColumnWidth(0.7),
              7: pw.FlexColumnWidth(0.7),
              8: pw.FlexColumnWidth(0.6),
              9: pw.FlexColumnWidth(1),
              10: pw.FlexColumnWidth(0.7),
              11: pw.FlexColumnWidth(1),
              12: pw.FlexColumnWidth(1.15),
              13: pw.FlexColumnWidth(0.9),
              14: pw.FlexColumnWidth(1),
              15: pw.FlexColumnWidth(1.15),
            },
            children: [
              pw.TableRow(
                repeat: true,
                decoration: const pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFFEEEEEE),
                ),
                children: [
                  'Sr#',
                  'Bill No',
                  'Type',
                  'Billing Period',
                  'Arrears',
                  'Water',
                  'Sanit.',
                  'Drain.',
                  'Fee',
                  'Total',
                  'Fine',
                  'After Due',
                  'Due Date',
                  'Status',
                  'Received',
                  'Recv Date',
                ].map((label) => cell(label, header: true)).toList(),
              ),
              for (final entry in bills.asMap().entries)
                pw.TableRow(
                  children: [
                    '${entry.key + 1}',
                    entry.value.billNo,
                    entry.value.billType,
                    entry.value.billingPeriod,
                    formatAmountWithoutDecimals(entry.value.arrears),
                    formatAmountWithoutDecimals(entry.value.waterFee),
                    formatAmountWithoutDecimals(entry.value.sanitation),
                    formatAmountWithoutDecimals(entry.value.drainage),
                    formatAmountWithoutDecimals(entry.value.billingFee),
                    formatAmountWithoutDecimals(entry.value.totalBill),
                    formatAmountWithoutDecimals(entry.value.fine),
                    formatAmountWithoutDecimals(entry.value.afterDueDate),
                    entry.value.dueDate,
                    entry.value.status,
                    formatAmountWithoutDecimals(entry.value.amountReceived),
                    entry.value.receiveDate,
                  ].map((value) => cell(value)).toList(),
                ),
            ],
          ),
          if (bills.isEmpty)
            pw.Text(
              'No bill history records.',
              style: const pw.TextStyle(fontSize: 10),
            ),
        ],
      ),
    );
    return pdfDoc.save();
  }

  static String _auditAmount(int? paisa) => paisa == null ? '' : (paisa / 100).toStringAsFixed(2);

  static final billingAuditColumns = <BillingAuditColumn>[
    BillingAuditColumn('bill_group', 'Bill Group', (e) => e.billGroupLabel, width: 1.5),
    BillingAuditColumn('current_bill_status', 'Current Bill Status', (e) => e.currentBillStatus),
    BillingAuditColumn('consumer_status', 'Consumer Status', (e) => e.consumerStatus),
    BillingAuditColumn('connection', 'Connection No', (e) => e.connectionNo),
    BillingAuditColumn('consumer', 'Consumer Name', (e) => e.consumerName, width: 1.8),
    BillingAuditColumn('father', 'F/H Name', (e) => e.fatherHusbandName, width: 1.6),
    BillingAuditColumn('sector', 'Sector', (e) => e.sector, width: 1.5),
    BillingAuditColumn('locality', 'Locality', (e) => e.locality, width: 1.5),
    BillingAuditColumn('address', 'Address', (e) => e.address, width: 2.2),
    BillingAuditColumn('date', 'Connection Date', (e) => e.connectionDate),
    BillingAuditColumn('connection_status', 'Connection Status', (e) => e.connectionStatus, width: 1.4),
    BillingAuditColumn('category', 'Category', (e) => e.categoryLabel, width: 1.3),
    BillingAuditColumn('bills', 'Generated Bills', (e) => '${e.billCount}', width: 0.8),
    BillingAuditColumn('paid', 'Marked Paid', (e) => '${e.paidBillCount}', width: 0.8),
    BillingAuditColumn('unpaid', 'Unpaid', (e) => '${e.unpaidBillCount}', width: 0.8),
    BillingAuditColumn('water', 'Generated Water Fee', (e) => _auditAmount(e.waterFee)),
    BillingAuditColumn('receipts', 'Amount Received (Water)', (e) => _auditAmount(e.waterReceived)),
    BillingAuditColumn('gross_receipts', 'Cash Receipts', (e) => _auditAmount(e.cashReceived)),
    BillingAuditColumn('recorded_receipts', 'Recorded Receipts (including credit applications)', (e) => _auditAmount(e.received)),
    BillingAuditColumn('advance_applied', 'Advance Applied (not new cash)', (e) => _auditAmount(e.advanceApplied)),
    BillingAuditColumn('advance_remaining', 'Unapplied Receipts / Advance Credit', (e) => _auditAmount(e.advanceBalance)),
    BillingAuditColumn('excluded_bills', 'Older Overlapping Bills Excluded', (e) => e.excludedBillNumbers.join(', ')),
    BillingAuditColumn('fine_collected', 'Fine Collected', (e) => _auditAmount(e.fineCollected)),
    BillingAuditColumn('unpaid_fine', 'Unpaid Fine', (e) => _auditAmount(e.outstandingFine)),
    BillingAuditColumn('balance', 'Water Balance', (e) => _auditAmount(e.payableBalance)),
    BillingAuditColumn('paid_short', 'Paid Bills With Short Receipt', (e) => '${e.paidShortCount}', width: 0.9),
    BillingAuditColumn('result', 'Result', (e) => e.result, width: 1.4),
    BillingAuditColumn('review', 'Review Reasons', (e) => [...e.reviewReasons, if (e.confirmedPaymentCount > 0) 'Confirmed sector payment exception: ${e.confirmedPaymentCount} bill(s), principal added Rs. ${(e.confirmedPaymentAdjustment / 100).toStringAsFixed(2)}'].join('; '), width: 2.8),
    BillingAuditColumn('missing_bill_count', 'Missing Bill Count', (e) => '${e.coverage?.missingBillCount ?? 0}'),
    BillingAuditColumn('missing_periods', 'Missing Billing Periods', (e) => e.coverage?.missingPeriods.map((p) => p.label).join('; ') ?? '', width: 2.8),
    BillingAuditColumn('missing_water_fee', 'Estimated Missing Water Fee', (e) => _auditAmount(e.coverage?.estimatedMissingFee)),
    BillingAuditColumn('short_fee_count', 'Bills With Short Water Fee', (e) => '${e.coverage?.shortFees.length ?? 0}'),
    BillingAuditColumn('short_fee_amount', 'Estimated Water Fee Shortfall', (e) => _auditAmount(e.coverage?.shortFeeAmount)),
    BillingAuditColumn('coverage_notes', 'Billing Coverage Notes', (e) => e.coverage?.warningText(_auditAmount) ?? '', width: 3),
    BillingAuditColumn('expected_water_fee', 'Expected Water Fee', (e) => _auditAmount(e.coverage?.expectedWaterFee)),
    BillingAuditColumn('missing_amount', 'Total Missing Amount', (e) => _auditAmount(e.coverage?.estimatedMissingAmount)),
  ];

  static const defaultBillingAuditPdfColumns = {
    'connection', 'consumer', 'sector', 'bills', 'paid', 'unpaid', 'water', 'receipts', 'fine_collected', 'unpaid_fine', 'balance', 'result',
  };
  static const defaultMissingAmountsPdfColumns = {
    'connection', 'consumer', 'sector', 'water', 'missing_bill_count',
    'missing_amount', 'coverage_notes',
  };

  static String billingAuditCsv(List<BillingAuditEntry> entries) {
    String cell(Object value) {
      var text = value.toString();
      if (RegExp(r'^\s*[=+@-]').hasMatch(text)) text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }
    final rows = <List<Object>>[
      billingAuditColumns.map((c) => c.label).toList(),
      for (final e in entries) billingAuditColumns.map((c) => c.value(e)).toList(),
    ];
    return '\ufeff${rows.map((row) => row.map(cell).join(',')).join('\r\n')}\r\n';
  }

  Future<String?> exportBillingAudit(List<BillingAuditEntry> entries) async {
    final now = DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now());
    final uri = await FilePicker.saveFile(
      fileName: 'Water_Fee_Audit_$now.csv',
      bytes: Uint8List.fromList(utf8.encode(billingAuditCsv(entries))),
      dialogTitle: 'Save filtered water fee audit',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    return uri?.toString();
  }

  Future<Uint8List> generateBillingAuditPdf({
    required List<BillingAuditEntry> entries,
    required Set<String> selectedColumnKeys,
    String filterSummary = 'All connections',
  }) async {
    final columns = billingAuditColumns.where((c) => selectedColumnKeys.contains(c.key)).toList();
    if (columns.isEmpty) throw ArgumentError('Select at least one report column.');
    final document = pw.Document();
    final size = columns.length > 16 ? const PdfPageFormat(594 * PdfPageFormat.mm, 420 * PdfPageFormat.mm)
        : columns.length > 12 ? PdfPageFormat.a3.landscape
        : columns.length > 5 ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
    final fontSize = columns.length > 12 && columns.length <= 16 ? 8.0 : 9.0;
    document.addPage(pw.MultiPage(
      pageFormat: size, maxPages: entries.length + 2,
      margin: const pw.EdgeInsets.all(28),
      theme: pw.ThemeData.withFont(base: pw.Font.helvetica(), bold: pw.Font.helveticaBold()),
      header: (_) => pw.Padding(padding: const pw.EdgeInsets.only(bottom: 10), child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Water Fee Audit - Generated Bills & Recovery', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 5),
          pw.Text(filterSummary, style: const pw.TextStyle(fontSize: 9)),
          pw.Text('${entries.length} connections | Generated: ${DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now())} | Amounts in Rs.', style: const pw.TextStyle(fontSize: 9)),
        ])),
      footer: (context) => pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Water Balance = Water Fee - Water Received. Fines and advance credit applications are separate.', style: const pw.TextStyle(fontSize: 8)),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
        ])),
      build: (_) => [pw.TableHelper.fromTextArray(
        headers: columns.map((c) => c.label).toList(),
        data: [for (final entry in entries) columns.map((c) => c.value(entry).isEmpty ? '-' : c.value(entry)).toList()],
        columnWidths: {for (var i = 0; i < columns.length; i++) i: pw.FlexColumnWidth(columns[i].width)},
        headerStyle: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold),
        cellStyle: pw.TextStyle(fontSize: fontSize),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 7),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
        cellAlignment: pw.Alignment.centerLeft,
        border: pw.TableBorder.all(width: 0.4, color: PdfColors.grey600),
      )],
    ));
    return document.save();
  }

  /// Export CSV Backup
  Future<String?> exportCsvBackup({List<Consumer>? consumers}) async {
    final now = DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now());
    final defaultFileName = 'Consumer_Backup_$now.csv';

    List<Consumer> dataToExport = consumers ?? [];
    if (dataToExport.isEmpty) {
      // Export all records from database
      final res = await DatabaseService.instance.searchConsumers(
        pageSize: 100000,
      );
      dataToExport = res.items;
    }

    final buffer = StringBuffer();
    // Write CSV Header
    buffer.writeln(
      'Sr #,Consumer Name,F/H Name,Mobile,Sector,Locality,Address,Order No. / Register No,Rate Type,Connection No.,Old Connection No.,Connection Date,Status,Consumer Status',
    );

    for (final c in dataToExport) {
      String sanitize(String val) {
        if (val.contains(',') || val.contains('"') || val.contains('\n')) {
          return '"${val.replaceAll('"', '""')}"';
        }
        return val;
      }

      buffer.writeln([
        c.srNo,
        sanitize(c.consumerName),
        sanitize(c.fatherHusbandName),
        sanitize(c.mobile),
        sanitize(c.sector),
        sanitize(c.locality),
        sanitize(c.address),
        sanitize(c.orderNo),
        sanitize(c.rateType),
        sanitize(c.connectionNo),
        sanitize(c.oldConnectionNo),
        sanitize(c.connectionDate),
        sanitize(c.connectionStatus),
        sanitize(c.consumerStatus),
      ].join(','));
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final saveUri = await FilePicker.saveFile(
      fileName: defaultFileName,
      bytes: bytes,
      dialogTitle: 'Save CSV Backup',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );

    return saveUri?.toString();
  }

  /// Export only Connection Numbers to CSV
  Future<String?> exportConnectionNumbersCsv({
    required List<String> connectionNumbers,
    String? fileNamePrefix,
  }) async {
    final now = DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now());
    final defaultFileName = '${fileNamePrefix ?? "Connection_Numbers"}_$now.csv';

    final buffer = StringBuffer();
    // CSV Header: Connection No
    buffer.writeln('Connection No');

    for (final connNo in connectionNumbers) {
      final trimmed = connNo.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains(',') || trimmed.contains('"') || trimmed.contains('\n')) {
        buffer.writeln('"${trimmed.replaceAll('"', '""')}"');
      } else {
        buffer.writeln(trimmed);
      }
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final saveUri = await FilePicker.saveFile(
      fileName: defaultFileName,
      bytes: bytes,
      dialogTitle: 'Save Connection Numbers CSV',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );

    return saveUri?.toString();
  }

  /// Export raw SQLite Database file backup
  Future<String?> exportDatabaseBackup() async {
    final bytes = await DatabaseService.instance.createDatabaseBackup();
    final now = DateFormat('dd-MM-yyyy_HHmm').format(DateTime.now());
    final defaultFileName = 'consumer_database_backup_$now.db';

    final saveUri = await FilePicker.saveFile(
      fileName: defaultFileName,
      bytes: bytes,
      dialogTitle: 'Save SQLite Database Backup (.db)',
      allowedExtensions: ['db', 'sqlite'],
      type: FileType.custom,
    );

    return saveUri?.toString();
  }
}
