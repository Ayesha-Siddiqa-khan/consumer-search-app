import 'bill_amount.dart';

/// Evidence comes from active imported history, after superseded bills are removed.
class AuditBillPeriod {
  final String billNo;
  final DateTime? start;
  final DateTime? end;
  final String? confirmation;
  const AuditBillPeriod(this.billNo, this.start, this.end, {this.confirmation});
}

/// This user-confirmed exception establishes coverage only, never a new charge.
/// Scope it to the exact connection/bill; other arrears entries are not evidence.
List<AuditBillPeriod> resolveAuditBillPeriods(
  List<Map<String, Object?>> bills,
  Map<String, List<DateTime>> periods,
) => [
  for (final bill in bills)
    if ('${bill['connection_no']}'.trim().toUpperCase() == '13010340' &&
        '${bill['bill_no']}'.trim() == '5986238' &&
        '${bill['bill_type']}'.toLowerCase().trim() == 'arrears')
      AuditBillPeriod(
        '5986238',
        DateTime(2025, 7, 1),
        DateTime(2025, 12, 31),
        confirmation:
            'Confirmed replacement: connection 13010340, bill 5986238 covers 01/07/2025 - 31/12/2025. Recorded period: ${bill['billing_period']}. Original Water Fee and account totals are unchanged.',
      )
    else if (!((periods['${bill['billing_period']}'] ?? []).length == 2 &&
        periods['${bill['billing_period']}']!.first ==
            periods['${bill['billing_period']}']!.last &&
        auditAmountInPaisa(bill['water_fee']) == 0))
      AuditBillPeriod(
        '${bill['bill_no'] ?? ''}',
        (periods['${bill['billing_period']}'] ?? []).firstOrNull,
        (periods['${bill['billing_period']}'] ?? []).length == 2
            ? periods['${bill['billing_period']}']!.last
            : null,
      ),
];

String auditDateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

/// Only complete calendar billing-session boundaries are offered in the UI.
List<({DateTime start, DateTime end})> auditBillingSessions(DateTime asOf) => [
  for (
    var start = DateTime(2023, 7, 1);
    !start.isAfter(DateTime(asOf.year, asOf.month, asOf.day));
    start = DateTime(start.year, start.month + 6)
  )
    (start: start, end: DateTime(start.year, start.month + 6, 0)),
];

class AuditDateGap {
  final DateTime start;
  final DateTime end;
  const AuditDateGap(this.start, this.end);
  String get label => '${auditDateLabel(start)} - ${auditDateLabel(end)}';
}

class AuditSessionCheck {
  final DateTime start;
  final DateTime end;
  final List<AuditDateGap> gaps;
  const AuditSessionCheck(this.start, this.end, this.gaps);
  bool get complete => gaps.isEmpty;
  String get shortLabel =>
      '${start.month <= 6 ? 'Jan-Jun' : 'Jul-Dec'} ${start.year}';
  String get label => '${auditDateLabel(start)} - ${auditDateLabel(end)}';
}

class AuditPeriodCheck {
  final DateTime from;
  final DateTime to;
  final List<AuditSessionCheck> sessions;
  final List<String> undatedBills;
  final List<String> confirmations;
  const AuditPeriodCheck(
    this.from,
    this.to,
    this.sessions,
    this.undatedBills, {
    this.confirmations = const [],
  });
  int get completeSessions => sessions.where((s) => s.complete).length;
  bool get present => completeSessions == sessions.length;
  String get periodLabel => '${auditDateLabel(from)} - ${auditDateLabel(to)}';
  String get presenceLabel => present
      ? 'Present'
      : undatedBills.isEmpty
      ? 'Missing / incomplete'
      : 'Unconfirmed gaps';
  String get sessionSummary =>
      '$completeSessions/${sessions.length} sessions complete';
  String get missingSessions => sessions
      .where((s) => !s.complete)
      .map(
        (s) => '${s.label}: missing ${s.gaps.map((g) => g.label).join(', ')}',
      )
      .join('\n');
  String get missingSessionLabels =>
      sessions.where((s) => !s.complete).map((s) => s.shortLabel).join(', ');
  String get details => [
    '$presenceLabel: $periodLabel',
    sessionSummary,
    if (!present) missingSessions,
    if (undatedBills.isNotEmpty)
      'Unusable billing period on bill(s): ${undatedBills.join(', ')}. Any unfilled dates require source review.',
    ...confirmations,
  ].join('\n');
}

DateTime _day(DateTime date) => DateTime.utc(date.year, date.month, date.day);

/// Count calendar half-years by covered dates, never by number of source rows or
/// fees. Jul/Aug/Sep/Oct-Dec 2025 therefore form one complete Jul-Dec session.
AuditPeriodCheck checkAuditPeriod(
  List<AuditBillPeriod> bills,
  DateTime from,
  DateTime to,
) {
  from = _day(from);
  to = _day(to);
  if (from.isAfter(to)) {
    throw ArgumentError('The end date must be on or after the start date.');
  }
  final ranges = <({DateTime start, DateTime end})>[];
  final undated = <String>{};
  final confirmations = <String>{};
  for (final bill in bills) {
    if (bill.start == null ||
        bill.end == null ||
        bill.start!.isAfter(bill.end!)) {
      undated.add(bill.billNo);
    } else {
      ranges.add((start: _day(bill.start!), end: _day(bill.end!)));
      if (bill.confirmation != null &&
          !bill.end!.isBefore(from) &&
          !bill.start!.isAfter(to)) {
        confirmations.add(bill.confirmation!);
      }
    }
  }
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final sessions = <AuditSessionCheck>[];
  for (
    var start = DateTime.utc(from.year, from.month <= 6 ? 1 : 7);
    !start.isAfter(to);
    start = DateTime.utc(start.year, start.month + 6)
  ) {
    final end = DateTime.utc(start.year, start.month + 6, 0);
    final selectedStart = start.isBefore(from) ? from : start;
    final selectedEnd = end.isAfter(to) ? to : end;
    var cursor = selectedStart;
    final gaps = <AuditDateGap>[];
    for (final range in ranges) {
      if (range.end.isBefore(cursor)) continue;
      if (range.start.isAfter(selectedEnd)) break;
      if (range.start.isAfter(cursor)) {
        gaps.add(
          AuditDateGap(cursor, range.start.subtract(const Duration(days: 1))),
        );
      }
      final next = range.end.add(const Duration(days: 1));
      if (next.isAfter(cursor)) cursor = next;
      if (cursor.isAfter(selectedEnd)) break;
    }
    if (!cursor.isAfter(selectedEnd)) {
      gaps.add(AuditDateGap(cursor, selectedEnd));
    }
    sessions.add(AuditSessionCheck(start, end, gaps));
  }
  return AuditPeriodCheck(
    from,
    to,
    sessions,
    undated.toList(),
    confirmations: confirmations.toList(),
  );
}
