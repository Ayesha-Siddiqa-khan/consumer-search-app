import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/models/history_bill_balance.dart';
import 'package:flutter_test/flutter_test.dart';

BillHistory bill({
  String no = '6865832',
  String status = 'Un-Paid',
  String due = '29/08/2026',
  String received = '0',
  String after = '2640',
}) => BillHistory(
  connectionNo: '90010045',
  billNo: no,
  status: status,
  dueDate: due,
  waterFee: '2400',
  totalBill: '2400',
  fine: '240',
  afterDueDate: after,
  amountReceived: received,
);

void main() {
  test(
    'normal amount applies through the entire due date; late amount applies the next day',
    () {
      final bills = [bill()];
      expect(
        latestHistoryBillBalance(bills, asOf: DateTime(2026, 8, 28)).amount,
        240000,
      );
      expect(
        latestHistoryBillBalance(
          bills,
          asOf: DateTime(2026, 8, 29, 23, 59),
        ).amount,
        240000,
      );
      expect(
        latestHistoryBillBalance(bills, asOf: DateTime(2026, 8, 30)).amount,
        264000,
      );
    },
  );

  test(
    'sample remaining is latest overdue bill, not generated fees minus receipts',
    () {
      final result = latestHistoryBillBalance([
        bill(no: '5063016', status: 'Expired'),
        bill(no: '6133319', status: 'Paid', received: '2640'),
        bill(),
      ], asOf: DateTime(2026, 10, 21));
      expect(result.bill!.billNo, '6865832');
      expect(result.amount, 264000);
      expect(result.basis, contains('After due date'));
    },
  );

  test('a paid or expired latest bill does not revive older unpaid bills', () {
    for (final status in ['Paid', 'Expired']) {
      expect(
        latestHistoryBillBalance([
          bill(no: '100'),
          bill(no: '200', status: status),
        ], asOf: DateTime(2026, 10, 21)).amount,
        0,
      );
    }
    expect(latestHistoryBillBalance([]).amount, 0);
  });

  test(
    'partial payment reduces latest bill and carried arrears are not added twice',
    () {
      expect(
        latestHistoryBillBalance([
          bill(received: '1000'),
        ], asOf: DateTime(2026, 10, 21)).amount,
        164000,
      );
      final current = BillHistory(
        connectionNo: 'A',
        billNo: '200',
        totalBill: '4800',
        waterFee: '2400',
        arrears: '2400',
        fine: '240',
        afterDueDate: '5040',
        dueDate: '29/08/2026',
      );
      expect(
        latestHistoryBillBalance([
          bill(no: '100'),
          current,
        ], asOf: DateTime(2026, 10, 21)).amount,
        504000,
      );
    },
  );

  test(
    'missing or invalid due dates do not guess a fine; invalid late amounts are flagged',
    () {
      for (final due in ['-', '2640', '31/02/2026']) {
        expect(
          latestHistoryBillBalance([
            bill(due: due),
          ], asOf: DateTime(2026, 10, 21)).amount,
          isNull,
        );
      }
      expect(
        latestHistoryBillBalance([
          bill(after: '2000'),
        ], asOf: DateTime(2026, 10, 21)).amount,
        isNull,
      );
      const noFine = BillHistory(
        connectionNo: 'A',
        billNo: '200',
        totalBill: '2400',
        afterDueDate: '2400',
      );
      expect(latestHistoryBillBalance([noFine]).amount, 240000);
    },
  );
}
