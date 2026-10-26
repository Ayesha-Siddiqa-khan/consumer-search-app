final _currencyPrefix = RegExp(r'^(Rs\.?|PKR)\s*', caseSensitive: false);
final _moneyDigits = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$');
final _amountCache = <String, int?>{};

int? auditAmountInPaisa(Object? raw) {
  final source = (raw ?? '').toString().trim();
  if (_amountCache.containsKey(source)) return _amountCache[source];
  final amount = _parseAmount(source);
  // A bounded cache reuses common CSV values without retaining the dataset.
  if (_amountCache.length >= 2048) _amountCache.clear();
  return _amountCache[source] = amount;
}

int? _parseAmount(String source) {
  final text = source
      .replaceFirst(_currencyPrefix, '')
      .replaceAll(',', '')
      .replaceAll(' ', '');
  final match = _moneyDigits.firstMatch(text);
  if (match == null) return null;
  final rupees = int.tryParse(match[1]!);
  if (rupees == null || rupees > 90071992547409) return null;
  return rupees * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
}
