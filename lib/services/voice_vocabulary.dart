import 'name_normalizer.dart';

/// Resolves spelling against actual imported vocabulary. Ambiguities stay visible
/// for correction instead of silently choosing a different person's name.
class VoiceVocabulary {
  final Map<String, Set<String>> _keys = {};
  final Map<String, Set<String>> _exact = {};
  VoiceVocabulary(Iterable<String> phrases) {
    for (final phrase in phrases) {
      for (final word in phrase.toUpperCase().split(RegExp(r'[^A-Z0-9]+'))) {
        if (word.isEmpty) continue;
        (_exact[NameNormalizer.normalize(word)] ??= {}).add(word);
        (_keys[NameNormalizer.phoneticKey(word)] ??= {}).add(word);
      }
    }
  }

  String resolve(String phrase) => NameNormalizer.normalize(phrase)
      .split(' ')
      .map((word) {
        final exact = _exact[word];
        if (exact != null) {
          if (exact.contains(word)) return word;
          if (exact.length == 1) return exact.single;
          return word;
        }
        final key = NameNormalizer.phoneticKey(word);
        // Short keys collide heavily: Ali/Wali, Riaz/Raza, etc.
        final candidates = key.length >= 3 ? _keys[key] : null;
        if (candidates != null && candidates.length == 1) {
          return candidates.single;
        }
        return word;
      })
      .join(' ');
}
