import 'bill_amount.dart';
import 'audit_period_check.dart';
import 'bill_history_model.dart';
import 'billing_coverage_model.dart';
import 'bill_import_model.dart'
    show
        advanceAppliedInReceipt,
        hasConsistentAdvanceCredit,
        importAmountInPaisa,
        negativeCreditReviewIssue;
import 'history_bill_balance.dart';
export 'bill_amount.dart' show auditAmountInPaisa;

final _nonLetters = RegExp(r'[^a-z]');
final _periodDates = RegExp(r'\d{1,2}[/-]\d{1,2}[/-]\d{4}');
final _confirmedPeriodDates = RegExp(r'\d{2}[/\-]\d{2}[/\-]\d{4}');

/// All amounts are integer paisa. Ungenerated periods never create a debt.
class BillingAuditEntry {
  final String connectionNo;
  final String consumerName;
  final String fatherHusbandName;
  final String sector;
  final String locality;
  final String address;
  final String connectionDate;
  final String connectionStatus;
  final String consumerStatus;
  final String currentBillStatus;
  final String category;
  final String billGroup;
  final int billCount;
  final int paidBillCount;
  final int unpaidBillCount;
  final int expiredBillCount;
  final int paidShortCount;
  final int? waterFee;
  final int? received;
  final int? waterReceiptLimit;
  final int knownNonWaterReceived;
  final int fineCollected;
  final int advanceApplied;
  final int advanceBalance;
  final List<String> excludedBillNumbers;
  final int? outstandingFine;
  final int confirmedPaymentCount;
  final int confirmedPaymentAdjustment;
  final bool allocationNeedsReview;
  final bool invalidHistory;
  final List<String> reviewReasons;
  final BillingCoverage? coverage;
  final List<AuditBillPeriod> periodBills;

  const BillingAuditEntry({
    required this.connectionNo,
    required this.consumerName,
    required this.fatherHusbandName,
    required this.sector,
    required this.locality,
    required this.address,
    required this.connectionDate,
    required this.connectionStatus,
    required this.consumerStatus,
    required this.currentBillStatus,
    required this.category,
    required this.billGroup,
    required this.billCount,
    required this.paidBillCount,
    required this.unpaidBillCount,
    required this.expiredBillCount,
    required this.paidShortCount,
    required this.waterFee,
    required this.received,
    required this.waterReceiptLimit,
    required this.knownNonWaterReceived,
    required this.fineCollected,
    this.advanceApplied = 0,
    this.advanceBalance = 0,
    this.excludedBillNumbers = const [],
    required this.outstandingFine,
    required this.confirmedPaymentCount,
    required this.confirmedPaymentAdjustment,
    required this.allocationNeedsReview,
    required this.invalidHistory,
    required this.reviewReasons,
    this.coverage,
    this.periodBills = const [],
  });

  /// Difference between the two recorded columns; receipts may include fines.
  int? get recordedDifference =>
      waterFee == null || received == null ? null : waterFee! - received!;

  bool get needsReview => reviewReasons.isNotEmpty;
  String get billGroupLabel => billingAuditGroups[billGroup]!;

  /// Audit difference is independent of the history page's latest payable bill.
  int? get difference =>
      invalidHistory || waterFee == null || waterReceiptLimit == null
      ? null
      : waterFee! - waterReceiptLimit! + advanceBalance;
  int? get cashReceived => received == null ? null : received! - advanceApplied;
  int? get waterReceived => invalidHistory || waterReceiptLimit == null
      ? null
      : waterReceiptLimit! - advanceBalance;
  int? get payableBalance => difference;
  String get result => billCount == 0
      ? 'No generated bills'
      : payableBalance == null
      ? 'Needs review'
      : payableBalance! > 0
      ? 'Water balance due'
      : payableBalance! < 0
      ? 'Receipts exceed water fee'
      : allocationNeedsReview
      ? 'Review allocation'
      : needsReview
      ? 'Needs review'
      : 'No water balance';

  String get categoryLabel => switch (category) {
    'domestic' => 'Domestic',
    'private' => 'Private Societies',
    'commercial' => 'Commercial',
    _ => 'Unclassified',
  };
}

const billingAuditGroups = {
  'regular': 'Regular / other bills',
  'new_connection': 'New Connection bills',
  'all': 'All generated bills',
};

bool isNewConnectionBill(Object? type) => (type ?? '')
    .toString()
    .toLowerCase()
    .replaceAll(_nonLetters, '')
    .contains('newconnection');

const billingCategoryOverrides = {
  '10010100': 'domestic',
  '66160006': 'commercial',
  '66050050': 'commercial',
};

String billingCategory(String raw) {
  final rate = raw.toUpperCase();
  if (rate.contains('COMMERCIAL') || rate.contains('COMERCIAL')) {
    return 'commercial';
  }
  if (rate.contains('PRIVATE')) return 'private';
  if (rate.contains('DOMESTIC') || rate.contains('6 MONTH JAN26 TO JUNE26')) {
    return 'domestic';
  }
  return 'unknown';
}

List<BillingAuditEntry> buildBillingAudit({
  required List<Map<String, Object?>> consumers,
  required List<Map<String, Object?>> bills,
  String billGroup = 'all',
  DateTime? asOf,
}) {
  if (!billingAuditGroups.containsKey(billGroup)) {
    throw ArgumentError.value(billGroup, 'billGroup');
  }
  String value(Map<String, Object?> row, String key) =>
      (row[key] ?? '').toString().trim();
  String connection(Map<String, Object?> row) =>
      value(row, 'connection_no').toUpperCase();
  final masters = <String, List<Map<String, Object?>>>{};
  final histories = <String, List<Map<String, Object?>>>{};
  for (final row in consumers) {
    final key = connection(row);
    if (key.isNotEmpty) masters.putIfAbsent(key, () => []).add(row);
  }
  for (final row in bills) {
    final key = connection(row);
    if (key.isNotEmpty) histories.putIfAbsent(key, () => []).add(row);
  }
  final entries = <BillingAuditEntry>[];
  final periods = <String, List<DateTime>>{};
  final coverageSchedule = expectedBillingPeriods(asOf ?? DateTime.now());
  for (final key in {...masters.keys, ...histories.keys}) {
    final master = masters[key] ?? [];
    final allHistory = histories[key] ?? [];
    var history = allHistory
        .where(
          (b) =>
              billGroup == 'all' ||
              isNewConnectionBill(b['bill_type']) ==
                  (billGroup == 'new_connection'),
        )
        .toList();
    if (billGroup != 'all' &&
        history.isEmpty &&
        (allHistory.isNotEmpty || billGroup == 'new_connection')) {
      continue;
    }
    final detail = master.isNotEmpty ? master.first : allHistory.first;
    final selection = _currentAuditBills(
      history,
      value(detail, 'sector'),
      periods,
    );
    history = selection.bills;
    final categories = master
        .map((r) => billingCategory(value(r, 'rate_type')))
        .toSet();
    final category =
        billingCategoryOverrides[key] ??
        (categories.length == 1 ? categories.single : 'unknown');
    final reasons = <String>[];
    reasons.addAll(
      selection.invalidPeriods.map(
        (number) => 'Invalid billing period: $number',
      ),
    );
    if (master.isEmpty) reasons.add('Missing consumer master');
    var recorded = 0;
    var received = 0;
    var knownNonWater = 0;
    var fineCollected = 0;
    var advanceApplied = 0;
    var confirmedPaymentCount = 0;
    var confirmedPaymentAdjustment = 0;
    var validFees = true;
    var validReceipts = true;
    final unallocatedReceipt = master.any(
      (row) => row['unallocated_receipt_review'] == true,
    );
    var invalidHistory = unallocatedReceipt;
    if (unallocatedReceipt) {
      reasons.add(
        'Receipt on superseded bill needs allocation review before issuing a recovery notice',
      );
    }
    if (billGroup != 'all' &&
        allHistory.any(
          (b) =>
              isNewConnectionBill(b['bill_type']) !=
                  (billGroup == 'new_connection') &&
              (auditAmountInPaisa(b['amount_received']) ?? 0) > 0 &&
              (auditAmountInPaisa(b['arrears']) ?? 0) > 0,
        )) {
      invalidHistory = true;
      reasons.add(
        'Payment on another bill type includes arrears. Review the account in All generated bills.',
      );
    }
    var allocationNeedsReview = selection.invalidPeriods.isNotEmpty;
    final fullyPaidArrears = <String>[];
    final settledWaterReasons = <String>{};
    var paidCount = 0;
    var unpaidCount = 0;
    var expiredCount = 0;
    var paidShortCount = 0;
    final identities = <String>{};
    var count = 0;
    final reconciledHistory = applyConfirmedSectorPayments(
      history,
      value(detail, 'sector'),
    );
    final latestBalance = latestHistoryBillBalance(
      reconciledHistory.map((bill) => BillHistory.fromMap(bill)).toList(),
      asOf: asOf,
    );
    final recoveredFines = <String>{};
    for (final bill in reconciledHistory) {
      if (bill['payment_exception_review'] != null) {
        invalidHistory = true;
        reasons.add(bill['payment_exception_review'] as String);
      }
      if (bill.containsKey('confirmed_payment_adjustment')) {
        confirmedPaymentCount++;
        confirmedPaymentAdjustment +=
            bill['confirmed_payment_adjustment'] as int;
      }
      final billNo = value(bill, 'bill_no').toUpperCase();
      if (billNo.isEmpty) {
        reasons.add('Bill number missing');
        invalidHistory = true;
      } else if (!identities.add(billNo)) {
        reasons.add('Duplicate bill number: $billNo');
        invalidHistory = true;
        continue;
      }
      final advanceCredit = hasConsistentAdvanceCredit(bill);
      var sourceIssues = value(bill, 'import_issues');
      if (advanceCredit) {
        sourceIssues = sourceIssues.replaceAll(negativeCreditReviewIssue, '');
      }
      final importIssues = sourceIssues
          .split(';')
          .map((issue) => issue.trim())
          .where(
            (issue) =>
                issue.isNotEmpty &&
                issue != 'Invalid source due_date' &&
                issue != 'History name differs from consumer master' &&
                issue != 'identity not reassigned',
          )
          .join('; ');
      if (importIssues.isNotEmpty) reasons.add('Bill $billNo: $importIssues');
      count++;
      final fee = auditAmountInPaisa(bill['water_fee']);
      final sourceReceipt = auditAmountInPaisa(bill['amount_received']);
      final applied = advanceCredit ? advanceAppliedInReceipt(bill) : 0;
      advanceApplied += applied;
      final receipt = sourceReceipt == null ? null : sourceReceipt - applied;
      if (fee == null) {
        validFees = false;
        reasons.add('Invalid water fee: $billNo');
      } else {
        recorded += fee;
      }
      if (receipt == null) {
        validReceipts = false;
        reasons.add('Invalid receipt: $billNo');
      } else {
        received += sourceReceipt!;
      }
      final paid =
          value(bill, 'status').toLowerCase().replaceAll(_nonLetters, '') ==
          'paid';
      if (paid) {
        paidCount++;
      } else if (value(bill, 'status').toLowerCase() == 'expired') {
        expiredCount++;
      } else {
        unpaidCount++;
      }
      int? charge(String key) =>
          advanceCredit && (key == 'arrears' || key == 'total_bill')
          ? importAmountInPaisa(bill[key] ?? '0')
          : auditAmountInPaisa(bill[key] ?? '0');
      final total = charge('total_bill');
      final fine = charge('fine');
      final sanitation = charge('sanitation');
      final drainage = charge('drainage');
      final billing = charge('billing_fee');
      final arrears = charge('arrears');
      if ([
        total,
        fine,
        sanitation,
        drainage,
        billing,
        arrears,
      ].any((n) => n == null)) {
        invalidHistory = true;
        reasons.add('Invalid bill charges: $billNo');
        continue;
      }
      if (paid && receipt != null && receipt < total!) {
        paidShortCount++;
        reasons.add('Paid bill receipt is below Total Bill: $billNo');
      }
      if (fee == null || receipt == null) continue;
      final other = sanitation! + drainage! + billing!;
      if (total! < fee + other && !advanceCredit) {
        invalidHistory = true;
        reasons.add('Total Bill is below current charges: $billNo');
        continue;
      }
      if (other == 0 && total == fee + arrears!) {
        settledWaterReasons.addAll([
          'Paid bill receipt is below Total Bill: $billNo',
          'Mixed / arrears receipt allocation needs review: $billNo',
        ]);
      }
      // A printed fine is not a collected fine; only the excess over principal proves collection.
      final collectedFine = (receipt - (total < 0 ? 0 : total)).clamp(0, fine!);
      final principalReceipt = receipt - collectedFine;
      final collectedOther = (principalReceipt - (total - other))
          .clamp(0, other)
          .clamp(0, principalReceipt);
      final carriedFine = receipt >= total && total == fee + other + arrears!
          ? _collectedCarriedFine(
              bill,
              reconciledHistory,
              recoveredFines,
              periods,
            )
          : 0;
      knownNonWater += collectedFine + collectedOther + carriedFine;
      fineCollected += collectedFine + carriedFine;
      if (receipt > 0 &&
          receipt < total &&
          (arrears! > 0 || other > 0 || fine > 0)) {
        allocationNeedsReview = true;
        reasons.add('Mixed / arrears receipt allocation needs review: $billNo');
      } else if (receipt >= total && arrears! > 0) {
        if (total == fee + other + arrears) {
          fullyPaidArrears.add(billNo);
        } else {
          allocationNeedsReview = true;
          reasons.add(
            'Total Bill does not match current charges and arrears: $billNo',
          );
        }
      }
    }
    final waterReceipts = received - advanceApplied - knownNonWater;
    final advanceBalance = validFees && validReceipts
        ? (waterReceipts - recorded).clamp(
            0,
            waterReceipts < 0 ? 0 : waterReceipts,
          )
        : 0;
    // Full arrears payments need no allocation review when water recovery reconciles.
    if (fullyPaidArrears.isNotEmpty &&
        (!validFees ||
            !validReceipts ||
            recorded != waterReceipts - advanceBalance)) {
      allocationNeedsReview = true;
      reasons.addAll(
        fullyPaidArrears.map(
          (billNo) =>
              'Mixed / arrears receipt allocation needs review: $billNo',
        ),
      );
    }
    // Later receipts can settle an earlier short payment; waived fines do not
    // require water allocation review once all generated water fees are covered.
    if (validFees &&
        validReceipts &&
        !invalidHistory &&
        recorded == waterReceipts - advanceBalance) {
      reasons.removeWhere(settledWaterReasons.contains);
      allocationNeedsReview =
          selection.invalidPeriods.isNotEmpty ||
          reasons.any(
            (reason) =>
                reason.startsWith('Mixed / arrears receipt allocation') ||
                reason.startsWith('Total Bill does not match current charges'),
          );
    }
    entries.add(
      BillingAuditEntry(
        connectionNo: key,
        consumerName: value(detail, 'consumer_name'),
        fatherHusbandName: value(detail, 'father_husband_name'),
        sector: value(detail, 'sector'),
        locality: value(detail, 'locality'),
        address: value(detail, 'address'),
        connectionDate: value(detail, 'connection_date'),
        connectionStatus: value(detail, 'connection_status'),
        consumerStatus: value(detail, 'consumer_status'),
        currentBillStatus: value(detail, 'bill_status'),
        category: category,
        billGroup: billGroup,
        billCount: count,
        paidBillCount: paidCount,
        unpaidBillCount: unpaidCount,
        expiredBillCount: expiredCount,
        paidShortCount: paidShortCount,
        waterFee: validFees ? recorded : null,
        received: validReceipts ? received : null,
        waterReceiptLimit: validReceipts ? waterReceipts : null,
        knownNonWaterReceived: knownNonWater,
        fineCollected: fineCollected,
        advanceApplied: advanceApplied,
        advanceBalance: advanceBalance,
        excludedBillNumbers: selection.excluded,
        outstandingFine: latestBalance.outstandingFine,
        confirmedPaymentCount: confirmedPaymentCount,
        confirmedPaymentAdjustment: confirmedPaymentAdjustment,
        allocationNeedsReview: allocationNeedsReview,
        invalidHistory: invalidHistory,
        reviewReasons: reasons.toSet().toList(),
        periodBills: resolveAuditBillPeriods(history, periods),
        coverage: billGroup == 'new_connection'
            ? null
            : buildBillingCoverage(
                bills: history
                    .where((bill) => !isNewConnectionBill(bill['bill_type']))
                    .toList(),
                periods: periods,
                schedule: coverageSchedule,
                category: category,
              ),
      ),
    );
  }
  entries.sort((a, b) {
    final amountA = a.payableBalance;
    final amountB = b.payableBalance;
    if (amountA == null && amountB != null) return 1;
    if (amountB == null && amountA != null) return -1;
    final difference = amountA == null ? 0 : amountB!.compareTo(amountA);
    return difference != 0
        ? difference
        : a.connectionNo.compareTo(b.connectionNo);
  });
  return entries;
}

({
  List<Map<String, Object?>> bills,
  List<String> excluded,
  List<String> invalidPeriods,
})
_currentAuditBills(
  List<Map<String, Object?>> history,
  String sector,
  Map<String, List<DateTime>> periodCache,
) {
  final models = {for (final bill in history) bill: BillHistory.fromMap(bill)};
  final periods = {
    for (final bill in history) bill: _auditBillPeriod(bill, periodCache),
  };
  final invalidPeriods = [
    for (final bill in history)
      if (!{'', '-', '--'}.contains('${bill['billing_period'] ?? ''}'.trim()) &&
          periods[bill]!.isEmpty)
        '${bill['bill_no']}',
  ];
  final types = {
    for (final bill in history)
      bill: '${bill['bill_type']}'.trim().toLowerCase(),
  };
  final sorted = List<Map<String, Object?>>.of(history)
    ..sort((a, b) => compareHistoryBillsNewestFirst(models[a]!, models[b]!));
  final kept = <Map<String, Object?>>[];
  final excluded = <String>[];
  for (final bill in sorted) {
    final period = periods[bill]!;
    if (period.length != 2 ||
        _confirmedSectorPeriod(bill, sector) ||
        kept.any(
          (newer) =>
              '${newer['bill_no']}'.trim().toUpperCase() ==
              '${bill['bill_no']}'.trim().toUpperCase(),
        )) {
      kept.add(bill);
      continue;
    }
    final overlaps = kept.any((newer) {
      final range = periods[newer]!;
      return types[newer] == types[bill] &&
          range.length == 2 &&
          !range.first.isAfter(period.last) &&
          !range.last.isBefore(period.first);
    });
    if (overlaps) {
      excluded.add('${bill['bill_no']}');
    } else {
      kept.add(bill);
    }
  }
  return (bills: kept, excluded: excluded, invalidPeriods: invalidPeriods);
}

List<DateTime> _auditBillPeriod(
  Map<String, Object?> bill,
  Map<String, List<DateTime>> cache,
) => cache.putIfAbsent('${bill['billing_period'] ?? ''}', () {
  final dates = _periodDates
      .allMatches('${bill['billing_period'] ?? ''}')
      .map((m) => historyBillDate(m[0]!))
      .whereType<DateTime>()
      .toList();
  return dates.length == 2 && !dates.first.isAfter(dates.last) ? dates : [];
});

/// User-confirmed exception for first bills affected by sector renaming.
/// The original imported rows and receipt dates remain unchanged in storage.
bool _confirmedSectorPeriod(Map<String, Object?> bill, String sector) {
  final area = sector.toLowerCase().replaceAll(_nonLetters, '');
  if (!{'alitown', 'muslimtown'}.contains(area)) return false;
  final period = _confirmedPeriodDates
      .allMatches('${bill['billing_period'] ?? ''}')
      .map((m) => m[0]!.replaceAll('-', '/'))
      .toList();
  return period.length == 2 &&
      period[0] == '01/07/2023' &&
      period[1] == '31/12/2023' &&
      !'${bill['bill_type']}'.toLowerCase().contains('new');
}

Map<String, Object?> applyConfirmedSectorPayment(
  Map<String, Object?> bill,
  String sector,
) {
  final status = '${bill['status'] ?? ''}'.toLowerCase().replaceAll(
    _nonLetters,
    '',
  );
  if (!_confirmedSectorPeriod(bill, sector) || status == 'paid') return bill;
  final principal = auditAmountInPaisa(bill['total_bill']);
  final received = auditAmountInPaisa(bill['amount_received']);
  if (principal == null || received == null) return bill;
  final increase = principal > received ? principal - received : 0;
  return {
    ...bill,
    'status': 'Paid',
    'amount_received': ((received + increase) / 100).toStringAsFixed(2),
    'confirmed_payment_adjustment': increase,
  };
}

/// One first-period payment per connection. Existing Paid bills take precedence.
List<Map<String, Object?>> applyConfirmedSectorPayments(
  List<Map<String, Object?>> bills,
  String sector,
) {
  final eligible = bills
      .where((bill) => _confirmedSectorPeriod(bill, sector))
      .toList();
  if (eligible.isEmpty) return bills;
  eligible.sort((a, b) {
    final paidA = '${a['status']}'.toLowerCase() == 'paid';
    final paidB = '${b['status']}'.toLowerCase() == 'paid';
    if (paidA != paidB) return paidA ? -1 : 1;
    final numberA = int.tryParse('${a['bill_no']}');
    final numberB = int.tryParse('${b['bill_no']}');
    return numberA != null && numberB != null
        ? numberB.compareTo(numberA)
        : '${b['bill_no']}'.compareTo('${a['bill_no']}');
  });
  final chosen = eligible.first['bill_no'];
  return [
    for (final bill in bills)
      if (!_confirmedSectorPeriod(bill, sector))
        bill
      else if (bill['bill_no'] == chosen)
        applyConfirmedSectorPayment(bill, sector)
      else
        {
          ...bill,
          'payment_exception_review':
              'Multiple bills for July-December 2023: review bill ${bill['bill_no']}; one confirmed payment per connection (bill $chosen).',
        },
  ];
}

// Separate a fine recovered through a uniquely matched adjacent bill. A Paid
// predecessor can still carry its unpaid fine after its principal was received.
int _collectedCarriedFine(
  Map<String, Object?> bill,
  List<Map<String, Object?>> history,
  Set<String> recovered,
  Map<String, List<DateTime>> periodCache,
) {
  final arrears = auditAmountInPaisa(bill['arrears']);
  if (arrears == null || arrears == 0) return 0;
  final current = _auditBillPeriod(bill, periodCache);
  if (current.length != 2 || current.first.isAfter(current.last)) return 0;
  final candidates = history.where((old) {
    final status = '${old['status']}'.trim().toLowerCase();
    if ((status != 'expired' && status != 'paid') ||
        '${old['bill_type']}'.trim().toLowerCase() !=
            '${bill['bill_type']}'.trim().toLowerCase()) {
      return false;
    }
    final oldPeriod = _auditBillPeriod(old, periodCache);
    if (oldPeriod.length != 2 ||
        oldPeriod.first.isAfter(oldPeriod.last) ||
        oldPeriod.last.add(const Duration(days: 1)) != current.first) {
      return false;
    }
    final fine = auditAmountInPaisa(old['fine']);
    final total = auditAmountInPaisa(old['total_bill']);
    final after = auditAmountInPaisa(old['after_due_date']);
    final fee = auditAmountInPaisa(old['water_fee']);
    final priorReceipt = auditAmountInPaisa(old['amount_received']);
    final priorArrears = auditAmountInPaisa(old['arrears']);
    final other = [
      old['sanitation'] ?? '0',
      old['drainage'] ?? '0',
      old['billing_fee'] ?? '0',
    ].map(auditAmountInPaisa).toList();
    if (fine == null ||
        fine < 0 ||
        total == null ||
        after == null ||
        fee == null ||
        priorReceipt == null ||
        priorArrears == null ||
        other.contains(null)) {
      return false;
    }
    final canCarry =
        (status == 'expired' && priorReceipt == 0) ||
        (status == 'paid' && priorReceipt >= total);
    return canCarry &&
        total ==
            fee + priorArrears + other.fold<int>(0, (sum, n) => sum + n!) &&
        after == total + fine &&
        (arrears == after - priorReceipt || arrears == total - priorReceipt);
  }).toList();
  if (candidates.length != 1 ||
      !recovered.add('${candidates.single['bill_no']}')) {
    return 0;
  }
  final previous = candidates.single;
  final fine = auditAmountInPaisa(previous['fine'])!;
  final receivedEarlier = auditAmountInPaisa(previous['amount_received'])!;
  final total = auditAmountInPaisa(previous['total_bill'])!;
  final carriedOwnFine = arrears == total + fine - receivedEarlier
      ? fine - (receivedEarlier - total).clamp(0, fine)
      : 0;
  // A principal-only carry waives this bill's fine; earlier carried fines may remain.
  final earlierFine = '${previous['status']}'.trim().toLowerCase() == 'expired'
      ? _collectedCarriedFine(previous, history, recovered, periodCache)
      : 0;
  return carriedOwnFine + earlierFine;
}
