import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/billing_audit_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> oldBill(String no) => BillHistory(
  connectionNo: 'A',
  billNo: no,
  billType: 'Regular',
  billingPeriod: '01/08/2025 - 31/08/2025',
  waterFee: '400',
  totalBill: '400',
  fine: '40',
  afterDueDate: '440',
  status: 'Expired',
).toMap();
Map<String, Object?> paidBill({String receipt = '840'}) => BillHistory(
  connectionNo: 'A',
  billNo: '200',
  billType: 'Regular',
  billingPeriod: '01/09/2025 - 30/09/2025',
  waterFee: '400',
  totalBill: '840',
  arrears: '440',
  fine: '40',
  afterDueDate: '880',
  status: 'Paid',
  amountReceived: receipt,
).toMap();

void main() {
  test(
    'a fully paid unique carried amount separates the prior fine exactly once',
    () {
      final result = buildBillingAudit(
        consumers: [
          {'connection_no': 'A'},
        ],
        bills: [oldBill('100'), paidBill()],
        asOf: DateTime(2026, 10, 22),
      ).single;
      expect(result.waterFee, 80000);
      expect(result.received, 84000);
      expect(result.fineCollected, 4000);
      expect(result.waterReceived, 80000);
      expect(result.difference, 0);
      expect(result.outstandingFine, 0);
      expect(result.payableBalance, 0);
      expect(result.allocationNeedsReview, false);
      expect(result.result, 'No water balance');
    },
  );
  test('an inverted billing period cannot prove a recovered fine', () {
    final invalidOld = {
      ...oldBill('100'),
      'billing_period': '01/09/2025 - 31/08/2025',
    };
    final result = buildBillingAudit(
      consumers: [
        {'connection_no': 'A'},
      ],
      bills: [invalidOld, paidBill()],
    ).single;
    expect(result.fineCollected, 0);
    expect(result.allocationNeedsReview, true);
  });
  test(
    'newer period bills resolve duplicates while partial arrears stay flagged',
    () {
      final ambiguous = buildBillingAudit(
        consumers: [
          {'connection_no': 'A'},
        ],
        bills: [oldBill('100'), oldBill('101'), paidBill()],
      ).single;
      expect(ambiguous.fineCollected, 4000);
      expect(ambiguous.excludedBillNumbers, ['100']);
      expect(ambiguous.allocationNeedsReview, false);
      final partial = buildBillingAudit(
        consumers: [
          {'connection_no': 'A'},
        ],
        bills: [
          oldBill('100'),
          paidBill(receipt: '500'),
        ],
      ).single;
      expect(partial.fineCollected, 0);
      expect(partial.allocationNeedsReview, true);
    },
  );
}
