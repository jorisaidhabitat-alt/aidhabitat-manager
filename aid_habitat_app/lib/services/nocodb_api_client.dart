import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/types.dart';
import 'app_config.dart';
import 'document_repository.dart' show InlineDocumentBytes;
import 'note_repository.dart' show InlinePlanBytes;

/// Thrown when the server returns HTTP 409, indicating the remote record was
/// modified since the client last fetched it.
class ConflictException implements Exception {
  final String message;
  final Map<String, dynamic>? remoteData;

  ConflictException(this.message, {this.remoteData});

  @override
  String toString() => 'ConflictException: $message';
}

/// Erreur transitoire : timeout réseau, déconnexion, 5xx serveur, etc.
/// L'opération locale doit être retentée en silence (la sync engine la
/// repasse en "pending" sans afficher de bandeau rouge à l'utilisateur).
/// Les vraies erreurs fonctionnelles (400/401/403/404) restent des
/// Exception génériques → marquées `failed` et remontées à l'utilisateur.
class TransientRemoteException implements Exception {
  final String message;
  final int? statusCode;

  TransientRemoteException(this.message, {this.statusCode});

  @override
  String toString() => 'TransientRemoteException: $message';
}

/// True si l'erreur réseau sous-jacente doit être considérée comme
/// transitoire (retry silencieux plutôt qu'échec remonté à l'UI).
bool _isTransientNetworkError(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    error is HttpException ||
    error is http.ClientException;

/// Exécute [request] en convertissant les erreurs réseau bas niveau
/// (timeout, socket, http) en [TransientRemoteException]. Les 5xx sont
/// transformés avant le check de statut, les 4xx restent des Exception
/// standards.
Future<http.Response> _runWithTransientGuard(
  String context,
  Future<http.Response> Function() request,
) async {
  try {
    final response = await request();
    if (response.statusCode >= 500) {
      throw TransientRemoteException(
        '$context failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    return response;
  } on TransientRemoteException {
    rethrow;
  } catch (error) {
    if (_isTransientNetworkError(error)) {
      throw TransientRemoteException('$context network error: $error');
    }
    rethrow;
  }
}

class NocodbApiClient {
  NocodbApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Default timeout for regular JSON requests. Kept short so slow networks
  /// fail fast and the sync engine can retry with backoff instead of hanging.
  static const Duration _defaultTimeout = Duration(seconds: 20);

  /// Longer timeout for multipart uploads (documents), which can legitimately
  /// take longer on mobile networks.
  static const Duration _uploadTimeout = Duration(seconds: 60);

  String get _baseUrl => AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-App-Session': AppConfig.appSessionToken,
  };

  Future<List<Dossier>> fetchDossiers() async {
    final raw = await fetchDossierPayloads();
    return raw.map(_mapRemoteDossier).toList();
  }

  /// Returns raw dossier payloads as returned by the server, untouched.
  /// Used by the sync pipeline so ALL server-provided fields (including
  /// those that have no Dart model representation — e.g. `cheminement_*`,
  /// `*_rooms_json`) can be persisted directly into SQLite without being
  /// filtered through the Dossier / Patient / Housing model shape.
  Future<List<Map<String, dynamic>>> fetchDossierPayloads() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/dossiers'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote dossiers fetch failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body);
    if (payload is! List) {
      throw Exception('Unexpected dossiers payload');
    }

    return payload.whereType<Map<String, dynamic>>().toList();
  }

  /// Create a new beneficiary on the server. The server automatically creates
  /// the associated dossier and housing records.
  /// Returns `{ id: remotePatientId, dossierId: remoteDossierId }`.
  ///
  /// Wrappé dans `_runWithTransientGuard` + `.timeout(_defaultTimeout)` :
  /// avant ce wrap, un timeout système ou une déconnexion Wi-Fi APRÈS
  /// que NocoDB ait inséré la ligne mais AVANT la réception de la
  /// réponse → l'op était marquée `failed` puis automatiquement
  /// réhabilitée par `rehabilitateTransientFailures` (le pattern
  /// `ClientException` matchait) → POST rejoué à l'aveugle → 2e ligne
  /// dans NocoDB. Maintenant : 5xx + timeout + erreur réseau remontent
  /// en `TransientRemoteException` qui passe par `markTransientFailure`
  /// (pas de bandeau rouge, retry au cycle suivant) ; la garde
  /// d'idempotence côté `_processDossierOperation` skip le 2e POST si
  /// le 1er a abouti.
  Future<Map<String, dynamic>> createBeneficiary({
    required Map<String, dynamic> fields,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _runWithTransientGuard(
      'Remote beneficiary creation',
      () => _client
          .post(
            Uri.parse('$_baseUrl/api/beneficiaires'),
            headers: _headers,
            body: jsonEncode(fields),
          )
          .timeout(_defaultTimeout),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote beneficiary creation failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data =
        (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return data;
  }

  Future<void> updateDossier({
    required String dossierId,
    required Map<String, dynamic> updates,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.patch(
      Uri.parse('$_baseUrl/api/dossiers/$dossierId'),
      headers: _headers,
      body: jsonEncode(updates),
    ).timeout(_defaultTimeout);

    if (response.statusCode == 409) {
      Map<String, dynamic>? remoteData;
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        remoteData = body;
      } catch (_) {}
      throw ConflictException(
        'Conflit de modification sur le dossier $dossierId',
        remoteData: remoteData,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote dossier update failed (${response.statusCode})');
    }
  }

  /// PATCH /api/beneficiaires/:patientId — updates a beneficiary record.
  /// The [patientId] is the remote/app beneficiary ID (not the SQLite
  /// local_id). Payload uses camelCase keys (firstName, lastName,
  /// trustedPerson: {name, phone, email}, etc.); the server maps them to
  /// NocoDB column names.
  Future<void> updateBeneficiary({
    required String patientId,
    required Map<String, dynamic> updates,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _client
        .patch(
          Uri.parse('$_baseUrl/api/beneficiaires/$patientId'),
          headers: _headers,
          body: jsonEncode(updates),
        )
        .timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote beneficiary update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// PATCH /api/logements/by-beneficiary/:beneficiaryId — updates a housing
  /// record linked to the given beneficiary.
  Future<void> updateLogement({
    required String beneficiaryId,
    required Map<String, dynamic> updates,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _client
        .patch(
          Uri.parse(
              '$_baseUrl/api/logements/by-beneficiary/$beneficiaryId'),
          headers: _headers,
          body: jsonEncode(updates),
        )
        .timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote logement update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// PUT /api/mesures/:dossierId — upsert mesures anthropométriques.
  /// Body : `{deboutHauteurCoude, assisHauteurAssise, assisProfondeurGenoux,
  /// assisHauteurCoudes, observations}` — toutes en string nullable.
  Future<void> updateMesures({
    required String dossierId,
    required Map<String, dynamic> updates,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _runWithTransientGuard(
      'Mesures update',
      () => _client
          .put(
            Uri.parse('$_baseUrl/api/mesures/$dossierId'),
            headers: _headers,
            body: jsonEncode(updates),
          )
          .timeout(_defaultTimeout),
    );
    if (response.statusCode == 409) {
      Map<String, dynamic>? remoteData;
      try {
        remoteData = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}
      throw ConflictException(
        'Conflit mesures pour le dossier $dossierId',
        remoteData: remoteData,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote mesures update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// PUT /api/observations/:dossierId — upsert observations de synthèse
  /// (Projet usager, Résumé préconisations, Observations équipements).
  /// Alimente les pages 6 (« Observation sur les équipements ») et 7
  /// (« Projet ou souhait de l'usager » + « Résumé des préconisations »)
  /// du rapport PDF.
  Future<void> updateObservations({
    required String dossierId,
    required Map<String, dynamic> updates,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _runWithTransientGuard(
      'Observations update',
      () => _client
          .put(
            Uri.parse('$_baseUrl/api/observations/$dossierId'),
            headers: _headers,
            body: jsonEncode(updates),
          )
          .timeout(_defaultTimeout),
    );
    if (response.statusCode == 409) {
      Map<String, dynamic>? remoteData;
      try {
        remoteData = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}
      throw ConflictException(
        'Conflit observations pour le dossier $dossierId',
        remoteData: remoteData,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote observations update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// GET /api/diagnostic-sanitaires/:dossierId — returns the latest
  /// persisted SDB + WC instances for the dossier, or null if no record
  /// has ever been saved server-side.
  Future<Map<String, dynamic>?> fetchDiagnosticSanitairePayload(
    String dossierId,
  ) async {
    if (!AppConfig.hasRemoteConfig) return null;

    final response = await _client
        .get(
          Uri.parse('$_baseUrl/api/diagnostic-sanitaires/$dossierId'),
          headers: _headers,
        )
        .timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote diagnostic sanitaires fetch failed (${response.statusCode})',
      );
    }
    final body = response.body.trim();
    if (body.isEmpty || body == 'null') return null;
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  /// GET /api/visit-recommendations/:dossierId — returns the list of
  /// recommendation items persisted server-side for this dossier.
  Future<List<Map<String, dynamic>>> fetchVisitRecommendationsPayload(
    String dossierId,
  ) async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client
        .get(
          Uri.parse('$_baseUrl/api/visit-recommendations/$dossierId'),
          headers: _headers,
        )
        .timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote visit recommendations fetch failed (${response.statusCode})',
      );
    }
    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) return const [];
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final items = (data['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  /// PUT /api/diagnostic-sanitaires/:dossierId — persists bathroom + WC
  /// instances (arrays) for the given dossier. The server normalises each
  /// instance into the `diagnostic_sanitaires` NocoDB table.
  Future<void> updateDiagnosticSanitaires({
    required String dossierId,
    required List<Map<String, dynamic>> sdbInstances,
    required List<Map<String, dynamic>> wcInstances,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _client
        .put(
          Uri.parse('$_baseUrl/api/diagnostic-sanitaires/$dossierId'),
          headers: _headers,
          body: jsonEncode({
            'sdbInstances': sdbInstances,
            'wcInstances': wcInstances,
          }),
        )
        .timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote diagnostic sanitaires update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// PUT /api/visit-recommendations/:dossierId — replaces the full list of
  /// recommendations for the dossier. Each item must reference a valid
  /// wiki library entry (server-side validation).
  Future<void> updateVisitRecommendations({
    required String dossierId,
    required List<Map<String, dynamic>> items,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _client
        .put(
          Uri.parse('$_baseUrl/api/visit-recommendations/$dossierId'),
          headers: _headers,
          body: jsonEncode({'items': items}),
        )
        .timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote visit recommendations update failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  /// Uploads a document to NocoDB. Callers pass **either** a [file] (native
  /// platforms where `dart:io` works) **or** raw [bytes] (web PWA where
  /// there's no filesystem and the picked file lives in memory only).
  Future<Map<String, dynamic>> uploadDocument({
    required String patientId,
    required String documentLocalId,
    required String title,
    required String fileName,
    required String mimeType,
    required List<String> tags,
    File? file,
    List<int>? bytes,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    if (file == null && bytes == null) {
      throw Exception('uploadDocument: provide either `file` or `bytes`');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/api/documents'),
    );
    request.headers['X-App-Session'] = AppConfig.appSessionToken;
    request.fields['patientId'] = patientId;
    request.fields['documentLocalId'] = documentLocalId;
    request.fields['title'] = title;
    request.fields['fileName'] = fileName;
    request.fields['mimeType'] = mimeType;
    request.fields['tags'] = jsonEncode(tags);
    if (file != null) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: fileName,
        ),
      );
    } else {
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes!, filename: fileName),
      );
    }

    // Transient guard manuel : `MultipartRequest.send` ne passe pas par
    // `_runWithTransientGuard` (qui attend une `Future<http.Response>`),
    // donc on classifie ici les erreurs réseau / 5xx comme transitoires
    // pour que le sync engine les retry au cycle suivant au lieu de les
    // marquer définitivement failed.
    http.StreamedResponse streamed;
    String responseBody;
    try {
      streamed = await _client.send(request).timeout(_uploadTimeout);
      responseBody =
          await streamed.stream.bytesToString().timeout(_uploadTimeout);
    } catch (error) {
      if (_isTransientNetworkError(error)) {
        throw TransientRemoteException(
          'Document upload network error: $error',
        );
      }
      rethrow;
    }

    if (streamed.statusCode >= 500) {
      // 5xx serveur → transient, retry plus tard.
      throw TransientRemoteException(
        'Remote document upload failed (${streamed.statusCode})',
        statusCode: streamed.statusCode,
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // 4xx → vraie erreur fonctionnelle, on remonte.
      throw Exception(
        'Remote document upload failed (${streamed.statusCode}): $responseBody',
      );
    }

    final payload = jsonDecode(responseBody) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final document = (data['document'] as Map?)?.cast<String, dynamic>();
    if (document == null) {
      throw Exception('Unexpected document payload');
    }
    return document;
  }

  /// Supprime un document côté serveur. [remoteDocumentId] est le
  /// `clientDocumentId` (= `uuid_source` côté NocoDB) que Flutter a
  /// assigné à l'upload. Renvoie `true` si la suppression a réussi (ou
  /// si le doc n'existe plus côté serveur — cas idempotent).
  Future<bool> deleteDocument(String remoteDocumentId) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    if (remoteDocumentId.isEmpty) {
      throw Exception('deleteDocument: remoteDocumentId vide');
    }
    final response = await _runWithTransientGuard(
      'Document delete',
      () => _client
          .delete(
            Uri.parse(
              '$_baseUrl/api/documents/${Uri.encodeComponent(remoteDocumentId)}',
            ),
            headers: _headers,
          )
          .timeout(_defaultTimeout),
    );

    // 404 = doc déjà supprimé côté serveur → on considère que c'est un
    // succès idempotent (on évite que la sync queue boucle indéfiniment
    // sur un doc qui n'existe plus).
    if (response.statusCode == 404) return true;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'deleteDocument failed (${response.statusCode}): ${response.body}',
      );
    }
    return true;
  }

  Future<Map<String, dynamic>> upsertNotePage({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required String drawingJson,
    String scopeType = 'dossier_detail',
    String? scopeId,
    String? subTabKey,
    String layoutKind = 'freeform',
    String? planPhase,
    String? previewDataUrl,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _runWithTransientGuard(
      'Remote note sync',
      () => _client
          .put(
            Uri.parse('$_baseUrl/api/note-pages'),
            headers: _headers,
            body: jsonEncode({
              'patientId': patientId,
              'scopeType': scopeType,
              // Fallback: patientId is a valid scopeId for dossier/visit
              // scopes when the caller doesn't know the exact dossierId.
              'scopeId': scopeId ?? patientId,
              'tabKey': tabKey,
              if (subTabKey != null) 'subTabKey': subTabKey,
              'pageNumber': pageNumber,
              'drawingJson': drawingJson,
              'layoutKind': layoutKind,
              // Phase Plans (avant / apres / null). Côté serveur :
              // ignoré si la table NocoDB n'a pas encore la colonne.
              if (planPhase != null) 'planPhase': planPhase,
              // PNG rasterisé du canvas, sous forme de data URL.
              // Persisté dans `mobile_note_pages.preview_data_url`,
              // utilisé par le générateur de rapport pour les
              // pages 9/10 (plans avant/après).
              if (previewDataUrl != null && previewDataUrl.isNotEmpty)
                'previewDataUrl': previewDataUrl,
            }),
          )
          .timeout(_uploadTimeout),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote note sync failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final notePage = (data['notePage'] as Map?)?.cast<String, dynamic>();
    if (notePage == null) {
      throw Exception('Unexpected note payload');
    }
    return notePage;
  }

  /// POST /api/reports/visit/:dossierId — génère le PDF du rapport
  /// de visite côté serveur (cf. server/reports/generateVisitReport.mjs)
  /// et retourne directement les bytes du PDF.
  ///
  /// Le serveur fait :
  ///   1. Vérifie l'auth via X-App-Session
  ///   2. Récupère le dossier scopé pour l'utilisateur
  ///   3. Charge le template PDF + le mapping JSON
  ///   4. Remplit les champs AcroForm avec les valeurs du dossier
  ///   5. Aplatit le formulaire (PDF non-modifiable)
  ///   6. Renvoie `application/pdf`
  ///
  /// L'header `X-Report-Stats` contient un JSON `{applied, missingField,
  /// missingValue}` utile en debug pour diagnostiquer une dérive de
  /// mapping (champ renommé côté template par exemple).
  ///
  /// **inlineDocuments / inlinePlans** : assets locaux non-encore-syncés
  /// vers NocoDB, embarqués en multipart pour que le serveur puisse
  /// générer le PDF même quand la sync NocoDB est en retard ou
  /// intermittente. Si vides, on retombe sur le POST sans body
  /// (comportement v1, lecture intégrale depuis NocoDB côté serveur).
  Future<({Uint8List bytes, String fileName, Map<String, dynamic>? stats})>
      downloadVisitReport({
    required String dossierId,
    List<InlineDocumentBytes> inlineDocuments = const [],
    List<InlinePlanBytes> inlinePlans = const [],
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final hasInlineAssets =
        inlineDocuments.isNotEmpty || inlinePlans.isNotEmpty;

    final http.Response response;
    if (hasInlineAssets) {
      // Multipart : embarque les bytes locaux. Cf. parseInlineReportAssets
      // côté serveur (server/index.mjs).
      response = await _sendReportMultipart(
        dossierId: dossierId,
        inlineDocuments: inlineDocuments,
        inlinePlans: inlinePlans,
      );
    } else {
      // POST simple sans body — le serveur lit tout depuis NocoDB.
      response = await _runWithTransientGuard(
        'Visit report generation',
        () => _client
            .post(
              Uri.parse('$_baseUrl/api/reports/visit/$dossierId'),
              headers: _headers,
            )
            .timeout(_uploadTimeout),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Génération du rapport échouée (${response.statusCode}): '
        '${response.body}',
      );
    }
    // Filename : on extrait depuis Content-Disposition si fourni,
    // sinon fallback "rapport.pdf".
    String fileName = 'rapport.pdf';
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    if (match != null) {
      try {
        fileName = Uri.decodeComponent(match.group(1) ?? fileName);
      } catch (_) {
        fileName = match.group(1) ?? fileName;
      }
    }
    Map<String, dynamic>? stats;
    final statsHeader = response.headers['x-report-stats'];
    if (statsHeader != null && statsHeader.isNotEmpty) {
      try {
        stats = jsonDecode(statsHeader) as Map<String, dynamic>;
      } catch (_) {}
    }
    return (
      bytes: response.bodyBytes,
      fileName: fileName,
      stats: stats,
    );
  }

  /// Construit et envoie la requête multipart pour la génération PDF
  /// avec assets inline. Calque le pattern de `uploadDocument` (multer
  /// memoryStorage côté serveur).
  ///
  /// Convention de fieldnames :
  ///   - `inline_doc_<localId>` : binaires des photos VAD locales
  ///   - `inline_doc_<localId>_meta` : JSON `{fileName, mimeType, tags, dossierId, title}`
  ///   - `inline_plan_<localId>` : binaire PNG des plans locaux
  ///   - `inline_plan_<localId>_meta` : JSON `{planPhase, pageNumber, scopeId, mimeType}`
  Future<http.Response> _sendReportMultipart({
    required String dossierId,
    required List<InlineDocumentBytes> inlineDocuments,
    required List<InlinePlanBytes> inlinePlans,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/api/reports/visit/$dossierId'),
    );
    // Pas de Content-Type ici — multipart le définit lui-même avec
    // boundary. Auth via X-App-Session uniquement.
    request.headers['X-App-Session'] = AppConfig.appSessionToken;

    for (final doc in inlineDocuments) {
      MediaType contentType;
      try {
        contentType = MediaType.parse(doc.mimeType);
      } catch (_) {
        contentType = MediaType('application', 'octet-stream');
      }
      request.files.add(
        http.MultipartFile.fromBytes(
          'inline_doc_${doc.localId}',
          doc.bytes,
          filename: doc.fileName,
          contentType: contentType,
        ),
      );
      request.fields['inline_doc_${doc.localId}_meta'] = jsonEncode({
        'fileName': doc.fileName,
        'mimeType': doc.mimeType,
        'tags': doc.tags,
        if (doc.dossierId != null) 'dossierId': doc.dossierId,
        'title': doc.title,
      });
    }

    for (final plan in inlinePlans) {
      MediaType contentType;
      try {
        contentType = MediaType.parse(plan.mimeType);
      } catch (_) {
        contentType = MediaType('image', 'png');
      }
      request.files.add(
        http.MultipartFile.fromBytes(
          'inline_plan_${plan.localId}',
          plan.bytes,
          filename: '${plan.localId}.png',
          contentType: contentType,
        ),
      );
      request.fields['inline_plan_${plan.localId}_meta'] = jsonEncode({
        'planPhase': plan.planPhase,
        'pageNumber': plan.pageNumber,
        if (plan.scopeId != null) 'scopeId': plan.scopeId,
        'mimeType': plan.mimeType,
      });
    }

    // Transient guard manuel : `MultipartRequest.send` ne passe pas par
    // `_runWithTransientGuard`. On reproduit la classification 5xx /
    // network → TransientRemoteException pour que le sync engine puisse
    // retry au cycle suivant au lieu de marquer définitivement failed.
    http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(_uploadTimeout);
    } catch (error) {
      if (_isTransientNetworkError(error)) {
        throw TransientRemoteException(
          'Visit report network error: $error',
        );
      }
      rethrow;
    }
    if (streamed.statusCode >= 500) {
      throw TransientRemoteException(
        'Visit report failed (${streamed.statusCode})',
        statusCode: streamed.statusCode,
      );
    }
    return http.Response.fromStream(streamed);
  }

  Future<List<Map<String, dynamic>>> fetchDocuments(String patientId) async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/documents/$patientId'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote documents fetch failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['documents'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }

  /// Authenticate against the Express API and return the session token.
  /// Unlike other methods, this does not require [AppConfig.hasRemoteConfig]
  /// since we're establishing it.
  Future<String?> loginToRemote({
    required String email,
    required String password,
  }) async {
    if (AppConfig.apiBaseUrl.trim().isEmpty) return null;

    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      ).timeout(_defaultTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      if (payload['success'] != true) return null;

      final data =
          (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final token = data['token']?.toString();
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchLocalAuthState() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/auth/local-state'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote auth state fetch failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['users'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }

  /// Fetches reference data from `GET /api/references`.
  /// Includes communes, baremesAnah (income thresholds), and other
  /// reference lists.
  Future<ReferencesPayload> fetchReferences() async {
    if (!AppConfig.hasRemoteConfig) return const ReferencesPayload();

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/references'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote references fetch failed (${response.statusCode})',
      );
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('Unexpected references payload');
    }

    final communesRaw = (body['communes'] as List?) ?? const [];
    final baremesRaw = (body['baremesAnah'] as List?) ?? const [];
    final epcisRaw = (body['epcis'] as List?) ?? const [];

    return ReferencesPayload(
      communes: communesRaw
          .whereType<Map>()
          .map((e) => CommuneRef.fromJson(e.cast<String, dynamic>()))
          .toList(),
      baremesAnah: baremesRaw
          .whereType<Map>()
          .map((e) => BaremeAnahRef.fromJson(e.cast<String, dynamic>()))
          .toList(),
      epcis: epcisRaw
          .whereType<Map>()
          .map((e) => EpciRef.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  Future<List<WikiItem>> fetchWikiItems() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/wiki-library'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote wiki items fetch failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => _mapWikiItem(item.cast<String, dynamic>()))
        .toList();
  }

  Future<WikiItem> createWikiItem({
    required String title,
    required String description,
    required String category,
    required List<String> tags,
    String imageDataUrl = '',
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final body = <String, dynamic>{
      'title': title,
      'description': description,
      'category': category,
      'tags': tags,
    };
    if (imageDataUrl.isNotEmpty) body['imageDataUrl'] = imageDataUrl;

    final response = await _client
        .post(
          Uri.parse('$_baseUrl/api/wiki-library'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote wiki item create failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final saved = (data['item'] as Map?)?.cast<String, dynamic>();
    if (saved == null) {
      throw Exception('Unexpected wiki item payload');
    }
    return _mapWikiItem(saved);
  }

  /// Uploads a base64 data URL image as profile photo.
  /// Returns the resolved public photo URL.
  Future<String> uploadProfilePhoto(String imageDataUrl) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client
        .post(
          Uri.parse('$_baseUrl/api/profile/photo'),
          headers: _headers,
          body: jsonEncode({'imageDataUrl': imageDataUrl}),
        )
        .timeout(_uploadTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Profile photo upload failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final photoUrl = data['photoUrl']?.toString() ?? '';
    return photoUrl;
  }

  /// Fetches ANAH service status.
  /// Returns a map with `available`, `registrationUrl`, `publicUrl`, `reason`, `checkedAt`.
  Future<Map<String, dynamic>> fetchAnahStatus() async {
    if (!AppConfig.hasRemoteConfig) {
      // Fallback: assume offline, but still provide the public URLs so the
      // "Ouvrir MaPrimeAdapt'" button works without a backend.
      return {
        'available': false,
        'registrationUrl': 'https://monprojet.anah.gouv.fr/',
        'publicUrl': 'https://www.anah.gouv.fr/',
        'reason': 'Configuration distante manquante',
        'checkedAt': DateTime.now().toIso8601String(),
      };
    }

    final response = await _client
        .get(
          Uri.parse('$_baseUrl/api/anah-status'),
          headers: _headers,
        )
        .timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ANAH status fetch failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final status =
        (data['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    return {
      'available': status['available'] as bool? ?? false,
      'registrationUrl':
          status['registrationUrl']?.toString() ?? 'https://monprojet.anah.gouv.fr/',
      'publicUrl':
          status['publicUrl']?.toString() ?? 'https://www.anah.gouv.fr/',
      'reason': status['reason']?.toString() ?? '',
      'checkedAt':
          status['checkedAt']?.toString() ?? DateTime.now().toIso8601String(),
    };
  }

  Future<WikiItem> updateWikiItem({
    required String itemId,
    required WikiItem item,
    String? imageDataUrl,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final body = <String, dynamic>{
      'title': item.title,
      'description': item.description,
      'tags': item.tags,
      'category': item.category,
    };
    // Only include imageDataUrl when the caller provided a new one —
    // the server interprets an empty string as "clear the image", which
    // is not what we want when the user only edited the text fields.
    if (imageDataUrl != null && imageDataUrl.isNotEmpty) {
      body['imageDataUrl'] = imageDataUrl;
    }

    final response = await _client.put(
      Uri.parse('$_baseUrl/api/wiki-library/$itemId'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote wiki item update failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final saved = (data['item'] as Map?)?.cast<String, dynamic>();
    if (saved == null) {
      throw Exception('Unexpected wiki item payload');
    }
    return _mapWikiItem(saved);
  }

  Future<List<RetirementFund>> fetchRetirementFunds() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/retirement-funds'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote retirement funds fetch failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['funds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => _mapRetirementFund(item.cast<String, dynamic>()))
        .toList();
  }

  Future<List<String>> fetchPrincipalRetirementFundNames() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/retirement-funds-principal'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote principal retirement funds fetch failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['funds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => (item['name'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  Future<RetirementFund> updateRetirementFund({
    required String fundId,
    required RetirementFund fund,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.put(
      Uri.parse('$_baseUrl/api/retirement-funds/$fundId'),
      headers: _headers,
      body: jsonEncode({
        'name': fund.name,
        'phone': fund.phone,
        'audience': fund.audience,
        'requestMethod': fund.requestMethod,
        'requestDelay': fund.requestDelay,
        'aidAmount': fund.aidAmount,
        'therapistNote': fund.therapistNote,
        'website': fund.website,
      }),
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote retirement fund update failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final savedFund = (data['fund'] as Map?)?.cast<String, dynamic>();
    if (savedFund == null) {
      throw Exception('Unexpected retirement fund payload');
    }
    return _mapRetirementFund(savedFund);
  }

  Future<List<AdminAccessMember>> fetchAdminAccessMembers() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/admin/access-members'),
      headers: _headers,
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote admin access fetch failed (${response.statusCode})',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ((data['members'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => _mapAdminAccessMember(item.cast<String, dynamic>()))
        .toList();
  }

  /// Définit un mot de passe explicite pour [email]. Si [password] est
  /// null ou vide, demande au serveur une régénération aléatoire.
  /// Retourne le mot de passe effectivement en vigueur.
  Future<String?> setAccessPassword({
    required String email,
    String? password,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final body = <String, dynamic>{
      'email': email,
      if (password != null && password.isNotEmpty)
        'password': password
      else
        'forceReset': true,
    };
    final response = await _client.post(
      Uri.parse('$_baseUrl/api/auth/provision'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote password set failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final generatedEntries = ((data['generated'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final generated = generatedEntries.firstWhere(
      (entry) => entry['email']?.toString() == email,
      orElse: () => const {},
    );
    return generated['password']?.toString();
  }

  Future<AdminAccessMember> createAccessMember({
    required String email,
    required String displayName,
    required LocalUserRole role,
    String? establishmentId,
    String? password,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final response = await _client.post(
      Uri.parse('$_baseUrl/api/admin/access-members'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'displayName': displayName,
        'role': role == LocalUserRole.admin ? 'ADMIN' : 'ERGO',
        if (establishmentId != null && establishmentId.isNotEmpty)
          'establishmentId': establishmentId,
        if (password != null && password.isNotEmpty) 'password': password,
      }),
    ).timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Remote create member failed (${response.statusCode}): ${response.body}',
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final member = (data['member'] as Map?)?.cast<String, dynamic>();
    if (member == null) {
      throw Exception('Unexpected create member payload');
    }
    return _mapAdminAccessMember(member);
  }

  Future<AdminAccessMember> updateAccessMember({
    required String email,
    String? displayName,
    String? establishmentId,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final encodedEmail = Uri.encodeComponent(email);
    final response = await _client.patch(
      Uri.parse('$_baseUrl/api/admin/access-members/$encodedEmail'),
      headers: _headers,
      body: jsonEncode({
        if (displayName != null) 'displayName': displayName,
        if (establishmentId != null) 'establishmentId': establishmentId,
      }),
    ).timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote update member failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final member = (data['member'] as Map?)?.cast<String, dynamic>();
    if (member == null) {
      throw Exception('Unexpected update member payload');
    }
    return _mapAdminAccessMember(member);
  }

  Future<void> deleteAccessMember(String email) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }
    final encodedEmail = Uri.encodeComponent(email);
    final response = await _client.delete(
      Uri.parse('$_baseUrl/api/admin/access-members/$encodedEmail'),
      headers: _headers,
    ).timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote delete member failed (${response.statusCode})');
    }
  }

  Future<String?> regenerateAccessPassword(String email) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.post(
      Uri.parse('$_baseUrl/api/auth/provision'),
      headers: _headers,
      body: jsonEncode({'email': email, 'forceReset': true}),
    ).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote password reset failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final generatedEntries = ((data['generated'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final generated = generatedEntries.firstWhere(
      (entry) => entry['email']?.toString() == email,
      orElse: () => const {},
    );
    return generated['password']?.toString();
  }

  Future<Map<String, dynamic>?> fetchNotePage({
    required String patientId,
    required String tabKey,
    required int pageNumber,
  }) async {
    if (!AppConfig.hasRemoteConfig) return null;

    final uri = Uri.parse(
      '$_baseUrl/api/note-pages/$patientId',
    ).replace(queryParameters: {'tabKey': tabKey, 'pageNumber': '$pageNumber'});
    final response =
        await _client.get(uri, headers: _headers).timeout(_defaultTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote note fetch failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final notePages = ((data['notePages'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    if (notePages.isEmpty) return null;
    return notePages.first;
  }

  Dossier _mapRemoteDossier(Map<String, dynamic> json) {
    final patientJson =
        (json['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
    final housingJson =
        (json['housing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final trustedPersonJson =
        (patientJson['trustedPerson'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final occupantsList =
        (patientJson['occupants'] as List?)
                ?.whereType<Map>()
                .map((e) => Occupant.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const <Occupant>[];

    return Dossier(
      id: json['id']?.toString() ?? '',
      patient: Patient(
        id: patientJson['id']?.toString() ?? '',
        firstName: patientJson['firstName']?.toString() ?? '',
        lastName: patientJson['lastName']?.toString() ?? '',
        secondFirstName: patientJson['secondFirstName']?.toString() ?? '',
        secondLastName: patientJson['secondLastName']?.toString() ?? '',
        birthDate: patientJson['birthDate']?.toString() ?? '',
        phone: patientJson['phone']?.toString() ?? '',
        email: patientJson['email']?.toString() ?? '',
        address: patientJson['address']?.toString() ?? '',
        city: patientJson['city']?.toString() ?? '',
        cityId: patientJson['cityId']?.toString() ?? '',
        zipCode: patientJson['zipCode']?.toString() ?? '',
        familySituation: patientJson['familySituation']?.toString() ?? '',
        occupationStatus:
            patientJson['occupationStatus']?.toString() ?? '',
        incomeCategory: patientJson['incomeCategory']?.toString() ?? '',
        numberPeople: _parseInt(patientJson['numberPeople']),
        fiscalRevenue: _parseDouble(patientJson['fiscalRevenue']),
        occupants: occupantsList,
        apa: _parseBool(patientJson['apa']),
        invalidity: _parseBool(patientJson['invalidity']),
        invalidityTxt: patientJson['invalidityTxt']?.toString() ?? '',
        homeHelp: _parseBool(patientJson['homeHelp']),
        homeHelpTxt: patientJson['homeHelpTxt']?.toString() ?? '',
        dependenceTxt: patientJson['dependenceTxt']?.toString() ?? '',
        caisseRetraitePrincipale:
            patientJson['caisseRetraitePrincipale']?.toString() ?? '',
        caissesRetraiteComplementaires:
            patientJson['caissesRetraiteComplementaires']?.toString() ?? '',
        trustedPerson: TrustedPerson(
          name: trustedPersonJson['name']?.toString() ?? '',
          phone: trustedPersonJson['phone']?.toString() ?? '',
          email: trustedPersonJson['email']?.toString() ?? '',
        ),
      ),
      status: _mapStatus(json['status']?.toString()),
      ergoId: json['ergoId']?.toString() ?? '',
      visitDate: json['visitDate']?.toString(),
      housing: Housing(
        type: _mapHousingType(housingJson['typology']?.toString()),
        year: int.tryParse(housingJson['yearConstruction']?.toString() ?? ''),
        surface: double.tryParse(housingJson['surface']?.toString() ?? ''),
        heating: _mapHeatingMode(housingJson['heatingMode']?.toString()),
        accessibilityNotes:
            housingJson['accessibilityNotes']?.toString() ??
            housingJson['accessObservation']?.toString() ??
            '',
      ),
      autonomyNotes: json['autonomyNotes']?.toString() ?? '',
      // Extended dossier-level fields the server maps from the NocoDB row.
      compteAnah: json['compteAnah']?.toString() ?? '',
      natureAccompagnement: json['natureAccompagnement']?.toString() ?? '',
      envoiRapport: json['envoiRapport']?.toString() ?? '',
      personnesPresentesVisite:
          json['personnesPresentesVisite']?.toString() ?? '',
      medicalContext: json['medicalContext'] is Map
          ? MedicalContext.fromJson(
              (json['medicalContext'] as Map).cast<String, dynamic>())
          : null,
      autonomy: json['autonomy'] is Map
          ? AutonomyData.fromJson(
              (json['autonomy'] as Map).cast<String, dynamic>())
          : null,
      plans: const {
        'PF1': FinancialPlan(id: 'PF1'),
        'PF2': FinancialPlan(id: 'PF2'),
        'PF3': FinancialPlan(id: 'PF3'),
      },
      createdAt:
          json['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
      syncState: SyncState.synced,
    );
  }

  /// Lenient int parser — the server sometimes serialises numeric fields
  /// as strings ("3") or numbers (3 / 3.0). Returns null on any other
  /// value so callers can fall back to their own default.
  int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// Lenient double parser (fiscalRevenue etc.).
  double? _parseDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  /// Lenient bool parser — server-side booleans may come as real `bool`,
  /// numeric (`0` / `1`) or stringified (`"true"` / `"oui"`).
  bool _parseBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'oui' || s == 'yes';
    }
    return false;
  }

  DossierStatus _mapStatus(String? status) {
    switch (status) {
      case 'Validé':
        return DossierStatus.GRANT_VALIDATED;
      case 'En cours':
        return DossierStatus.IN_PROGRESS;
      case 'Clos':
        return DossierStatus.CLOSED;
      case 'À visiter':
      default:
        return DossierStatus.TO_VISIT;
    }
  }

  HousingType _mapHousingType(String? value) {
    return value == 'Appartement' ? HousingType.APARTMENT : HousingType.HOUSE;
  }

  HeatingMode _mapHeatingMode(String? value) {
    switch ((value ?? '').toLowerCase()) {
      case 'gaz':
        return HeatingMode.GAS;
      case 'bois':
        return HeatingMode.WOOD;
      case 'fioul':
        return HeatingMode.OIL;
      default:
        return HeatingMode.ELECTRIC;
    }
  }

  WikiItem _mapWikiItem(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.map((tag) => tag.toString()).toList()
        : <String>[];
    return WikiItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      tags: tags,
      category: json['category']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
    );
  }

  RetirementFund _mapRetirementFund(Map<String, dynamic> json) {
    return RetirementFund(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      audience: json['audience']?.toString() ?? '',
      requestMethod: json['requestMethod']?.toString() ?? '',
      requestDelay: json['requestDelay']?.toString() ?? '',
      aidAmount: json['aidAmount']?.toString() ?? '',
      therapistNote: json['therapistNote']?.toString() ?? '',
      website: json['website']?.toString() ?? '',
      logoUrl: json['logoUrl']?.toString() ?? '',
      lastEditedAt: json['lastEditedAt']?.toString(),
      createdAt: json['createdAt']?.toString() ??
          json['created_at']?.toString() ??
          json['updatedAt']?.toString(),
    );
  }

  AdminAccessMember _mapAdminAccessMember(Map<String, dynamic> json) {
    return AdminAccessMember(
      email: json['email']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      role: _mapRemoteRole(json['role']?.toString()),
      selectable: json['selectable'] == true,
      establishmentLabel: json['establishmentLabel']?.toString() ?? '',
      ergoLabel: json['ergoLabel']?.toString() ?? '',
      hasPassword: json['hasPassword'] == true,
      generatedPassword: json['generatedPassword']?.toString() ?? '',
      createdAt: json['createdAt']?.toString(),
    );
  }

  LocalUserRole _mapRemoteRole(String? role) {
    switch ((role ?? '').trim().toUpperCase()) {
      case 'ADMIN':
        return LocalUserRole.admin;
      case 'ERGO':
      default:
        return LocalUserRole.ergo;
    }
  }
}
