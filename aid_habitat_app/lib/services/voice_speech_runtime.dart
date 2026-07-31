import 'voice_speech_runtime_io.dart'
    if (dart.library.html) 'voice_speech_runtime_web.dart';

const webVoiceRuntimeLocal = 'local';
const webVoiceRuntimeRemote = 'remote';
const webVoiceRuntimeUnsupported = 'unsupported';
const webVoiceRuntimeInstallFailed = 'install-failed';
const webVoiceRuntimeLocalError = 'local-error';

/// Prepares the browser speech engine before `speech_to_text` creates its
/// recognition object. Chromium browsers use their local French model when
/// available; other browsers retain their regular implementation.
Future<String> prepareWebVoiceSpeechRuntime() {
  return prepareWebVoiceSpeechRuntimeImpl();
}
