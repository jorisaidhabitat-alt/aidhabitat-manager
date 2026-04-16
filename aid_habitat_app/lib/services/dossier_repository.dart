import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class DossierRepository {
  DossierRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  String _uuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<void> initialize() async {
    await _database.ensureSeeded();
  }

  /// Create a new beneficiary + housing + dossier locally. All three entities
  /// are inserted into SQLite with local IDs and a sync operation is enqueued
  /// for each so they are pushed to the server when connectivity is available.
  ///
  /// Returns the newly created [Dossier] immediately — no network required.
  Future<Dossier> createDossierOffline({
    required String firstName,
    required String lastName,
    String ergoId = '',
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final patientLocalId = _generateLocalId();
    final housingLocalId = _generateLocalId();
    final dossierLocalId = _generateLocalId();

    final patient = Patient(
      id: patientLocalId,
      firstName: firstName,
      lastName: lastName,
      birthDate: '',
      phone: '',
      email: '',
      address: '',
      city: '',
      zipCode: '',
      familySituation: '',
      incomeCategory: '',
      trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
    );

    final housing = Housing(
      type: HousingType.HOUSE,
      heating: HeatingMode.ELECTRIC,
      accessibilityNotes: '',
    );

    await db.transaction((txn) async {
      await txn.insert('patients', {
        'local_id': patientLocalId,
        'remote_patient_id': null,
        'first_name': firstName,
        'last_name': lastName,
        'birth_date': '',
        'phone': '',
        'email': '',
        'address': '',
        'city': '',
        'zip_code': '',
        'family_situation': '',
        'income_category': '',
        'trusted_person_json': jsonEncode({
          'name': '',
          'phone': '',
          'email': '',
        }),
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      await txn.insert('housings', {
        'local_id': housingLocalId,
        'remote_housing_id': null,
        'patient_local_id': patientLocalId,
        'type': HousingType.HOUSE.name,
        'year_value': null,
        'surface': null,
        'heating_mode': HeatingMode.ELECTRIC.name,
        'accessibility_notes': '',
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      await txn.insert('dossiers', {
        'local_id': dossierLocalId,
        'remote_dossier_id': null,
        'patient_local_id': patientLocalId,
        'housing_local_id': housingLocalId,
        'status': DossierStatus.TO_VISIT.name,
        'ergo_id': ergoId,
        'visit_date': null,
        'autonomy_notes': '',
        'plans_json': jsonEncode(['PF1', 'PF2', 'PF3']),
        'created_at': now,
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      // Enqueue a sync operation to create the full dossier on the server
      // when connectivity is available.
      await txn.insert('sync_operations', {
        'id': 'create_$dossierLocalId',
        'entity_type': 'dossier',
        'entity_local_id': dossierLocalId,
        'operation_type': 'create',
        'payload_json': jsonEncode({
          'dossierLocalId': dossierLocalId,
          'patientLocalId': patientLocalId,
          'housingLocalId': housingLocalId,
          'firstName': firstName,
          'lastName': lastName,
          'ergoId': ergoId,
        }),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    return Dossier(
      id: dossierLocalId,
      patient: patient,
      status: DossierStatus.TO_VISIT,
      ergoId: ergoId,
      housing: housing,
      autonomyNotes: '',
      plans: const {
        'PF1': FinancialPlan(id: 'PF1'),
        'PF2': FinancialPlan(id: 'PF2'),
        'PF3': FinancialPlan(id: 'PF3'),
      },
      createdAt: now,
      syncState: SyncState.localOnly,
    );
  }

  /// Update local patient fields for an existing dossier and enqueue a sync.
  Future<void> updatePatientLocal({
    required String patientLocalId,
    required Map<String, dynamic> updates,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    final dbUpdates = <String, dynamic>{'updated_at': now};
    if (updates.containsKey('firstName')) dbUpdates['first_name'] = updates['firstName'];
    if (updates.containsKey('lastName')) dbUpdates['last_name'] = updates['lastName'];
    if (updates.containsKey('phone')) dbUpdates['phone'] = updates['phone'];
    if (updates.containsKey('email')) dbUpdates['email'] = updates['email'];
    if (updates.containsKey('address')) dbUpdates['address'] = updates['address'];
    if (updates.containsKey('city')) dbUpdates['city'] = updates['city'];
    if (updates.containsKey('zipCode')) dbUpdates['zip_code'] = updates['zipCode'];
    if (updates.containsKey('birthDate')) dbUpdates['birth_date'] = updates['birthDate'];
    if (updates.containsKey('familySituation')) dbUpdates['family_situation'] = updates['familySituation'];
    if (updates.containsKey('incomeCategory')) dbUpdates['income_category'] = updates['incomeCategory'];

    // Only update sync_state if currently synced — don't overwrite localOnly
    final currentRows = await db.query(
      'patients',
      columns: ['sync_state'],
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
      limit: 1,
    );
    if (currentRows.isNotEmpty) {
      final current = currentRows.first['sync_state'] as String;
      if (current == SyncState.synced.name) {
        dbUpdates['sync_state'] = SyncState.pendingSync.name;
      }
    }

    await db.update(
      'patients',
      dbUpdates,
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
    );

    // Enqueue sync operation (upsert by entity key to avoid duplicates).
    final opId = 'patient_update_$patientLocalId';
    await db.insert('sync_operations', {
      'id': opId,
      'entity_type': 'patient',
      'entity_local_id': patientLocalId,
      'operation_type': 'update',
      'payload_json': jsonEncode({
        'patientLocalId': patientLocalId,
        'updates': updates,
      }),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String _generateLocalId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'local_$hex';
  }

  Future<List<Dossier>> fetchAllDossiers() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT
        d.local_id AS dossier_local_id,
        d.remote_dossier_id AS dossier_remote_id,
        d.status AS dossier_status,
        d.ergo_id AS dossier_ergo_id,
        d.visit_date AS dossier_visit_date,
        d.autonomy_notes AS dossier_autonomy_notes,
        d.created_at AS dossier_created_at,
        d.sync_state AS dossier_sync_state,
        p.local_id AS patient_local_id,
        p.remote_patient_id AS patient_remote_id,
        p.first_name AS patient_first_name,
        p.last_name AS patient_last_name,
        p.birth_date AS patient_birth_date,
        p.phone AS patient_phone,
        p.email AS patient_email,
        p.address AS patient_address,
        p.city AS patient_city,
        p.zip_code AS patient_zip_code,
        p.family_situation AS patient_family_situation,
        p.income_category AS patient_income_category,
        p.trusted_person_json AS patient_trusted_person_json,
        h.local_id AS housing_local_id,
        h.type AS housing_type,
        h.year_value AS housing_year_value,
        h.surface AS housing_surface,
        h.heating_mode AS housing_heating_mode,
        h.accessibility_notes AS housing_accessibility_notes
      FROM dossiers d
      INNER JOIN patients p ON p.local_id = d.patient_local_id
      INNER JOIN housings h ON h.local_id = d.housing_local_id
      ORDER BY d.created_at DESC
    ''');

    return rows.map(_mapDossierRow).toList();
  }

  Future<List<SyncOperation>> fetchPendingOperations() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      where: 'status != ?',
      whereArgs: [SyncOperationStatus.completed.name],
      orderBy: 'created_at ASC',
    );

    return rows.map((row) {
      return SyncOperation(
        id: row['id'] as String,
        entityType: row['entity_type'] as String,
        entityLocalId: row['entity_local_id'] as String,
        operationType: row['operation_type'] as String,
        payloadJson: row['payload_json'] as String,
        status: SyncOperationStatus.values.byName(row['status'] as String),
        attemptCount: row['attempt_count'] as int? ?? 0,
        lastError: row['last_error'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    }).toList();
  }

  Future<void> mergeRemoteDossiers(List<Dossier> remoteDossiers) async {
    if (remoteDossiers.isEmpty) return;
    final db = await _database.database;

    await db.transaction((txn) async {
      for (final dossier in remoteDossiers) {
        final existingRows = await txn.query(
          'dossiers',
          columns: ['sync_state'],
          where: 'local_id = ?',
          whereArgs: [dossier.id],
          limit: 1,
        );

        final existingSyncState = existingRows.isEmpty
            ? SyncState.synced
            : SyncState.values.byName(
                existingRows.first['sync_state'] as String,
              );

        if (existingRows.isNotEmpty && existingSyncState != SyncState.synced) {
          continue;
        }

        final now = DateTime.now().toIso8601String();
        await txn.insert('patients', {
          'local_id': dossier.patient.id,
          'remote_patient_id': dossier.patient.id,
          'first_name': dossier.patient.firstName,
          'last_name': dossier.patient.lastName,
          'birth_date': dossier.patient.birthDate,
          'phone': dossier.patient.phone,
          'email': dossier.patient.email,
          'address': dossier.patient.address,
          'city': dossier.patient.city,
          'zip_code': dossier.patient.zipCode,
          'family_situation': dossier.patient.familySituation,
          'income_category': dossier.patient.incomeCategory,
          'trusted_person_json': jsonEncode({
            'name': dossier.patient.trustedPerson.name,
            'phone': dossier.patient.trustedPerson.phone,
            'email': dossier.patient.trustedPerson.email,
          }),
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final housingLocalId = 'housing_${dossier.id}';
        await txn.insert('housings', {
          'local_id': housingLocalId,
          'remote_housing_id': housingLocalId,
          'patient_local_id': dossier.patient.id,
          'type': dossier.housing.type.name,
          'year_value': dossier.housing.year,
          'surface': dossier.housing.surface,
          'heating_mode': dossier.housing.heating.name,
          'accessibility_notes': dossier.housing.accessibilityNotes,
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.insert('dossiers', {
          'local_id': dossier.id,
          'remote_dossier_id': dossier.id,
          'patient_local_id': dossier.patient.id,
          'housing_local_id': housingLocalId,
          'status': dossier.status.name,
          'ergo_id': dossier.ergoId,
          'visit_date': dossier.visitDate,
          'autonomy_notes': dossier.autonomyNotes,
          'plans_json': jsonEncode(dossier.plans.keys.toList()),
          'created_at': dossier.createdAt,
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> forceReplaceWithRemote(Dossier remote) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.insert('patients', {
        'local_id': remote.patient.id,
        'remote_patient_id': remote.patient.id,
        'first_name': remote.patient.firstName,
        'last_name': remote.patient.lastName,
        'birth_date': remote.patient.birthDate,
        'phone': remote.patient.phone,
        'email': remote.patient.email,
        'address': remote.patient.address,
        'city': remote.patient.city,
        'zip_code': remote.patient.zipCode,
        'family_situation': remote.patient.familySituation,
        'income_category': remote.patient.incomeCategory,
        'trusted_person_json': jsonEncode({
          'name': remote.patient.trustedPerson.name,
          'phone': remote.patient.trustedPerson.phone,
          'email': remote.patient.trustedPerson.email,
        }),
        'updated_at': now,
        'remote_updated_at': now,
        'sync_state': SyncState.synced.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final housingLocalId = 'housing_${remote.id}';
      await txn.insert('housings', {
        'local_id': housingLocalId,
        'remote_housing_id': housingLocalId,
        'patient_local_id': remote.patient.id,
        'type': remote.housing.type.name,
        'year_value': remote.housing.year,
        'surface': remote.housing.surface,
        'heating_mode': remote.housing.heating.name,
        'accessibility_notes': remote.housing.accessibilityNotes,
        'updated_at': now,
        'remote_updated_at': now,
        'sync_state': SyncState.synced.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.insert('dossiers', {
        'local_id': remote.id,
        'remote_dossier_id': remote.id,
        'patient_local_id': remote.patient.id,
        'housing_local_id': housingLocalId,
        'status': remote.status.name,
        'ergo_id': remote.ergoId,
        'visit_date': remote.visitDate,
        'autonomy_notes': remote.autonomyNotes,
        'plans_json': jsonEncode(remote.plans.keys.toList()),
        'created_at': remote.createdAt,
        'updated_at': now,
        'remote_updated_at': now,
        'sync_state': SyncState.synced.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> updatePatientFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update(
      'patients',
      fields,
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
    );
  }

  Future<void> updateHousingFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update(
      'housings',
      fields,
      where: 'patient_local_id = ?',
      whereArgs: [patientLocalId],
    );
  }

  Future<void> updateDossierFields(
    String dossierLocalId,
    Map<String, dynamic> fields,
  ) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update(
      'dossiers',
      fields,
      where: 'local_id = ?',
      whereArgs: [dossierLocalId],
    );
  }

  Future<Map<String, dynamic>> fetchFormData(
    String patientId,
    String formKey,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: ['text_content'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, 'form_$formKey', 0],
      limit: 1,
    );
    if (rows.isEmpty) return {};
    final text = rows.first['text_content'] as String? ?? '';
    if (text.isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> saveFormData(
    String patientId,
    String formKey,
    Map<String, dynamic> data,
  ) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'form_${patientId}_$formKey';
    await db.insert(
      'note_pages',
      {
        'local_id': noteId,
        'patient_local_id': patientId,
        'tab_key': 'form_$formKey',
        'page_number': 0,
        'text_content': jsonEncode(data),
        'drawing_json': null,
        'drawing_local_path': null,
        'drawing_remote_path': null,
        'drawing_remote_url': null,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Dossier _mapDossierRow(Map<String, Object?> row) {
    final trustedPersonJson =
        jsonDecode(row['patient_trusted_person_json'] as String)
            as Map<String, dynamic>;

    return Dossier(
      id: row['dossier_local_id'] as String,
      patient: Patient(
        id: row['patient_local_id'] as String,
        firstName: row['patient_first_name'] as String,
        lastName: row['patient_last_name'] as String,
        birthDate: row['patient_birth_date'] as String,
        phone: row['patient_phone'] as String,
        email: row['patient_email'] as String,
        address: row['patient_address'] as String,
        city: row['patient_city'] as String,
        zipCode: row['patient_zip_code'] as String,
        familySituation: row['patient_family_situation'] as String,
        incomeCategory: row['patient_income_category'] as String,
        trustedPerson: TrustedPerson(
          name: trustedPersonJson['name'] as String? ?? '',
          phone: trustedPersonJson['phone'] as String? ?? '',
          email: trustedPersonJson['email'] as String? ?? '',
        ),
      ),
      status: DossierStatus.values.byName(row['dossier_status'] as String),
      ergoId: row['dossier_ergo_id'] as String,
      visitDate: row['dossier_visit_date'] as String?,
      housing: Housing(
        type: HousingType.values.byName(row['housing_type'] as String),
        year: row['housing_year_value'] as int?,
        surface: (row['housing_surface'] as num?)?.toDouble(),
        heating: HeatingMode.values.byName(
          row['housing_heating_mode'] as String,
        ),
        accessibilityNotes: row['housing_accessibility_notes'] as String,
      ),
      autonomyNotes: row['dossier_autonomy_notes'] as String,
      plans: const {
        'PF1': FinancialPlan(id: 'PF1'),
        'PF2': FinancialPlan(id: 'PF2'),
        'PF3': FinancialPlan(id: 'PF3'),
      },
      createdAt: row['dossier_created_at'] as String,
      syncState: SyncState.values.byName(row['dossier_sync_state'] as String),
    );
  }

  // ---------------------------------------------------------------------------
  // Visit report CRUD methods
  // ---------------------------------------------------------------------------

  Future<void> updatePatient(String patientId, Map<String, dynamic> fields) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update('patients', fields, where: 'local_id = ?', whereArgs: [patientId]);
  }

  Future<void> updateHousing(String dossierId, Map<String, dynamic> fields) async {
    final db = await _database.database;
    final rows = await db.query('dossiers', columns: ['housing_local_id'], where: 'local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return;
    final housingId = rows.first['housing_local_id'] as String;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update('housings', fields, where: 'local_id = ?', whereArgs: [housingId]);
  }

  Future<void> updateDossierFields(String dossierId, Map<String, dynamic> fields) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update('dossiers', fields, where: 'local_id = ?', whereArgs: [dossierId]);
  }

  Future<Map<String, dynamic>?> fetchContexteDeVie(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query('contexte_de_vie', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'medicalContext': row['medical_context_json'] != null ? jsonDecode(row['medical_context_json'] as String) : null,
      'autonomy': row['autonomy_json'] != null ? jsonDecode(row['autonomy_json'] as String) : null,
    };
  }

  Future<void> upsertContexteDeVie(String dossierId, String patientId, {MedicalContext? medicalContext, AutonomyData? autonomy}) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('contexte_de_vie', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'patient_local_id': patientId,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (medicalContext != null) data['medical_context_json'] = jsonEncode(medicalContext.toJson());
    if (autonomy != null) data['autonomy_json'] = jsonEncode(autonomy.toJson());
    if (existing.isEmpty) {
      data['local_id'] = 'ctx_${dossierId}_${_uuid()}';
      await db.insert('contexte_de_vie', data);
    } else {
      await db.update('contexte_de_vie', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }
  }

  Future<DiagnosticSanitaire?> fetchDiagnosticSanitaire(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query('diagnostic_sanitaires', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DiagnosticSanitaire(
      dossierId: dossierId,
      sdbInstances: row['sdb_instances_json'] != null
          ? (jsonDecode(row['sdb_instances_json'] as String) as List<dynamic>).map((e) => BathroomInstance.fromJson(e as Map<String, dynamic>)).toList()
          : [],
      wcInstances: row['wc_instances_json'] != null
          ? (jsonDecode(row['wc_instances_json'] as String) as List<dynamic>).map((e) => WcInstance.fromJson(e as Map<String, dynamic>)).toList()
          : [],
    );
  }

  Future<void> upsertDiagnosticSanitaire(String dossierId, DiagnosticSanitaire diag) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('diagnostic_sanitaires', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'sdb_instances_json': jsonEncode(diag.sdbInstances.map((e) => e.toJson()).toList()),
      'wc_instances_json': jsonEncode(diag.wcInstances.map((e) => e.toJson()).toList()),
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'diag_${dossierId}_${_uuid()}';
      await db.insert('diagnostic_sanitaires', data);
    } else {
      await db.update('diagnostic_sanitaires', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }
  }

  Future<MesuresAnthropometriques?> fetchMesures(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query('mesures_anthropometriques', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return MesuresAnthropometriques(
      dossierId: dossierId,
      deboutHauteurCoude: (row['debout_hauteur_coude'] as num?)?.toDouble(),
      assisHauteurAssise: (row['assis_hauteur_assise'] as num?)?.toDouble(),
      assisProfondeurGenoux: (row['assis_profondeur_genoux'] as num?)?.toDouble(),
      assisHauteurCoudes: (row['assis_hauteur_coudes'] as num?)?.toDouble(),
      observations: row['observations'] as String? ?? '',
    );
  }

  Future<void> upsertMesures(String dossierId, MesuresAnthropometriques mesures) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('mesures_anthropometriques', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'debout_hauteur_coude': mesures.deboutHauteurCoude,
      'assis_hauteur_assise': mesures.assisHauteurAssise,
      'assis_profondeur_genoux': mesures.assisProfondeurGenoux,
      'assis_hauteur_coudes': mesures.assisHauteurCoudes,
      'observations': mesures.observations,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'mes_${dossierId}_${_uuid()}';
      await db.insert('mesures_anthropometriques', data);
    } else {
      await db.update('mesures_anthropometriques', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }
  }

  Future<ObservationsSynthese?> fetchObservations(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query('observations_synthese', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ObservationsSynthese(
      dossierId: dossierId,
      observationEquipements: row['observation_equipements'] as String? ?? '',
      projetSouhaitUsage: row['projet_souhait_usage'] as String? ?? '',
      resumePreconisations: row['resume_preconisations'] as String? ?? '',
    );
  }

  Future<void> upsertObservations(String dossierId, ObservationsSynthese obs) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('observations_synthese', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'observation_equipements': obs.observationEquipements,
      'projet_souhait_usage': obs.projetSouhaitUsage,
      'resume_preconisations': obs.resumePreconisations,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'obs_${dossierId}_${_uuid()}';
      await db.insert('observations_synthese', data);
    } else {
      await db.update('observations_synthese', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }
  }

  Future<List<VisitRecommendationItem>> fetchVisitRecommendations(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query('visit_recommendations', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    if (rows.isEmpty) return [];
    final itemsJson = jsonDecode(rows.first['items_json'] as String) as List<dynamic>;
    return itemsJson.map((e) => VisitRecommendationItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveVisitRecommendations(String dossierId, List<VisitRecommendationItem> items) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('visit_recommendations', where: 'dossier_local_id = ?', whereArgs: [dossierId], limit: 1);
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'items_json': jsonEncode(items.map((e) => e.toJson()).toList()),
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'rec_${dossierId}_${_uuid()}';
      await db.insert('visit_recommendations', data);
    } else {
      await db.update('visit_recommendations', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }
  }
}
