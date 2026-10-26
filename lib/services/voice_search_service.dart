import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class VoiceSearchService {
  static final VoiceSearchService instance = VoiceSearchService._internal();
  VoiceSearchService._internal();

  Process? _activeProcess;

  /// Listen for speech input on Windows via System.Speech SAPI
  Future<String?> listenForSpeech({Duration timeout = const Duration(seconds: 5)}) async {
    if (!Platform.isWindows) {
      return null;
    }

    try {
      stopListening();

      // PowerShell script to capture speech from default audio device
      final script = '''
Add-Type -AssemblyName System.Speech
\$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
try {
    \$engine.SetInputToDefaultAudioDevice()
    \$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
    \$result = \$engine.Recognize([TimeSpan]::FromSeconds(${timeout.inSeconds}))
    if (\$result -and \$result.Text) {
        Write-Output "RESULT:\$(\$result.Text)"
    } else {
        Write-Output "NO_SPEECH"
    }
} catch {
    Write-Output "ERROR:\$(\$_.Exception.Message)"
} finally {
    \$engine.Dispose()
}
''';

      _activeProcess = await Process.start(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      );

      final completer = Completer<String?>();
      final output = StringBuffer();

      _activeProcess?.stdout.transform(const SystemEncoding().decoder).listen((data) {
        output.write(data);
      });

      _activeProcess?.exitCode.then((_) {
        final text = output.toString().trim();
        if (text.contains('RESULT:')) {
          final parts = text.split('RESULT:');
          if (parts.length > 1) {
            final recognized = parts[1].trim();
            if (!completer.isCompleted) {
              completer.complete(recognized.isNotEmpty ? recognized : null);
            }
          }
        }
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      return await completer.future.timeout(
        timeout + const Duration(seconds: 2),
        onTimeout: () {
          stopListening();
          return null;
        },
      );
    } catch (e) {
      debugPrint('Voice recognition error: $e');
      return null;
    }
  }

  void stopListening() {
    try {
      _activeProcess?.kill();
      _activeProcess = null;
    } catch (_) {}
  }
}
