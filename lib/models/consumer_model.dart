class Consumer {
  final int? id;
  final int srNo;
  final String consumerName;
  final String fatherHusbandName;
  final String mobile;
  final String sector;
  final String locality;
  final String address;
  final String orderNo;
  final String rateType;
  final String connectionNo;
  final String oldConnectionNo;
  final String connectionDate; // Formatted as DD-MM-YYYY
  final String connectionStatus;
  final String consumerStatus;
  // Bill fields (from Bills CSV)
  final String totalBill;
  final String fine;
  final String afterDueDate;
  final String dueDate;
  final String billStatus;
  final String amountReceived;

  Consumer({
    this.id,
    required this.srNo,
    required this.consumerName,
    required this.fatherHusbandName,
    required this.mobile,
    required this.sector,
    required this.locality,
    required this.address,
    required this.orderNo,
    required this.rateType,
    required this.connectionNo,
    required this.oldConnectionNo,
    required this.connectionDate,
    required this.connectionStatus,
    required this.consumerStatus,
    this.totalBill = '',
    this.fine = '',
    this.afterDueDate = '',
    this.dueDate = '',
    this.billStatus = '',
    this.amountReceived = '',
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'sr_no': srNo,
      'consumer_name': consumerName,
      'father_husband_name': fatherHusbandName,
      'mobile': mobile,
      'sector': sector,
      'locality': locality,
      'address': address,
      'order_no': orderNo,
      'rate_type': rateType,
      'connection_no': connectionNo,
      'old_connection_no': oldConnectionNo,
      'connection_date': connectionDate,
      'connection_status': connectionStatus,
      'consumer_status': consumerStatus,
      'total_bill': totalBill,
      'fine': fine,
      'after_due_date': afterDueDate,
      'due_date': dueDate,
      'bill_status': billStatus,
      'amount_received': amountReceived,
    };
  }

  factory Consumer.fromMap(Map<String, dynamic> map) {
    return Consumer(
      id: map['id'] as int?,
      srNo: map['sr_no'] as int? ?? 0,
      consumerName: (map['consumer_name'] as String?)?.trim() ?? '',
      fatherHusbandName: (map['father_husband_name'] as String?)?.trim() ?? '',
      mobile: (map['mobile'] as String?)?.trim() ?? '',
      sector: (map['sector'] as String?)?.trim() ?? '',
      locality: (map['locality'] as String?)?.trim() ?? '',
      address: (map['address'] as String?)?.trim() ?? '',
      orderNo: (map['order_no'] as String?)?.trim() ?? '',
      rateType: (map['rate_type'] as String?)?.trim() ?? '',
      connectionNo: (map['connection_no'] as String?)?.trim() ?? '',
      oldConnectionNo: (map['old_connection_no'] as String?)?.trim() ?? '',
      connectionDate: (map['connection_date'] as String?)?.trim() ?? '',
      connectionStatus: (map['connection_status'] as String?)?.trim() ?? '',
      consumerStatus: (map['consumer_status'] as String?)?.trim() ?? '',
      totalBill: (map['total_bill'] as String?)?.trim() ?? '',
      fine: (map['fine'] as String?)?.trim() ?? '',
      afterDueDate: (map['after_due_date'] as String?)?.trim() ?? '',
      dueDate: (map['due_date'] as String?)?.trim() ?? '',
      billStatus: (map['bill_status'] as String?)?.trim() ?? '',
      amountReceived: (map['amount_received'] as String?)?.trim() ?? '',
    );
  }

  bool get isActive => consumerStatus.toLowerCase().replaceAll('-', '') == 'active';

  Consumer copyWith({
    int? id,
    int? srNo,
    String? consumerName,
    String? fatherHusbandName,
    String? mobile,
    String? sector,
    String? locality,
    String? address,
    String? orderNo,
    String? rateType,
    String? connectionNo,
    String? oldConnectionNo,
    String? connectionDate,
    String? connectionStatus,
    String? consumerStatus,
    String? totalBill,
    String? fine,
    String? afterDueDate,
    String? dueDate,
    String? billStatus,
    String? amountReceived,
  }) {
    return Consumer(
      id: id ?? this.id,
      srNo: srNo ?? this.srNo,
      consumerName: consumerName ?? this.consumerName,
      fatherHusbandName: fatherHusbandName ?? this.fatherHusbandName,
      mobile: mobile ?? this.mobile,
      sector: sector ?? this.sector,
      locality: locality ?? this.locality,
      address: address ?? this.address,
      orderNo: orderNo ?? this.orderNo,
      rateType: rateType ?? this.rateType,
      connectionNo: connectionNo ?? this.connectionNo,
      oldConnectionNo: oldConnectionNo ?? this.oldConnectionNo,
      connectionDate: connectionDate ?? this.connectionDate,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      consumerStatus: consumerStatus ?? this.consumerStatus,
      totalBill: totalBill ?? this.totalBill,
      fine: fine ?? this.fine,
      afterDueDate: afterDueDate ?? this.afterDueDate,
      dueDate: dueDate ?? this.dueDate,
      billStatus: billStatus ?? this.billStatus,
      amountReceived: amountReceived ?? this.amountReceived,
    );
  }

  /// Standardized Pakistani date format DD-MM-YYYY
  static String formatPakistaniDate(String? rawDate) {
    if (rawDate == null || rawDate.trim().isEmpty) return '-';
    final cleaned = rawDate.trim();
    // Handles formats like DD/MM/YYYY or YYYY-MM-DD or DD-MM-YYYY
    final slashParts = cleaned.split('/');
    if (slashParts.length == 3) {
      final p1 = slashParts[0].padLeft(2, '0');
      final p2 = slashParts[1].padLeft(2, '0');
      final p3 = slashParts[2];
      if (p3.length == 4) {
        // DD/MM/YYYY -> DD-MM-YYYY
        return '$p1-$p2-$p3';
      }
    }
    final dashParts = cleaned.split('-');
    if (dashParts.length == 3) {
      if (dashParts[0].length == 4) {
        // YYYY-MM-DD -> DD-MM-YYYY
        final y = dashParts[0];
        final m = dashParts[1].padLeft(2, '0');
        final d = dashParts[2].padLeft(2, '0');
        return '$d-$m-$y';
      } else {
        final d = dashParts[0].padLeft(2, '0');
        final m = dashParts[1].padLeft(2, '0');
        final y = dashParts[2];
        return '$d-$m-$y';
      }
    }
    return cleaned;
  }
}
