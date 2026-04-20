import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'sync_engine.dart';

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

    SyncEngine().notify();

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

    SyncEngine().notify();
  }

  static String _generateLocalId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'local_$hex';
  }

  /// Fetches a single dossier by its local id, returning null if missing.
  /// Used by screens that want to re-read fresh patient/housing data after
  /// a save that happened in a child widget (e.g. the visit report tabs).
  Future<Dossier?> fetchDossierById(String dossierLocalId) async {
    final all = await fetchAllDossiers();
    for (final d in all) {
      if (d.id == dossierLocalId) return d;
    }
    return null;
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
        d.compte_anah AS dossier_compte_anah,
        d.nature_accompagnement AS dossier_nature_accompagnement,
        d.envoi_rapport AS dossier_envoi_rapport,
        d.personnes_presentes_visite AS dossier_personnes_presentes,
        p.local_id AS patient_local_id,
        p.remote_patient_id AS patient_remote_id,
        p.first_name AS patient_first_name,
        p.last_name AS patient_last_name,
        p.second_first_name AS patient_second_first_name,
        p.second_last_name AS patient_second_last_name,
        p.birth_date AS patient_birth_date,
        p.phone AS patient_phone,
        p.email AS patient_email,
        p.address AS patient_address,
        p.city AS patient_city,
        p.city_id AS patient_city_id,
        p.zip_code AS patient_zip_code,
        p.family_situation AS patient_family_situation,
        p.income_category AS patient_income_category,
        p.number_people AS patient_number_people,
        p.fiscal_revenue AS patient_fiscal_revenue,
        p.occupants_json AS patient_occupants_json,
        p.apa AS patient_apa,
        p.invalidity AS patient_invalidity,
        p.invalidity_txt AS patient_invalidity_txt,
        p.home_help AS patient_home_help,
        p.home_help_txt AS patient_home_help_txt,
        p.dependence_txt AS patient_dependence_txt,
        p.caisse_retraite_principale AS patient_caisse_retraite_principale,
        p.caisses_retraite_complementaires AS patient_caisses_retraite_complementaires,
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
          // Preserve numberPeople across the pull → merge → UI round-trip.
          // Without this, ConflictAlgorithm.replace would reset the column
          // to NULL on every remote refresh, making the dropdown fall back
          // to "1 occupant" after a restart even when the server still has
          // the correct value.
          'number_people': dossier.patient.numberPeople,
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

  /// Alias kept for the dossier screen's in-place edits. Forwards to
  /// [updatePatient] so we get the same local write + sync-queue behaviour.
  Future<void> updatePatientFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) =>
      updatePatient(patientLocalId, fields);

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
    final now = DateTime.now().toIso8601String();
    final localFields = Map<String, dynamic>.from(fields);
    localFields['updated_at'] = now;
    localFields['sync_state'] = SyncState.pendingSync.name;
    await db.update(
      'dossiers',
      localFields,
      where: 'local_id = ?',
      whereArgs: [dossierLocalId],
    );

    final apiUpdates = _mapDossierFieldsToApi(fields);
    if (apiUpdates.isEmpty) return;
    await _enqueueEntityUpdate(
      db,
      entityType: 'dossier',
      entityLocalId: dossierLocalId,
      payloadKey: 'dossierId',
      updates: apiUpdates,
      now: now,
    );
    SyncEngine().notify();
  }

  static Map<String, dynamic> _mapDossierFieldsToApi(
      Map<String, dynamic> fields) {
    const snakeToCamel = <String, String>{
      'compte_anah': 'compteAnah',
      'nature_accompagnement': 'natureAccompagnement',
      'envoi_rapport': 'envoiRapport',
      'personnes_presentes_visite': 'personnesPresentesVisite',
      'ergo_id': 'ergoId',
      'visit_date': 'visitDate',
      'status': 'status',
    };
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;
      if (snakeToCamel.containsKey(key)) {
        out[snakeToCamel[key]!] = value;
      } else {
        out[key] = value;
      }
    });
    return out;
  }

  Future<void> _enqueueEntityUpdate(
    Database db, {
    required String entityType,
    required String entityLocalId,
    required String payloadKey,
    required Map<String, dynamic> updates,
    required String now,
  }) async {
    final opId = '${entityType}_update_$entityLocalId';
    final existing = await db.query('sync_operations',
        where: 'id = ?', whereArgs: [opId], limit: 1);
    Map<String, dynamic> merged = updates;
    if (existing.isNotEmpty) {
      try {
        final prev = jsonDecode(existing.first['payload_json'] as String)
            as Map<String, dynamic>;
        final prevUpdates =
            (prev['updates'] as Map?)?.cast<String, dynamic>();
        if (prevUpdates != null) merged = {...prevUpdates, ...updates};
      } catch (_) {}
    }
    final payloadMap = <String, dynamic>{
      payloadKey: entityLocalId,
      'updates': merged,
    };
    // Also add a generic local-id key so the housing processor can find
    // the source dossier id (the housing sync needs to resolve the
    // beneficiary from the dossier).
    if (entityType == 'housing') {
      payloadMap['dossierLocalId'] = entityLocalId;
    }
    await db.insert(
      'sync_operations',
      {
        'id': opId,
        'entity_type': entityType,
        'entity_local_id': entityLocalId,
        'operation_type': 'update',
        'payload_json': jsonEncode(payloadMap),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
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

    // Parse the occupants JSON blob (written by the visit report whenever
    // a per-occupant field is edited). Empty list means "no extra occupant
    // data yet" — the visit report will fall back to derive a single
    // occupant from the top-level patient fields.
    final occupantsRaw =
        row['patient_occupants_json'] as String? ?? '';
    List<Occupant> occupants = const [];
    if (occupantsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(occupantsRaw);
        if (decoded is List) {
          occupants = decoded
              .whereType<Map>()
              .map((e) => Occupant.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      } catch (_) {
        // Ignore invalid JSON — fall back to empty list.
      }
    }

    return Dossier(
      id: row['dossier_local_id'] as String,
      patient: Patient(
        id: row['patient_local_id'] as String,
        firstName: row['patient_first_name'] as String,
        lastName: row['patient_last_name'] as String,
        secondFirstName:
            row['patient_second_first_name'] as String? ?? '',
        secondLastName:
            row['patient_second_last_name'] as String? ?? '',
        birthDate: row['patient_birth_date'] as String,
        phone: row['patient_phone'] as String,
        email: row['patient_email'] as String,
        address: row['patient_address'] as String,
        city: row['patient_city'] as String,
        cityId: row['patient_city_id'] as String? ?? '',
        zipCode: row['patient_zip_code'] as String,
        familySituation: row['patient_family_situation'] as String,
        incomeCategory: row['patient_income_category'] as String,
        numberPeople: row['patient_number_people'] as int?,
        fiscalRevenue: (row['patient_fiscal_revenue'] as num?)?.toDouble(),
        occupants: occupants,
        apa: (row['patient_apa'] as int? ?? 0) == 1,
        invalidity: (row['patient_invalidity'] as int? ?? 0) == 1,
        invalidityTxt:
            row['patient_invalidity_txt'] as String? ?? '',
        homeHelp: (row['patient_home_help'] as int? ?? 0) == 1,
        homeHelpTxt:
            row['patient_home_help_txt'] as String? ?? '',
        dependenceTxt:
            row['patient_dependence_txt'] as String? ?? '',
        caisseRetraitePrincipale:
            row['patient_caisse_retraite_principale'] as String? ?? '',
        caissesRetraiteComplementaires:
            row['patient_caisses_retraite_complementaires'] as String? ?? '',
        trustedPerson: TrustedPerson(
          name: trustedPersonJson['name'] as String? ?? '',
          phone: trustedPersonJson['phone'] as String? ?? '',
          email: trustedPersonJson['email'] as String? ?? '',
        ),
      ),
      status: DossierStatus.values.byName(row['dossier_status'] as String),
      ergoId: row['dossier_ergo_id'] as String,
      visitDate: row['dossier_visit_date'] as String?,
      compteAnah: row['dossier_compte_anah'] as String? ?? '',
      natureAccompagnement:
          row['dossier_nature_accompagnement'] as String? ?? '',
      envoiRapport: row['dossier_envoi_rapport'] as String? ?? '',
      personnesPresentesVisite:
          row['dossier_personnes_presentes'] as String? ?? '',
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

  /// Updates a patient's fields both locally AND enqueues a remote sync
  /// operation so NocoDB receives the change when the device is online.
  ///
  /// [fields] can mix SQL column names (snake_case like `first_name`,
  /// `trusted_person_json`) — they are translated to the API's camelCase
  /// payload keys (`firstName`, `trustedPerson: {…}`, …) before being
  /// enqueued. Unknown snake_case keys are passed through as-is.
  Future<void> updatePatient(
      String patientId, Map<String, dynamic> fields) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final localFields = Map<String, dynamic>.from(fields);
    localFields['updated_at'] = now;
    localFields['sync_state'] = SyncState.pendingSync.name;
    await db.update('patients', localFields,
        where: 'local_id = ?', whereArgs: [patientId]);

    // Translate to API-friendly payload and enqueue a sync op. We merge with
    // any existing pending op so rapid edits collapse into a single push.
    final apiUpdates = _mapPatientFieldsToApi(fields);
    if (apiUpdates.isEmpty) return;

    final opId = 'patient_update_$patientId';
    final existing = await db.query('sync_operations',
        where: 'id = ?', whereArgs: [opId], limit: 1);
    Map<String, dynamic> mergedUpdates = apiUpdates;
    if (existing.isNotEmpty) {
      try {
        final prev = jsonDecode(existing.first['payload_json'] as String)
            as Map<String, dynamic>;
        final prevUpdates = (prev['updates'] as Map?)?.cast<String, dynamic>();
        if (prevUpdates != null) {
          mergedUpdates = {...prevUpdates, ...apiUpdates};
        }
      } catch (_) {
        // Fall back to the new payload only.
      }
    }

    await db.insert(
      'sync_operations',
      {
        'id': opId,
        'entity_type': 'patient',
        'entity_local_id': patientId,
        'operation_type': 'update',
        'payload_json': jsonEncode({
          'patientLocalId': patientId,
          'updates': mergedUpdates,
        }),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    SyncEngine().notify();
  }

  /// Maps SQL column names (snake_case) used by the visit-report tabs to
  /// the camelCase keys expected by the Express API. Also decodes JSON
  /// blobs (trusted_person_json, occupants_json) into nested structures.
  static Map<String, dynamic> _mapPatientFieldsToApi(
      Map<String, dynamic> fields) {
    const snakeToCamel = <String, String>{
      'first_name': 'firstName',
      'last_name': 'lastName',
      'second_first_name': 'secondFirstName',
      'second_last_name': 'secondLastName',
      'birth_date': 'occupant1BirthDate',
      'phone': 'phone',
      'email': 'email',
      'address': 'address',
      'city': 'city',
      'city_id': 'cityId',
      'zip_code': 'zipCode',
      'family_situation': 'familySituation',
      'income_category': 'incomeCategory',
      'fiscal_revenue': 'fiscalRevenue',
      'number_people': 'numberPeople',
      'invalidity_txt': 'invalidityTxt',
      'home_help_txt': 'homeHelpTxt',
      'dependence_txt': 'dependenceTxt',
      'caisse_retraite_principale': 'caisseRetraitePrincipale',
      'caisses_retraite_complementaires': 'caissesRetraiteComplementaires',
    };
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;
      if (snakeToCamel.containsKey(key)) {
        out[snakeToCamel[key]!] = value;
        return;
      }
      // Booleans stored as 0/1 in SQLite — decode back to bool for the API.
      if (key == 'apa' || key == 'invalidity' || key == 'home_help') {
        final camel = {
          'apa': 'apa',
          'invalidity': 'invalidity',
          'home_help': 'homeHelp',
        }[key]!;
        out[camel] = value == 1 || value == true;
        return;
      }
      if (key == 'trusted_person_json' && value is String && value.isNotEmpty) {
        try {
          out['trustedPerson'] = jsonDecode(value);
        } catch (_) {}
        return;
      }
      if (key == 'occupants_json' && value is String && value.isNotEmpty) {
        try {
          out['occupants'] = jsonDecode(value);
        } catch (_) {}
        return;
      }
      // Pass-through (rare): already camelCase or unknown.
      out[key] = value;
    });
    return out;
  }

  /// Loads the raw housing row (all columns) for a given dossier id. Used by
  /// the accessibility tab to access per-level rooms (stored as JSON),
  /// second/third-floor flags and all extended fields that aren't exposed
  /// on the [Housing] model.
  Future<Map<String, dynamic>?> fetchHousingRaw(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'dossiers',
      columns: ['housing_local_id'],
      where: 'local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final housingId = rows.first['housing_local_id'] as String;
    final housing = await db.query(
      'housings',
      where: 'local_id = ?',
      whereArgs: [housingId],
      limit: 1,
    );
    if (housing.isEmpty) return null;
    return Map<String, dynamic>.from(housing.first);
  }

  Future<void> updateHousing(
      String dossierId, Map<String, dynamic> fields) async {
    final db = await _database.database;
    final rows = await db.query('dossiers',
        columns: ['housing_local_id'],
        where: 'local_id = ?',
        whereArgs: [dossierId],
        limit: 1);
    if (rows.isEmpty) return;
    final housingId = rows.first['housing_local_id'] as String;
    final now = DateTime.now().toIso8601String();
    final localFields = Map<String, dynamic>.from(fields);
    localFields['updated_at'] = now;
    localFields['sync_state'] = SyncState.pendingSync.name;
    await db.update('housings', localFields,
        where: 'local_id = ?', whereArgs: [housingId]);

    final apiUpdates = _mapHousingFieldsToApi(fields);
    if (apiUpdates.isEmpty) return;
    await _enqueueEntityUpdate(
      db,
      entityType: 'housing',
      entityLocalId: dossierId,
      payloadKey: 'dossierLocalId',
      updates: apiUpdates,
      now: now,
    );
    SyncEngine().notify();
  }

  static Map<String, dynamic> _mapHousingFieldsToApi(
      Map<String, dynamic> fields) {
    // The /api/logements endpoint accepts snake_case / French keys directly
    // (see server mapHousingUpdatesToFields). We pass through most keys and
    // just convert a few known camelCase-only fields.
    const snakeToCamel = <String, String>{
      'year_construction': 'yearConstruction',
      'year_habitation': 'yearHabitation',
      'surface': 'surface',
      'levels': 'levels',
      'typology': 'typology',
      'easy_access': 'easyAccess',
      'access_observation': 'accessObservation',
      'motorisation_porte_garage': 'motorisationPorteGarage',
      'motorisation_portail': 'motorisationPortail',
    };
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;
      if (snakeToCamel.containsKey(key)) {
        out[snakeToCamel[key]!] = value is int && (key == 'easy_access')
            ? value == 1
            : value;
      } else {
        // Pass boolean-ish integer columns as bool where obvious.
        if (value is int && (value == 0 || value == 1)) {
          out[key] = value == 1;
        } else {
          out[key] = value;
        }
      }
    });
    return out;
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
