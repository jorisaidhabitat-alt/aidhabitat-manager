import 'voice_microphone_permission_io.dart'
    if (dart.library.html) 'voice_microphone_permission_web.dart';

/// Requests microphone access while the action still originates from the
/// user's tap. Native builds already handle this through `speech_to_text`.
Future<String?> requestVoiceMicrophonePermission() {
  return requestVoiceMicrophonePermissionImpl();
}
