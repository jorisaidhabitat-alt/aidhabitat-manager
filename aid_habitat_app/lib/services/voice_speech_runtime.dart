import 'voice_speech_runtime_io.dart'
    if (dart.library.html) 'voice_speech_runtime_web.dart';

const webVoiceRuntimeLocal = 'local';
const webVoiceRuntimeRemote = 'remote';
const webVoiceRuntimeRemoteTrack = 'remote-track';
const webVoiceRuntimeUnsupported = 'unsupported';
const webVoiceRuntimeInstallFailed = 'install-failed';
const webVoiceRuntimeLocalError = 'local-error';

/// Prepares the browser speech engine before `speech_to_text` creates its
/// recognition object. Chromium browsers use their local French model when
/// available. Arc keeps an explicit microphone track but uses its connected
/// recognizer because its local engine can detect speech without returning a
/// transcript.
Future<String> prepareWebVoiceSpeechRuntime() {
  return prepareWebVoiceSpeechRuntimeImpl();
}
