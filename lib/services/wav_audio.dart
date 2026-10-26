import 'dart:typed_data';

/// Validates and boosts only PCM sample data, never RIFF metadata chunks.
class WavAudio {
  static bool prepare(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    String tag(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException(
        'The microphone did not produce a valid WAV file.',
      );
    }
    var pcm16 = false;
    int? start;
    var length = 0;
    for (var offset = 12; offset + 8 <= bytes.length;) {
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (body + size > bytes.length) {
        throw const FormatException(
          'The recording is incomplete. Please try again.',
        );
      }
      if (tag(offset) == 'fmt ' && size >= 16) {
        pcm16 =
            data.getUint16(body, Endian.little) == 1 &&
            data.getUint16(body + 14, Endian.little) == 16;
      }
      if (tag(offset) == 'data') {
        start = body;
        length = size;
      }
      offset = body + size + (size % 2);
    }
    if (!pcm16 || start == null || length % 2 != 0) {
      throw const FormatException(
        'The microphone recording must be 16-bit PCM WAV.',
      );
    }
    var peak = 0;
    for (var i = start; i < start + length; i += 2) {
      final value = data.getInt16(i, Endian.little).abs();
      if (value > peak) peak = value;
    }
    if (peak <= 32) return false;
    // Avoid excessive amplification of near-silence or ambient noise.
    if (peak > 200 && peak < 18000) {
      final gain = (26000 / peak).clamp(1.0, 10.0);
      for (var i = start; i < start + length; i += 2) {
        final boosted = (data.getInt16(i, Endian.little) * gain).round().clamp(
          -32768,
          32767,
        );
        data.setInt16(i, boosted, Endian.little);
      }
    }
    return true;
  }
}
