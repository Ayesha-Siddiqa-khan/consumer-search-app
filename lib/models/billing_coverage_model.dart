import 'bill_amount.dart';

/// Missing history is diagnostic evidence, never an additional payable charge.
class BillingPeriodGap {
  final DateTime start;
  final DateTime end;
  final int? estimatedFee;
  const BillingPeriodGap(this.start, this.end, this.estimatedFee);

  String get label => '${_date(start)} - ${_date(end)}';
}

class BillingFeeShortfall {
  final String billNo;
  final String period;
  final int amount;
  const BillingFeeShortfall(this.billNo, this.period, this.amount);
}

class BillingCoverage {
  final List<BillingPeriodGap> missingPeriods;
  final List<BillingFeeShortfall> shortFees;
  final List<String> undatedBills;
  final int? monthlyWaterRate;
  final int? expectedWaterFee;
  final bool variableRates;
  final bool standardRateEstimate;
  final DateTime checkedThrough;
  final bool hasRecordedHistory;

  const BillingCoverage({
    required this.missingPeriods,
    required this.shortFees,
    required this.undatedBills,
    required this.monthlyWaterRate,
    required this.expectedWaterFee,
    required this.variableRates,
    required this.standardRateEstimate,
    required this.checkedThrough,
    required this.hasRecordedHistory,
  });

  int get missingBillCount => missingPeriods.length;
  int? get estimatedMissingFee => monthlyWaterRate == null
      ? null
      : missingPeriods.fold<int>(0, (sum, gap) => sum + gap.estimatedFee!);
  int get shortFeeAmount => shortFees.fold(0, (sum, bill) => sum + bill.amount);
  int? get estimatedMissingAmount => estimatedMissingFee == null
      ? null
      : estimatedMissingFee! + shortFeeAmount;
  bool get hasShortBills => missingPeriods.isNotEmpty || shortFees.isNotEmpty;
  bool get hasWarning =>
      hasShortBills || undatedBills.isNotEmpty || variableRates;

  String warningText(String Function(int?) money) {
    final lines = <String>[];
    if (!hasRecordedHistory) {
      lines.add(
        'No regular bill history is available. The periods below are absent from the import; issuance is unconfirmed.',
      );
    }
    if (missingPeriods.isNotEmpty) {
      lines.add(
        '${undatedBills.isEmpty ? 'Missing' : 'Possible missing'} bills: '
        '$missingBillCount; estimated water fees: '
        '${estimatedMissingFee == null ? 'rate confirmation needed' : money(estimatedMissingFee)}.',
      );
      for (final gap in missingPeriods) {
        lines.add(
          '${gap.label}: ${gap.estimatedFee == null ? 'amount unconfirmed' : money(gap.estimatedFee)}',
        );
      }
    }
    if (shortFees.isNotEmpty) {
      lines.add(
        'Bills present with short water fees: ${shortFees.length}; '
        'estimated shortfall: ${money(shortFeeAmount)}.',
      );
      for (final bill in shortFees) {
        lines.add(
          'Bill ${bill.billNo}, ${bill.period}: ${money(bill.amount)} short',
        );
      }
    }
    if (undatedBills.isNotEmpty) {
      lines.add(
        'Billing period missing or unusable on bills '
        '${undatedBills.join(', ')}. These may cover the gaps; confirm from source.',
      );
    }
    if (variableRates) {
      lines.add(
        'Recorded water rates vary; confirm the rate before assigning a missing amount.',
      );
    }
    if (hasShortBills) {
      lines.add(
        'Coverage checked from 01-07-2023 through ${_date(checkedThrough)}. '
        '${standardRateEstimate ? 'Amounts use the standard category rate. ' : ''}'
        'Not added to generated fees or payable balance; verify the original history.',
      );
    }
    return lines.join('\n');
  }
}

String _date(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.year}';

/// The user-confirmed calendar: half-yearly except Jul-Sep 2025 monthly and
/// Oct-Dec 2025 quarterly. Annual or other combined bills cover their months once.
List<({int start, int end})> expectedBillingPeriods(DateTime asOf) {
  final lastMonth = asOf.year == 2025 && asOf.month >= 7 && asOf.month <= 9
      ? asOf.year * 12 + asOf.month - 1
      : asOf.year * 12 + (asOf.month <= 6 ? 5 : 11);
  final result = <({int start, int end})>[];
  for (var month = 2023 * 12 + 6; month <= lastMonth;) {
    final length = month >= 2025 * 12 + 6 && month <= 2025 * 12 + 8
        ? 1
        : month == 2025 * 12 + 9
        ? 3
        : 6;
    result.add((start: month, end: month + length - 1));
    month += length;
  }
  return result;
}

BillingCoverage buildBillingCoverage({
  required List<Map<String, Object?>> bills,
  required Map<String, List<DateTime>> periods,
  required List<({int start, int end})> schedule,
  required String category,
}) {
  final covered = <int>{};
  final undated = <String>[];
  final rates = <int>{};
  final dated = <({String number, int start, int end, int? fee})>[];
  for (final bill in bills) {
    final range = periods['${bill['billing_period'] ?? ''}'] ?? [];
    final number = '${bill['bill_no'] ?? ''}';
    final fee = auditAmountInPaisa(bill['water_fee']);
    if (range.length != 2) {
      undated.add(number);
      continue;
    }
    // One-day, zero-water arrears adjustments do not establish a billing month.
    if (range.first == range.last && fee == 0) continue;
    final start = range.first.year * 12 + range.first.month - 1;
    final end = range.last.year * 12 + range.last.month - 1;
    if (schedule.isEmpty ||
        end < schedule.first.start ||
        start > schedule.last.end) {
      continue;
    }
    final months = end - start + 1;
    // Only intersect the requested window, even if a malformed source spans years.
    for (final slot in schedule) {
      for (var month = slot.start; month <= slot.end; month++) {
        if (month >= start && month <= end) covered.add(month);
      }
    }
    final wholeMonths =
        range.first.day == 1 &&
        range.last.day ==
            DateTime.utc(range.last.year, range.last.month + 1, 0).day;
    if (wholeMonths) {
      dated.add((number: number, start: start, end: end, fee: fee));
      if (fee != null && fee > 0 && fee % months == 0) rates.add(fee ~/ months);
    }
  }
  final standard =
      rates.isEmpty && (category == 'domestic' || category == 'private');
  final rate = rates.length == 1
      ? rates.single
      : standard
      ? (category == 'domestic' ? 40000 : 80000)
      : null;
  final gaps = <BillingPeriodGap>[];
  for (final slot in schedule) {
    var month = slot.start;
    while (month <= slot.end) {
      if (covered.contains(month)) {
        month++;
        continue;
      }
      final start = month;
      while (month <= slot.end && !covered.contains(month)) {
        month++;
      }
      gaps.add(
        BillingPeriodGap(
          DateTime.utc(start ~/ 12, start % 12 + 1),
          DateTime.utc((month - 1) ~/ 12, (month - 1) % 12 + 2, 0),
          rate == null ? null : (month - start) * rate,
        ),
      );
    }
  }
  final shorts = <BillingFeeShortfall>[];
  if (rate != null && schedule.isNotEmpty) {
    for (final bill in dated) {
      if (bill.fee == null ||
          bill.start < schedule.first.start ||
          bill.end > schedule.last.end) {
        continue;
      }
      final short = (bill.end - bill.start + 1) * rate - bill.fee!;
      if (short > 0) {
        shorts.add(
          BillingFeeShortfall(
            bill.number,
            '${_date(DateTime.utc(bill.start ~/ 12, bill.start % 12 + 1))} - '
            '${_date(DateTime.utc(bill.end ~/ 12, bill.end % 12 + 2, 0))}',
            short,
          ),
        );
      }
    }
  }
  final months = schedule.fold<int>(
    0,
    (sum, slot) => sum + slot.end - slot.start + 1,
  );
  return BillingCoverage(
    missingPeriods: gaps,
    shortFees: shorts,
    undatedBills: undated,
    monthlyWaterRate: rate,
    expectedWaterFee: rate == null ? null : rate * months,
    variableRates: rates.length > 1,
    standardRateEstimate: standard,
    checkedThrough: schedule.isEmpty
        ? DateTime.utc(2023, 7, 1)
        : DateTime.utc(schedule.last.end ~/ 12, schedule.last.end % 12 + 2, 0),
    hasRecordedHistory: bills.isNotEmpty,
  );
}
