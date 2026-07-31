import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/voice_microphone_permission.dart';

/// Applies a complete speech-recognition hypothesis to the text value captured
/// when dictation started. Reusing the same base value for partial results
/// prevents the recognizer from appending the same words several times.
@visibleForTesting
TextEditingValue applyVoiceDictationTranscript({
  required TextEditingValue baseValue,
  required String transcript,
}) {
  final recognized = transcript.trim();
  if (recognized.isEmpty) return baseValue;

  final text = baseValue.text;
  final selection = baseValue.selection;
  final hasValidSelection =
      selection.isValid &&
      selection.start >= 0 &&
      selection.end >= 0 &&
      selection.start <= text.length &&
      selection.end <= text.length;
  final start = hasValidSelection
      ? selection.start.clamp(0, text.length)
      : text.length;
  final end = hasValidSelection
      ? selection.end.clamp(start, text.length)
      : text.length;
  final prefix = text.substring(0, start);
  final suffix = text.substring(end);

  final leadingSpace =
      prefix.isNotEmpty &&
      !_isWhitespace(prefix.codeUnitAt(prefix.length - 1)) &&
      !_startsWithPunctuation(recognized);
  final trailingSpace =
      suffix.isNotEmpty &&
      !_isWhitespace(suffix.codeUnitAt(0)) &&
      !_startsWithPunctuation(suffix) &&
      !_endsWithOpeningPunctuation(recognized);
  final inserted =
      '${leadingSpace ? ' ' : ''}$recognized${trailingSpace ? ' ' : ''}';
  final nextText = '$prefix$inserted$suffix';

  return TextEditingValue(
    text: nextText,
    selection: TextSelection.collapsed(offset: prefix.length + inserted.length),
  );
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _startsWithPunctuation(String value) =>
    value.isNotEmpty && '.,;:!?…)]}'.contains(value[0]);

bool _endsWithOpeningPunctuation(String value) =>
    value.isNotEmpty && '([{'.contains(value[value.length - 1]);

class _VoiceDictationStartResult {
  const _VoiceDictationStartResult.success() : errorMessage = null;

  const _VoiceDictationStartResult.failure(this.errorMessage);

  final String? errorMessage;
  bool get started => errorMessage == null;
}

/// Owns the singleton `speech_to_text` instance and routes its callbacks to the
/// currently active editor. Native Apple builds force on-device recognition.
/// Web builds use the browser speech-recognition implementation.
class _VoiceDictationService {
  _VoiceDictationService._();

  static final _VoiceDictationService instance = _VoiceDictationService._();

  static bool get isSupportedPlatform =>
      kIsWeb ||
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  Object? _activeOwner;
  ValueChanged<SpeechRecognitionResult>? _resultCallback;
  ValueChanged<String>? _statusCallback;
  ValueChanged<SpeechRecognitionError>? _errorCallback;

  bool isActiveOwner(Object owner) => identical(_activeOwner, owner);

  Future<_VoiceDictationStartResult> start({
    required Object owner,
    required ValueChanged<SpeechRecognitionResult> onResult,
    required ValueChanged<String> onStatus,
    required ValueChanged<SpeechRecognitionError> onError,
  }) async {
    if (!isSupportedPlatform) {
      return const _VoiceDictationStartResult.failure(
        'La dictée locale est disponible uniquement dans '
        'l’application iPad, Mac ou la web app.',
      );
    }

    if (_activeOwner != null && !identical(_activeOwner, owner)) {
      await _cancelActiveSession();
    }

    _activeOwner = owner;
    _resultCallback = onResult;
    _statusCallback = onStatus;
    _errorCallback = onError;

    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onStatus: _relayStatus,
          onError: _relayError,
          debugLogging: false,
        );
      }
      if (!_initialized) {
        _release(owner);
        return _VoiceDictationStartResult.failure(
          kIsWeb
              ? 'La dictée vocale n’est pas disponible dans ce navigateur. '
                    'Utilisez une version récente de Safari ou Chrome.'
              : 'Autorisez le microphone et la reconnaissance vocale dans '
                    'Réglages pour utiliser la dictée.',
        );
      }

      final localeId = await _findFrenchLocale();
      if (localeId == null) {
        _release(owner);
        return _VoiceDictationStartResult.failure(
          kIsWeb
              ? 'La reconnaissance vocale française n’est pas disponible '
                    'dans ce navigateur.'
              : 'La reconnaissance française hors ligne n’est pas disponible '
                    'sur cet appareil.',
        );
      }

      await _speech.listen(
        onResult: _relayResult,
        listenOptions: stt.SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          onDevice: !kIsWeb,
          listenMode: stt.ListenMode.dictation,
          autoPunctuation: true,
          enableHapticFeedback: !kIsWeb,
          cancelOnError: true,
          pauseFor: const Duration(seconds: 5),
          listenFor: const Duration(minutes: 5),
        ),
      );
      return const _VoiceDictationStartResult.success();
    } catch (_) {
      await _cancelActiveSession();
      return _VoiceDictationStartResult.failure(
        kIsWeb
            ? 'La dictée n’a pas pu démarrer. Vérifiez l’autorisation du '
                  'microphone et votre connexion.'
            : 'La dictée hors ligne n’a pas pu démarrer. Vérifiez que la '
                  'reconnaissance française est installée sur l’appareil.',
      );
    }
  }

  Future<void> stop(Object owner) async {
    if (!identical(_activeOwner, owner)) return;
    try {
      await _speech.stop();
    } catch (_) {
      _release(owner);
    }
  }

  Future<void> cancel(Object owner) async {
    if (!identical(_activeOwner, owner)) return;
    await _cancelActiveSession();
  }

  Future<void> cancelAny() async {
    if (_activeOwner == null) return;
    await _cancelActiveSession();
  }

  Future<String?> _findFrenchLocale() async {
    // The Web Speech API does not expose its locale catalogue. Explicitly
    // request French instead of rejecting an otherwise supported browser.
    if (kIsWeb) return 'fr-FR';

    final locales = await _speech.locales();
    if (locales.isEmpty) return null;

    String normalize(String value) => value.toLowerCase().replaceAll('-', '_');

    for (final locale in locales) {
      if (normalize(locale.localeId) == 'fr_fr') return locale.localeId;
    }
    for (final locale in locales) {
      if (normalize(locale.localeId).startsWith('fr_') ||
          normalize(locale.localeId) == 'fr') {
        return locale.localeId;
      }
    }
    return null;
  }

  void _relayResult(SpeechRecognitionResult result) {
    _resultCallback?.call(result);
  }

  void _relayStatus(String status) {
    final callback = _statusCallback;
    final owner = _activeOwner;
    callback?.call(status);
    if (owner != null &&
        (status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus)) {
      _release(owner);
    }
  }

  void _relayError(SpeechRecognitionError error) {
    final callback = _errorCallback;
    final owner = _activeOwner;
    callback?.call(error);
    if (owner != null) _release(owner);
  }

  Future<void> _cancelActiveSession() async {
    final callback = _statusCallback;
    try {
      await _speech.cancel();
    } catch (_) {
      // Best effort: a failed cancellation must not keep an editor locked.
    }
    _activeOwner = null;
    _resultCallback = null;
    _statusCallback = null;
    _errorCallback = null;
    callback?.call(stt.SpeechToText.notListeningStatus);
  }

  void _release(Object owner) {
    if (!identical(_activeOwner, owner)) return;
    _activeOwner = null;
    _resultCallback = null;
    _statusCallback = null;
    _errorCallback = null;
  }
}

/// Microphone button for a written note.
///
/// It replaces the current selection and keeps updating that same range while
/// partial results arrive. The existing TextEditingController listener remains
/// responsible for the app's local-first autosave.
class VoiceDictationButton extends StatefulWidget {
  const VoiceDictationButton({
    super.key,
    required this.controller,
    this.focusNode,
    this.onListeningChanged,
    this.onTextChanged,
    this.size = 34,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onListeningChanged;
  final ValueChanged<String>? onTextChanged;
  final double size;

  static bool get isSupported => _VoiceDictationService.isSupportedPlatform;

  static Future<void> cancelActive() =>
      _VoiceDictationService.instance.cancelAny();

  @override
  State<VoiceDictationButton> createState() => _VoiceDictationButtonState();
}

class _VoiceDictationButtonState extends State<VoiceDictationButton> {
  final Object _owner = Object();
  final _VoiceDictationService _service = _VoiceDictationService.instance;
  TextEditingValue? _baseValue;
  bool _isStarting = false;
  bool _isListening = false;

  @override
  void dispose() {
    unawaited(_service.cancel(_owner));
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isStarting) return;
    if (_service.isActiveOwner(_owner) || _isListening) {
      await _service.stop(_owner);
      return;
    }

    setState(() => _isStarting = true);
    _baseValue = widget.controller.value;
    widget.focusNode?.requestFocus();

    if (kIsWeb) {
      final permissionError = await requestVoiceMicrophonePermission();
      if (!mounted) return;
      if (permissionError != null) {
        setState(() => _isStarting = false);
        widget.onListeningChanged?.call(false);
        _showMessage(permissionError);
        return;
      }
    }

    final result = await _service.start(
      owner: _owner,
      onResult: _handleResult,
      onStatus: _handleStatus,
      onError: _handleError,
    );
    if (!mounted) return;
    final listening = result.started && _service.isActiveOwner(_owner);
    setState(() {
      _isStarting = false;
      _isListening = listening;
    });
    widget.onListeningChanged?.call(listening);
    if (!result.started && result.errorMessage != null) {
      _showMessage(result.errorMessage!);
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    if (result.recognizedWords.trim().isEmpty) return;
    final baseValue = _baseValue;
    if (baseValue == null) return;
    widget.controller.value = applyVoiceDictationTranscript(
      baseValue: baseValue,
      transcript: result.recognizedWords,
    );
    widget.onTextChanged?.call(widget.controller.text);
    widget.focusNode?.requestFocus();
  }

  void _handleStatus(String status) {
    if (!mounted) return;
    final listening = status == stt.SpeechToText.listeningStatus;
    if (_isListening != listening || _isStarting) {
      setState(() {
        _isListening = listening;
        if (listening ||
            status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus) {
          _isStarting = false;
        }
      });
      widget.onListeningChanged?.call(listening);
    }
  }

  void _handleError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _isStarting = false;
      _isListening = false;
    });
    widget.onListeningChanged?.call(false);
    _showMessage(_messageForError(error));
  }

  String _messageForError(SpeechRecognitionError error) {
    final code = error.errorMsg.toLowerCase();
    if (code.contains('permission') ||
        code.contains('disabled') ||
        code.contains('not-allowed') ||
        code.contains('not_allowed') ||
        code.contains('service-not-allowed')) {
      return kIsWeb
          ? 'Autorisez le microphone pour app.aidhabitat.fr dans les '
                'réglages du navigateur.'
          : 'Autorisez le microphone et la reconnaissance vocale dans '
                'Réglages pour utiliser la dictée.';
    }
    if (kIsWeb &&
        (code.contains('not supported') ||
            code.contains('not_supported') ||
            code.contains('speech_not_supported'))) {
      return 'La dictée vocale n’est pas disponible dans ce navigateur. '
          'Utilisez une version récente de Safari ou Chrome.';
    }
    if (kIsWeb && code.contains('audio-capture')) {
      return 'Aucun microphone utilisable n’a été détecté par le navigateur.';
    }
    if (code.contains('network') ||
        code.contains('language') ||
        code.contains('on_device')) {
      return kIsWeb
          ? 'La dictée web nécessite une connexion active et la '
                'reconnaissance française du navigateur.'
          : 'La reconnaissance française hors ligne n’est pas disponible '
                'sur cet appareil.';
    }
    if (code.contains('no_match') || code.contains('speech_timeout')) {
      return 'Aucune parole reconnue. Touchez le micro pour réessayer.';
    }
    return 'La dictée s’est interrompue. Le texte déjà reconnu est conservé.';
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (!VoiceDictationButton.isSupported) return const SizedBox.shrink();

    final active = _isListening || _isStarting;
    final foreground = active ? Colors.white : const Color(0xFF76558C);
    final background = active
        ? const Color(0xFFB4232F)
        : const Color(0xFFF2ECF5);

    return Semantics(
      button: true,
      label: active
          ? 'Arrêter la dictée vocale'
          : kIsWeb
          ? 'Démarrer la dictée vocale dans le navigateur'
          : 'Démarrer la dictée vocale hors ligne',
      child: Tooltip(
        message: active
            ? 'Arrêter la dictée'
            : kIsWeb
            ? 'Dicter dans le navigateur'
            : 'Dicter sur l’appareil',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x33B4232F),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            splashRadius: widget.size / 2,
            onPressed: _toggle,
            icon: _isStarting
                ? SizedBox.square(
                    dimension: widget.size * 0.4,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                    ),
                  )
                : Icon(
                    _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: widget.size * 0.52,
                    color: foreground,
                  ),
          ),
        ),
      ),
    );
  }
}
