import 'package:flutter/foundation.dart';
import 'name_normalizer.dart';

class SmartSearchResult {
  final String rawQuery;
  final String cleanKeywords;
  final String? detectedSector;
  final String? detectedLocality;
  final String? detectedStatus;

  const SmartSearchResult({
    required this.rawQuery,
    required this.cleanKeywords,
    this.detectedSector,
    this.detectedLocality,
    this.detectedStatus,
  });

  bool get hasSector => detectedSector != null && detectedSector!.isNotEmpty;
  bool get hasLocality =>
      detectedLocality != null && detectedLocality!.isNotEmpty;
  bool get hasStatus => detectedStatus != null && detectedStatus!.isNotEmpty;

  @override
  String toString() =>
      'SmartSearchResult(keywords: "$cleanKeywords", sector: "$detectedSector", locality: "$detectedLocality", status: "$detectedStatus")';
}

class SmartSearchParser {
  /// Known Sector Aliases mapped to the exact database sector string
  static final Map<String, String> _sectorAliasMap = {
    // Top mentioned sectors from user audio and dataset
    'ALI TOWN': 'Ali Town',
    'FAROOQ COLONY': 'Farooq Colony',
    'GULBERG TOWN': 'Gulberg Town 14/G',
    'GULBERG': 'Gulberg Town 14/G',
    'AL KHAIR': 'Al-Khair Colony (PRIVATE SOCIETY)',
    'AL-KHAIR': 'Al-Khair Colony (PRIVATE SOCIETY)',
    'AL KHAIR COLONY': 'Al-Khair Colony (PRIVATE SOCIETY)',
    'AL-KHAIR COLONY': 'Al-Khair Colony (PRIVATE SOCIETY)',
    'CITY AREA': 'Qaziwala Road To Hospital City area',
    'HOSPITAL CITY AREA': 'Qaziwala Road To Hospital City area',
    'MEHBOOB COLONY': 'Mahboob Colony (SHARQI)',
    'MAHBOOB COLONY': 'Mahboob Colony (SHARQI)',
    'BALDIA COLONY': 'Baldia Colony',
    'BALDIA': 'Baldia Colony',
    'MADINA COLONY': 'Madina Colony',
    'SATELLITE TOWN': 'Satellite Town',
    'NEW SATELLITE TOWN': 'New Satellite Town',
    'MUSLIM TOWN': 'MUSLIM TOWN',
    'ISLAM PURA': 'Islam Pura',
    'PURANI CHISHTIAN': 'PURANI CHISHTIAN',
    'ALHARAM CITY': 'ALHARAM CITY',
    'ARHAM TOWN': 'ARHAM TOWN 16/G ROAD',
    'ALIMIA COLONY': 'Alimia Colony',
    'BAGHDAD COLONY': 'Baghdad Colony',
    'BAHADAR COLONY': 'Bahadar Colony',
    'BAHU CHOWK': 'Bahu Chowk to Sabz mandi Road',
    'BASTI QADRABBAD': 'Basti Qadrabbad',
    'COMMERCIAL': 'COMMERCIAL',
    'CHISHTIA PARK': 'Chishtia Park Colony',
    'FATIMA COLONY': 'FATIMA COLONY ( WARIS COLONY)',
    'WARIS COLONY': 'Waris Colony',
    'GHALA MANDI': 'Ghala Mandi Chishtian',
    'GHAREEB MOHALLAH': 'Ghareeb Mohallah',
    'GULSHAN-E-IQBAL': 'Gulshan-e-Iqbal Colony',
    'GULSHAN E IQBAL': 'Gulshan-e-Iqbal Colony',
    'HAIDAR PURA': 'HAIDAR PURA',
    'HUSSAIN COLONY': 'Hussain Colony',
    'IQBAL NAGAR': 'Iqbal Nager 46/F',
    'JINAH TOWN': 'JINAH TOWN',
    'JINNAH TOWN': 'JINAH TOWN',
    'LALA ZAAR COLONY': 'Lala Zaar Colony',
    'LALA ZAAR': 'Lala Zaar Colony',
    'SUKH CHAIN COLONY': 'SUKH CHAIN COLONY',
    'TAJ PURA': 'Taj Pura',
    'ZAIN CITY': 'ZAIN CITY (PRIVATE SOCITIES)',
  };

  /// Parse a raw voice or text query into smart components
  static SmartSearchResult parse(
    String rawQuery, {
    List<String>? availableSectors,
    List<String> availableLocalities = const [],
  }) {
    final clean = NameNormalizer.normalize(rawQuery);
    if (clean.isEmpty) {
      return SmartSearchResult(rawQuery: clean, cleanKeywords: clean);
    }

    String upper = clean.toUpperCase();
    String? matchedSector;
    String? matchedStatus;

    // 1. Check if status was explicitly spoken
    final statusMap = {
      'CLOSED': 'Closed',
      'REGULAR': 'Regular Connection',
      'ACTIVE': 'Regular Connection',
      'DEAD': 'Dead',
      'SUSPENDED': 'Suspended',
      'NEW DEMAND': 'New Demand',
    };
    for (final entry in statusMap.entries) {
      final statusRegex = RegExp(
        r'(?:\b|^)' + RegExp.escape(entry.key) + r'(?:\b|$)',
      );
      if (statusRegex.hasMatch(upper)) {
        matchedStatus = entry.value;
        upper = upper.replaceAll(statusRegex, ' ').trim();
        break;
      }
    }

    // 2. Build full sorted sector aliases (longest aliases first)
    final aliases = <String, String>{};
    final ambiguous = <String>{};
    void addAlias(String alias, String sector) {
      final key = NameNormalizer.normalize(alias);
      if (key.length < 3 || ambiguous.contains(key)) return;
      if (aliases.containsKey(key) && aliases[key] != sector) {
        aliases.remove(key);
        ambiguous.add(key);
      } else {
        aliases[key] = sector;
      }
    }

    for (final entry in _sectorAliasMap.entries) {
      final matches = availableSectors
          ?.where(
            (s) =>
                NameNormalizer.normalize(s) ==
                NameNormalizer.normalize(entry.value),
          )
          .toList();
      if (matches == null) {
        addAlias(entry.key, entry.value);
      } else if (matches.length == 1) {
        addAlias(entry.key, matches.single);
      }
    }

    // Also include any available sectors from DB if provided
    if (availableSectors != null) {
      for (final sec in availableSectors) {
        if (sec.trim().isEmpty || sec == 'All Sectors') continue;
        final cleanSec = sec
            .replaceAll(RegExp(r'\(.*?\)'), '')
            .trim()
            .toUpperCase();
        addAlias(cleanSec, sec);
        addAlias(sec, sec);
      }
    }
    final sortedAliases = aliases.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    String? matchedLocality;
    final localities = [...availableLocalities]
      ..sort((a, b) => b.length.compareTo(a.length));
    // Match full locality before removing its embedded sector name.
    for (final locality in localities) {
      if (locality == 'All Localities') continue;
      final key = NameNormalizer.normalize(locality);
      if (key.isEmpty || aliases.containsKey(key)) continue;
      final pattern = RegExp(r'\b' + RegExp.escape(key) + r'\b');
      if (pattern.hasMatch(upper)) {
        matchedLocality = locality;
        break;
      }
    }

    // 3. Match Sector
    for (final alias in sortedAliases) {
      final pattern = RegExp(r'(?:\b|^)' + RegExp.escape(alias) + r'(?:\b|$)');
      if (pattern.hasMatch(upper)) {
        matchedSector = aliases[alias];
        // Only remove one occurrence: a consumer may share a sector word.
        if (matchedLocality == null) {
          upper = upper.replaceFirst(pattern, ' ').trim();
        }
        break;
      }
    }

    if (matchedLocality != null) {
      upper = upper.replaceFirst(
        NameNormalizer.normalize(matchedLocality),
        ' ',
      );
      if (matchedSector != null) {
        for (final alias in sortedAliases.where(
          (a) => aliases[a] == matchedSector,
        )) {
          upper = upper.replaceFirst(
            RegExp(r'\b' + RegExp.escape(alias) + r'\b'),
            ' ',
          );
        }
      }
    }

    // Clean remaining words for consumer name / search keywords
    final remainingKeywords = upper.replaceAll(RegExp(r'\s+'), ' ').trim();

    debugPrint(
      'SmartSearchParser: "$clean" -> Keywords: "$remainingKeywords", Sector: "$matchedSector", Status: "$matchedStatus"',
    );

    return SmartSearchResult(
      rawQuery: clean,
      cleanKeywords: remainingKeywords,
      detectedSector: matchedSector,
      detectedLocality: matchedLocality,
      detectedStatus: matchedStatus,
    );
  }
}
