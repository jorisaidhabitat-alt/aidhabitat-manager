// Picked only by the web target through the conditional import.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<String?> requestVoiceMicrophonePermissionImpl() async {
  final mediaDevices = html.window.navigator.mediaDevices;

  try {
    final stream = await mediaDevices?.getUserMedia(const {'audio': true});
    if (stream == null) {
      return 'Aucun microphone utilisable n’a été détecté par le navigateur.';
    }
    for (final track in stream.getTracks()) {
      track.stop();
    }
    return null;
  } on html.DomException catch (error) {
    final code = error.name.toLowerCase();
    if (code.contains('notallowed') ||
        code.contains('permission') ||
        code.contains('security')) {
      return 'L’accès au microphone est bloqué. Autorisez le microphone pour '
          'app.aidhabitat.fr dans les réglages du site, puis réessayez.';
    }
    if (code.contains('notfound') || code.contains('devicesnotfound')) {
      return 'Aucun microphone utilisable n’a été détecté par le navigateur.';
    }
    if (code.contains('notreadable') || code.contains('trackstarterror')) {
      return 'Le microphone est déjà utilisé ou indisponible. Fermez les '
          'autres applications qui l’utilisent, puis réessayez.';
    }
    return 'Le navigateur n’a pas pu ouvrir le microphone. Vérifiez son '
        'autorisation pour app.aidhabitat.fr.';
  } catch (_) {
    return 'Le navigateur n’a pas pu ouvrir le microphone. Vérifiez son '
        'autorisation pour app.aidhabitat.fr.';
  }
}
