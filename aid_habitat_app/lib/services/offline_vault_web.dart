// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'secure_session_storage.dart';

const _textPrefix = 'AHENC:v1:';
const _bytesPrefix = 'AHENCB:v1:';
const _aesGcmAlgorithmName = 'AES-GCM';
const _ivLength = 12;

JSAny? _cachedKey;

Future<String> sealString(String value) async {
  if (value.isEmpty || value.startsWith(_textPrefix)) return value;
  final sealed = await _seal(utf8.encode(value), _textPrefix);
  return sealed;
}

Future<String> openString(String value) async {
  if (!value.startsWith(_textPrefix)) return value;
  final bytes = await _open(value, _textPrefix);
  return utf8.decode(bytes);
}

Future<Uint8List> sealBytes(List<int> value) async {
  if (value.isEmpty) return Uint8List(0);
  final raw = value is Uint8List ? value : Uint8List.fromList(value);
  if (_looksLikeSealedBytes(raw)) return raw;
  final envelope = await _seal(raw, _bytesPrefix);
  return Uint8List.fromList(utf8.encode(envelope));
}

Future<Uint8List> openBytes(Object? value) async {
  final raw = _asBytes(value);
  if (raw.isEmpty || !_looksLikeSealedBytes(raw)) return raw;
  final envelope = utf8.decode(raw);
  return _open(envelope, _bytesPrefix);
}

Future<String> _seal(List<int> plain, String prefix) async {
  final key = await _cryptoKey();
  final iv = _randomBytes(_ivLength);
  final promise = _subtleCrypto().callMethodVarArgs<JSPromise<JSArrayBuffer>>(
    'encrypt'.toJS,
    [_aesGcmAlgorithm(iv), key, Uint8List.fromList(plain).toJS],
  );
  final cipherBuffer = (await promise.toDart).toDart;
  final cipher = Uint8List.view(cipherBuffer);
  return '$prefix${base64UrlEncode(iv)}:${base64UrlEncode(cipher)}';
}

Future<Uint8List> _open(String envelope, String prefix) async {
  if (!envelope.startsWith(prefix)) {
    return Uint8List.fromList(utf8.encode(envelope));
  }
  final parts = envelope.substring(prefix.length).split(':');
  if (parts.length != 2) {
    throw const FormatException('Encrypted offline value has invalid format');
  }
  final iv = base64Url.decode(base64Url.normalize(parts[0]));
  final cipher = base64Url.decode(base64Url.normalize(parts[1]));
  final key = await _cryptoKey();
  final promise = _subtleCrypto().callMethodVarArgs<JSPromise<JSArrayBuffer>>(
    'decrypt'.toJS,
    [
      _aesGcmAlgorithm(Uint8List.fromList(iv)),
      key,
      Uint8List.fromList(cipher).toJS,
    ],
  );
  final plainBuffer = (await promise.toDart).toDart;
  return Uint8List.view(plainBuffer);
}

Future<JSAny> _cryptoKey() async {
  final cached = _cachedKey;
  if (cached != null) return cached;

  final storedKey = await SecureSessionStorage.instance.ensureMasterKey();
  final keyBytes = base64Url.decode(base64Url.normalize(storedKey));
  final promise = _subtleCrypto().callMethodVarArgs<JSPromise<JSAny>>(
    'importKey'.toJS,
    [
      'raw'.toJS,
      Uint8List.fromList(keyBytes).toJS,
      ({'name': _aesGcmAlgorithmName}.jsify() as JSObject),
      false.toJS,
      (['encrypt', 'decrypt'].jsify() as JSAny),
    ],
  );
  final imported = await promise.toDart;
  _cachedKey = imported;
  return imported;
}

Uint8List _randomBytes(int length) {
  final bytes = Uint8List(length);
  _webCrypto().getRandomValues(bytes);
  return bytes;
}

html.Crypto _webCrypto() {
  final crypto = html.window.crypto;
  if (crypto == null) {
    throw StateError('WebCrypto indisponible sur ce navigateur.');
  }
  return crypto;
}

JSObject _subtleCrypto() {
  final subtle = _webCrypto().subtle;
  if (subtle == null) {
    throw StateError('WebCrypto SubtleCrypto indisponible sur ce navigateur.');
  }
  return JSObject.fromInteropObject(subtle);
}

JSObject _aesGcmAlgorithm(Uint8List iv) {
  return {'name': _aesGcmAlgorithmName, 'iv': iv.toJS}.jsify() as JSObject;
}

Uint8List _asBytes(Object? value) {
  if (value == null) return Uint8List(0);
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  return Uint8List(0);
}

bool _looksLikeSealedBytes(Uint8List value) {
  if (value.length < _bytesPrefix.length) return false;
  try {
    return utf8.decode(value, allowMalformed: false).startsWith(_bytesPrefix);
  } catch (_) {
    return false;
  }
}
