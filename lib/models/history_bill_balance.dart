import 'bill_history_model.dart';
import 'bill_import_model.dart'
    show validImportDate, hasConsistentAdvanceCredit, importAmountInPaisa;
import 'bill_amount.dart' show auditAmountInPaisa;

DateTime? historyBillDate(String raw) {
  final normalized = validImportDate(raw);
  if (normalized != null) {
    final parts = normalized.split('/').map(int.parse).toList();
    return DateTime(parts[2], parts[1], parts[0]);
  }
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
  return iso == null ? null : historyBillDate('${iso[3]}/${iso[2]}/${iso[1]}');
}

/// Bill numbers reflect generation order; payment dates do not create new bills.
int compareHistoryBillsNewestFirst(BillHistory a, BillHistory b) {
  final numberA = int.tryParse(a.billNo);
  final numberB = int.tryParse(b.billNo);
  if (numberA != null && numberB != null && numberA != numberB) {
    return numberB.compareTo(numberA);
  }
  DateTime? date(BillHistory bill) {
    final dates = RegExp(
      r'\d{1,2}[/-]\d{1,2}[/-]\d{4}',
    ).allMatches(bill.billingPeriod).toList();
    return (dates.isEmpty ? null : historyBillDate(dates.last[0]!)) ??
        historyBillDate(bill.dueDate);
  }

  final dateA = date(a);
  final dateB = date(b);
  if (dateA != null && dateB != null && dateA != dateB) {
    return dateB.compareTo(dateA);
  }
  return b.billNo.compareTo(a.billNo);
}

class HistoryBillBalance {
  final BillHistory? bill;

  /// Remaining amount in integer paisa; null requires review.
  final int? amount;
  final String basis;
  const HistoryBillBalance(this.bill, this.amount, this.basis);

  int? get outstandingFine {
    if (amount == null) return null;
    if (bill == null || amount == 0) return 0;
    final total = hasConsistentAdvanceCredit(bill!.toMap())
        ? importAmountInPaisa(bill!.totalBill)
        : auditAmountInPaisa(bill!.totalBill);
    final receipt = auditAmountInPaisa(bill!.amountReceived);
    if (total == null || receipt == null) return null;
    final principalRemaining = (total - receipt).clamp(
      0,
      total < 0 ? 0 : total,
    );
    return (amount! - principalRemaining).clamp(0, amount!);
  }
}

/// The latest bill already includes carried arrears. Never sum older unpaid rows.
HistoryBillBalance latestHistoryBillBalance(
  List<BillHistory> bills, {
  DateTime? asOf,
}) {
  if (bills.isEmpty) {
    return const HistoryBillBalance(null, 0, 'No generated bills');
  }
  final latest = (List<BillHistory>.of(
    bills,
  )..sort(compareHistoryBillsNewestFirst)).first;
  final status = latest.status.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (status == 'paid') {
    return HistoryBillBalance(latest, 0, 'Latest bill is paid');
  }
  if (status == 'expired') {
    return HistoryBillBalance(latest, 0, 'Expired bill carried forward');
  }
  if (status != 'unpaid') {
    return HistoryBillBalance(latest, null, 'Latest bill status needs review');
  }
  final advanceCredit = hasConsistentAdvanceCredit(latest.toMap());
  final sourceTotal = advanceCredit
      ? importAmountInPaisa(latest.totalBill)
      : auditAmountInPaisa(latest.totalBill);
  final total = sourceTotal == null
      ? null
      : (sourceTotal < 0 ? 0 : sourceTotal);
  final receipt = auditAmountInPaisa(latest.amountReceived);
  if (total == null || receipt == null) {
    return HistoryBillBalance(latest, null, 'Latest bill amounts need review');
  }
  final due = historyBillDate(latest.dueDate);
  final now = asOf ?? DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (due != null && !today.isAfter(due)) {
    return HistoryBillBalance(
      latest,
      (total - receipt).clamp(0, total),
      'Within due date',
    );
  }
  final sourceAfterDue = advanceCredit
      ? importAmountInPaisa(latest.afterDueDate)
      : auditAmountInPaisa(latest.afterDueDate);
  final afterDue = sourceAfterDue == null
      ? null
      : (sourceAfterDue < 0 ? 0 : sourceAfterDue);
  final fine = auditAmountInPaisa(latest.fine);
  final payable = afterDue == 0 && fine == 0 ? total : afterDue;
  if (payable == null || payable < total) {
    return HistoryBillBalance(latest, null, 'After-due amount needs review');
  }
  if (due == null && payable != total) {
    return HistoryBillBalance(
      latest,
      null,
      'Due date missing: confirm applicable amount',
    );
  }
  return HistoryBillBalance(
    latest,
    (payable - receipt).clamp(0, payable),
    due == null
        ? 'No late-fine difference'
        : 'After due date (includes applicable late fine)',
  );
}
