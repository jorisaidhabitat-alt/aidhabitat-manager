import 'web_file_picker.dart';

/// Native stub — `pickWebFile` is web-only.
Future<WebPickedFile?> pickWebFileImpl({
  required String accept,
  bool capture = false,
}) async {
  return null;
}

Future<List<WebPickedFile>> pickWebFilesImpl({required String accept}) async {
  return const [];
}
