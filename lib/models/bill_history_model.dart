class BillHistory {
  final int? id;
  final String connectionNo;
  final String sector;
  final String locality;
  final String consumerName;
  final String fatherHusbandName;
  final String srNo;
  final String billNo;
  final String billType;
  final String billingPeriod;
  final String arrears;
  final String waterFee;
  final String sanitation;
  final String drainage;
  final String billingFee;
  final String totalBill;
  final String fine;
  final String afterDueDate;
  final String dueDate;
  final String status;
  final String amountReceived;
  final String receiveDate;
  final String createdAt;

  const BillHistory({
    this.id,
    required this.connectionNo,
    this.sector = '',
    this.locality = '',
    this.consumerName = '',
    this.fatherHusbandName = '',
    this.srNo = '',
    this.billNo = '',
    this.billType = '',
    this.billingPeriod = '',
    this.arrears = '0',
    this.waterFee = '0',
    this.sanitation = '0',
    this.drainage = '0',
    this.billingFee = '0',
    this.totalBill = '0',
    this.fine = '0',
    this.afterDueDate = '0',
    this.dueDate = '-',
    this.status = 'Un-Paid',
    this.amountReceived = '0',
    this.receiveDate = '-',
    this.createdAt = '',
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'connection_no': connectionNo,
      'sector': sector,
      'locality': locality,
      'consumer_name': consumerName,
      'father_husband_name': fatherHusbandName,
      'sr_no': srNo,
      'bill_no': billNo,
      'bill_type': billType,
      'billing_period': billingPeriod,
      'arrears': arrears,
      'water_fee': waterFee,
      'sanitation': sanitation,
      'drainage': drainage,
      'billing_fee': billingFee,
      'total_bill': totalBill,
      'fine': fine,
      'after_due_date': afterDueDate,
      'due_date': dueDate,
      'status': status,
      'amount_received': amountReceived,
      'receive_date': receiveDate,
      'created_at': createdAt,
    };
  }

  factory BillHistory.fromMap(Map<String, dynamic> map) {
    return BillHistory(
      id: map['id'] as int?,
      connectionNo: (map['connection_no'] as String? ?? '').trim(),
      sector: (map['sector'] as String? ?? '').trim(),
      locality: (map['locality'] as String? ?? '').trim(),
      consumerName: (map['consumer_name'] as String? ?? '').trim(),
      fatherHusbandName: (map['father_husband_name'] as String? ?? '').trim(),
      srNo: (map['sr_no'] as String? ?? '').trim(),
      billNo: (map['bill_no'] as String? ?? '').trim(),
      billType: (map['bill_type'] as String? ?? '').trim(),
      billingPeriod: (map['billing_period'] as String? ?? '').trim(),
      arrears: (map['arrears'] as String? ?? '0').trim(),
      waterFee: (map['water_fee'] as String? ?? '0').trim(),
      sanitation: (map['sanitation'] as String? ?? '0').trim(),
      drainage: (map['drainage'] as String? ?? '0').trim(),
      billingFee: (map['billing_fee'] as String? ?? '0').trim(),
      totalBill: (map['total_bill'] as String? ?? '0').trim(),
      fine: (map['fine'] as String? ?? '0').trim(),
      afterDueDate: (map['after_due_date'] as String? ?? '0').trim(),
      dueDate: (map['due_date'] as String? ?? '-').trim(),
      status: (map['status'] as String? ?? 'Un-Paid').trim(),
      amountReceived: (map['amount_received'] as String? ?? '0').trim(),
      receiveDate: (map['receive_date'] as String? ?? '-').trim(),
      createdAt: (map['created_at'] as String? ?? '').trim(),
    );
  }
}
