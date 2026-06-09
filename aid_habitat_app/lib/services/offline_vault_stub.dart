import 'dart:typed_data';

Future<String> sealString(String value) async => value;

Future<String> openString(String value) async => value;

Future<Uint8List> sealBytes(List<int> value) async {
  if (value is Uint8List) return value;
  return Uint8List.fromList(value);
}

Future<Uint8List> openBytes(Object? value) async {
  if (value == null) return Uint8List(0);
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  return Uint8List(0);
}
