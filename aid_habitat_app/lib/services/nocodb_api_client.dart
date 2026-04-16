import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/types.dart';
import 'app_config.dart';

class NocodbApiClient {
  NocodbApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

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
    );

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
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Remote dossier update failed (${response.statusCode})');
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

    final streamed = await _client.send(request);
    final responseBody = await streamed.stream.bytesToString();

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
  }) async {
    if (!AppConfig.hasRemoteConfig) {
      throw Exception('Remote config missing');
    }

    final response = await _client.put(
      Uri.parse('$_baseUrl/api/note-pages'),
      headers: _headers,
      body: jsonEncode({
        'patientId': patientId,
        'tabKey': tabKey,
        'pageNumber': pageNumber,
        'drawingJson': drawingJson,
      }),
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

  Future<List<Map<String, dynamic>>> fetchDocuments(String patientId) async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/documents/$patientId'),
      headers: _headers,
    );

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

  Future<List<Map<String, dynamic>>> fetchLocalAuthState() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/auth/local-state'),
      headers: _headers,
    );

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

  Future<List<WikiItem>> fetchWikiItems() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/wiki-library'),
      headers: _headers,
    );

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

  Future<List<RetirementFund>> fetchRetirementFunds() async {
    if (!AppConfig.hasRemoteConfig) return const [];

    final response = await _client.get(
      Uri.parse('$_baseUrl/api/retirement-funds'),
      headers: _headers,
    );

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
    );

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
    );

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
    );

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
    final response = await _client.get(uri, headers: _headers);

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
