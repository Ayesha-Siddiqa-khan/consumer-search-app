class NameNormalizer {
  /// English spelling variations for Pakistani names
  static const Map<String, String> transliterationDict = {
    'GAFUR': 'GHAFOOR', 'GAFOOR': 'GHAFOOR', 'GHAFUR': 'GHAFOOR',
    'GHAFOUR': 'GHAFOOR', 'FARUK': 'FAROOQ', 'FAROOQUE': 'FAROOQ',
    // Required by user specifications
    'ISMAEEL': 'ISMAIL',
    'ISMAIEL': 'ISMAIL',
    'SHAIR': 'SHER',
    'SHERE': 'SHER',
    'MEHER': 'MEHR',

    // Frequent Pakistani variations
    'MOHAMMAD': 'MUHAMMAD',
    'MOHAMED': 'MUHAMMAD',
    'MOHD': 'MUHAMMAD',
    'MOHAMMED': 'MUHAMMAD',
    'MD': 'MUHAMMAD',
    'PEER': 'PIR',
    'REHMAN': 'RAHMAN',
    'FAHIM': 'FAHEEM',
    'NAEEM': 'NAIM',
    'CH': 'CHAUDHRY',
    'CH.': 'CHAUDHRY',
    'AHMED': 'AHMAD',
    'HUSEN': 'HUSSAIN',
    'HUSAIN': 'HUSSAIN',
  };

  /// Clean, uppercase, remove punctuation, and normalize English spellings
  static String normalize(String input) {
    if (input.trim().isEmpty) return '';

    // Uppercase and strip unwanted punctuation (keep alphanumeric and spaces)
    String cleaned = input.toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9\s]'),
      ' ',
    );

    // Normalize multiple spaces into single space
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    final words = cleaned.split(' ');
    final normalizedWords = words.map((w) {
      final upper = w.trim();
      return transliterationDict[upper] ?? upper;
    }).toList();

    return normalizedWords.join(' ').trim();
  }

  /// A conservative consonant key used only when the vocabulary match is unique.
  static String phoneticKey(String value) {
    return normalize(value)
        .replaceAll('GH', 'G')
        .replaceAll('Q', 'K')
        .replaceAll(RegExp(r'[AEIOUWY]'), '')
        .replaceAll(RegExp(r'[^A-Z0-9]'), '')
        .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
  }

  static List<String> spellingVariants(String token) {
    final canonical = normalize(token);
    return {
      token.toUpperCase(),
      canonical,
      ...transliterationDict.entries
          .where(
            (e) => e.value == canonical && RegExp(r'^[A-Z]+$').hasMatch(e.key),
          )
          .map((e) => e.key),
    }.toList();
  }
}
