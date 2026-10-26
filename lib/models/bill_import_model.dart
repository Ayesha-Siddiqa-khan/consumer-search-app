import 'bill_history_model.dart';
import 'bill_amount.dart' show auditAmountInPaisa;

final _importDate = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$');

String billIdentity(String connection, String bill) =>
    '${connection.trim().toUpperCase()}|${bill.trim().toUpperCase()}';

String? historyPeriodIdentity(BillHistory bill) {
  final match = RegExp(
    r'^(\d{1,2}[/-]\d{1,2}[/-]\d{4})\s*-\s*(\d{1,2}[/-]\d{1,2}[/-]\d{4})$',
  ).firstMatch(bill.billingPeriod.trim());
  if (match == null || bill.billType.trim().isEmpty) return null;
  final start = validImportDate(match[1]);
  final end = validImportDate(match[2]);
  if (start == null || end == null) return null;
  return '${bill.connectionNo.trim().toUpperCase()}|${bill.billType.trim().toUpperCase()}|$start|$end';
}

String? validImportDate(String? value) {
  final match = _importDate.firstMatch((value ?? '').trim());
  if (match == null) return null;
  final day = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final year = int.parse(match[3]!);
  final date = DateTime(year, month, day);
  return date.day == day && date.month == month && date.year == year
      ? '${match[1]!.padLeft(2, '0')}/${match[2]!.padLeft(2, '0')}/$year'
      : null;
}

const importMoneyFields = {
  'arrears',
  'water_fee',
  'sanitation',
  'drainage',
  'billing_fee',
  'total_bill',
  'fine',
  'after_due_date',
  'amount_received',
};

int? importAmountInPaisa(Object? value) {
  final text = (value ?? '').toString().trim();
  if (text.startsWith('-')) {
    final absolute = auditAmountInPaisa(text.substring(1));
    return absolute == null ? null : -absolute;
  }
  return auditAmountInPaisa(text);
}

const negativeCreditReviewIssue =
    'Negative credit / adjustment preserved from source; review required';

bool hasConsistentAdvanceCredit(Map<String, Object?> bill) {
  final arrears = importAmountInPaisa(bill['arrears']);
  if (arrears == null || arrears >= 0) return false;
  final total = importAmountInPaisa(bill['total_bill']);
  final after = importAmountInPaisa(bill['after_due_date']);
  final fine = auditAmountInPaisa(bill['fine'] ?? '0');
  final charges = [
    'water_fee',
    'sanitation',
    'drainage',
    'billing_fee',
  ].map((field) => auditAmountInPaisa(bill[field] ?? '0')).toList();
  return total != null &&
      fine != null &&
      after == total + fine &&
      !charges.contains(null) &&
      total == arrears + charges.fold<int>(0, (sum, charge) => sum + charge!);
}

/// Some history rows repeat the water covered by an earlier advance as received.
int advanceAppliedInReceipt(Map<String, Object?> bill) {
  if (!hasConsistentAdvanceCredit(bill)) return 0;
  final receipt = auditAmountInPaisa(bill['amount_received']);
  if (receipt == null || receipt == 0) return 0;
  final arrears = importAmountInPaisa(bill['arrears'])!;
  final total = importAmountInPaisa(bill['total_bill'])!;
  final charges = total - arrears;
  if (total > 0 && receipt < charges) return 0;
  return (-arrears).clamp(0, charges).clamp(0, receipt);
}

Object? comparableBillValue(String key, Object? value) =>
    importMoneyFields.contains(key)
    ? importAmountInPaisa(value)
    : (value ?? '').toString().trim().toUpperCase();

class ImportedBill {
  final BillHistory bill;
  final Set<String> fields;
  final String asOf;
  final String source;
  const ImportedBill(this.bill, this.fields, this.asOf, this.source);
  String get key => billIdentity(bill.connectionNo, bill.billNo);

  bool agreesWith(ImportedBill other) {
    final a = bill.toMap();
    final b = other.bill.toMap();
    for (final field in fields.intersection(other.fields)) {
      if (['sr_no', 'created_at'].contains(field)) continue;
      if (comparableBillValue(field, a[field]) !=
          comparableBillValue(field, b[field])) {
        return false;
      }
    }
    return true;
  }
}

class BillMergeReport {
  int inserted = 0;
  int updated = 0;
  int unchanged = 0;
  int held = 0;
  int consumersUpdated = 0;
  int duplicateRows = 0;
  int superseded = 0;
  final List<Map<String, String>> issues = [];
  void issue(String key, String reason, String source) {
    final split = key.split('|');
    issues.add({
      'connection_no': split.first,
      'bill_no': split.last,
      'reason': reason,
      'source': source,
    });
  }
}
