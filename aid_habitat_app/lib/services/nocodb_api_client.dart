import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/types.dart';
import 'app_config.dart';

/// Thrown when the server returns HTTP 409, indicating the remote record was
/// modified since the client last fetched it.
class ConflictException implements Exception {
  final String message;
  final Map<String, dynamic>? remoteData;

  ConflictException(this.message, {this.remoteData});

  @override
  String toString() => 'ConflictException: $message';
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

    return payload
        .whereType<Map<String, dynamic>>()
        .map(_mapRemoteDossier)
        .toList();
  }

  /// Create a new beneficiary on the server. The server automatically creates
  /// the associated dossier and housing records.
  /// Returns `{ id: remotePatientId, dossierId: remoteDossierId }`.
  Future<Map<String, dynamic>> createBeneficiary({
    required Map<String, dynamic> fields,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.post(
      Uri.parse('$_baseUrl/api/beneficiaires'),
      headers: _headers,
      body: jsonEncode(fields),
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

  Future<Map<String, dynamic>> uploadDocument({
    required String patientId,
    required String documentLocalId,
    required String title,
    required String fileName,
    required String mimeType,
    required List<String> tags,
    required File file,
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
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
    request.files.add(
      await http.MultipartFile.fromPath('file', file.path, filename: fileName),
    );

    final streamed = await _client.send(request).timeout(_uploadTimeout);
    final responseBody =
        await streamed.stream.bytesToString().timeout(_uploadTimeout);

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception(
        'Remote document upload failed (${streamed.statusCode})',
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

  Future<Map<String, dynamic>> upsertNotePage({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required String drawingJson,
    String scopeType = 'dossier_detail',
    String? scopeId,
    String? subTabKey,
    String layoutKind = 'freeform',
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.put(
      Uri.parse('$_baseUrl/api/note-pages'),
      headers: _headers,
      body: jsonEncode({
        'patientId': patientId,
        'scopeType': scopeType,
        // Fallback: patientId is a valid scopeId for dossier/visit scopes when
        // the caller doesn't know the exact dossierId.
        'scopeId': scopeId ?? patientId,
        'tabKey': tabKey,
        if (subTabKey != null) 'subTabKey': subTabKey,
        'pageNumber': pageNumber,
        'drawingJson': drawingJson,
        'layoutKind': layoutKind,
      }),
    ).timeout(_defaultTimeout);

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

    return ReferencesPayload(
      communes: communesRaw
          .whereType<Map>()
          .map((e) => CommuneRef.fromJson(e.cast<String, dynamic>()))
          .toList(),
      baremesAnah: baremesRaw
          .whereType<Map>()
          .map((e) => BaremeAnahRef.fromJson(e.cast<String, dynamic>()))
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
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.put(
      Uri.parse('$_baseUrl/api/wiki-library/$itemId'),
      headers: _headers,
      body: jsonEncode({
        'title': item.title,
        'description': item.description,
        'tags': item.tags,
        'category': item.category,
      }),
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

    return Dossier(
      id: json['id']?.toString() ?? '',
      patient: Patient(
        id: patientJson['id']?.toString() ?? '',
        firstName: patientJson['firstName']?.toString() ?? '',
        lastName: patientJson['lastName']?.toString() ?? '',
        birthDate: patientJson['birthDate']?.toString() ?? '',
        phone: patientJson['phone']?.toString() ?? '',
        email: patientJson['email']?.toString() ?? '',
        address: patientJson['address']?.toString() ?? '',
        city: patientJson['city']?.toString() ?? '',
        zipCode: patientJson['zipCode']?.toString() ?? '',
        familySituation: patientJson['familySituation']?.toString() ?? '',
        incomeCategory: patientJson['incomeCategory']?.toString() ?? '',
        numberPeople: _parseInt(patientJson['numberPeople']),
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
