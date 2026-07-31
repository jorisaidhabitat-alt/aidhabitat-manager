// Picked only by the web target through the conditional import.
import 'dart:js_interop';

@JS('aidHabitatPrepareSpeechRecognition')
external JSPromise<JSString> _prepareSpeechRecognition(JSString locale);

Future<String> prepareWebVoiceSpeechRuntimeImpl() async {
  try {
    final result = await _prepareSpeechRecognition('fr-FR'.toJS).toDart;
    return result.toDart;
  } catch (_) {
    return 'remote';
  }
}
