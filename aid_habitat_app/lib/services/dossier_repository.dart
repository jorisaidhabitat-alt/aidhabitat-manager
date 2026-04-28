import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'nocodb_api_client.dart';
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
        'occupation_status': '',
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
        p.occupation_status AS patient_occupation_status,
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
        h.accessibility_notes AS housing_accessibility_notes,
        h.year_construction AS housing_year_construction,
        h.year_habitation AS housing_year_habitation,
        h.levels AS housing_levels,
        h.typology AS housing_typology,
        h.basement AS housing_basement,
        h.basement_desc AS housing_basement_desc,
        h.basement_rooms_json AS housing_basement_rooms,
        h.rdc AS housing_rdc,
        h.rdc_desc AS housing_rdc_desc,
        h.rdc_rooms_json AS housing_rdc_rooms,
        h.floor AS housing_floor,
        h.floor_desc AS housing_floor_desc,
        h.floor_rooms_json AS housing_floor_rooms,
        h.second_floor AS housing_second_floor,
        h.second_floor_desc AS housing_second_floor_desc,
        h.second_floor_rooms_json AS housing_second_floor_rooms,
        h.third_floor AS housing_third_floor,
        h.third_floor_desc AS housing_third_floor_desc,
        h.third_floor_rooms_json AS housing_third_floor_rooms,
        h.garage AS housing_garage,
        h.veranda AS housing_veranda,
        h.balcon AS housing_balcon,
        h.terrasse AS housing_terrasse,
        h.jardin AS housing_jardin,
        h.heating_details_json AS housing_heating_details,
        h.volets_roulants_manuels_localisation AS housing_volets_man_loc,
        h.volets_roulants_manuels_entier AS housing_volets_man_entier,
        h.volets_roulants_electriques_localisation AS housing_volets_elec_loc,
        h.volets_roulants_electriques_entier AS housing_volets_elec_entier,
        h.volets_persiennes_localisation AS housing_volets_pers_loc,
        h.volets_persiennes_entier AS housing_volets_pers_entier,
        h.porte_garage_id AS housing_porte_garage_id,
        h.portail_id AS housing_portail_id,
        h.motorisation_porte_garage AS housing_motorisation_porte_garage,
        h.motorisation_portail AS housing_motorisation_portail,
        h.easy_access AS housing_easy_access,
        h.comments AS housing_comments,
        h.access_observation AS housing_access_observation
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
          'occupation_status': dossier.patient.occupationStatus,
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

  /// Merge raw dossier payloads (as returned by `/api/dossiers`) into the
  /// local SQLite store. Unlike [mergeRemoteDossiers] this path has access
  /// to the full JSON sent by the server and can therefore persist ALL
  /// extended columns (number_people, fiscal_revenue, apa, invalidity,
  /// occupants_json, heating_details_json, per-floor rooms, cheminement_*,
  /// medical_context_json, autonomy_json, etc.).
  ///
  /// UPDATE is used when the row already exists in the `synced` state, so
  /// columns the server doesn't return (e.g. local-only flags) are NOT
  /// wiped. INSERT-or-replace is used only for rows that don't exist yet.
  /// Rows with pending local mutations (sync_state != synced) are skipped,
  /// exactly like the legacy path.
  Future<void> mergeRemoteDossierPayloads(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return;
    final db = await _database.database;

    // Sets canoniques d'IDs remote — utilisés à la fin de la transaction
    // pour réconcilier les suppressions côté NocoDB (toute ligne
    // `synced` localement qui n'apparaît plus dans la liste remote a
    // été supprimée sur le serveur → on la purge en local).
    final remoteDossierIds = <String>{};
    final remotePatientIds = <String>{};
    final remoteHousingIds = <String>{};

    await db.transaction((txn) async {
      for (final raw in payloads) {
        final dossierId = raw['id']?.toString() ?? '';
        if (dossierId.isEmpty) continue;
        remoteDossierIds.add(dossierId);
        final pJson = (raw['patient'] as Map?)?.cast<String, dynamic>();
        final pid = pJson?['id']?.toString() ?? dossierId;
        remotePatientIds.add(pid);
        remoteHousingIds.add('housing_$dossierId');

        final existingDossier = await txn.query(
          'dossiers',
          columns: ['sync_state', 'patient_local_id', 'housing_local_id'],
          where: 'local_id = ?',
          whereArgs: [dossierId],
          limit: 1,
        );

        final existingSyncState = existingDossier.isEmpty
            ? SyncState.synced
            : SyncState.values.byName(
                existingDossier.first['sync_state'] as String,
              );

        if (existingDossier.isNotEmpty &&
            existingSyncState != SyncState.synced) {
          // User has unsync'd local edits — do not overwrite them.
          continue;
        }

        // Garde de second niveau : on regarde aussi le `patients.sync_state`
        // ET le `housings.sync_state` du dossier. Avant cette garde, un
        // pull NocoDB pouvait écraser un patient ou un housing en cours
        // de push, parce que `dossiers.sync_state` était à `synced` mais
        // `patients.sync_state` était à `pendingSync`. Symptôme côté UI :
        // « le nom modifié disparaît pendant quelques secondes » — le
        // serveur renvoyait l'ancien nom (eventual consistency) et le
        // merge l'écrivait par-dessus le nouveau nom local.
        if (existingDossier.isNotEmpty) {
          final patientLocalIdExisting =
              existingDossier.first['patient_local_id'] as String?;
          final housingLocalIdExisting =
              existingDossier.first['housing_local_id'] as String?;
          if (patientLocalIdExisting != null &&
              patientLocalIdExisting.isNotEmpty) {
            final pRows = await txn.query(
              'patients',
              columns: ['sync_state'],
              where: 'local_id = ?',
              whereArgs: [patientLocalIdExisting],
              limit: 1,
            );
            if (pRows.isNotEmpty) {
              final pState = pRows.first['sync_state'] as String?;
              if (pState != null && pState != SyncState.synced.name) {
                continue;
              }
            }
          }
          if (housingLocalIdExisting != null &&
              housingLocalIdExisting.isNotEmpty) {
            final hRows = await txn.query(
              'housings',
              columns: ['sync_state'],
              where: 'local_id = ?',
              whereArgs: [housingLocalIdExisting],
              limit: 1,
            );
            if (hRows.isNotEmpty) {
              final hState = hRows.first['sync_state'] as String?;
              if (hState != null && hState != SyncState.synced.name) {
                continue;
              }
            }
          }
        }

        final now = DateTime.now().toIso8601String();
        final patientJson =
            (raw['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
        final housingJson =
            (raw['housing'] as Map?)?.cast<String, dynamic>() ?? const {};

        final patientLocalId = patientJson['id']?.toString() ?? dossierId;
        final housingLocalId = existingDossier.isEmpty
            ? 'housing_$dossierId'
            : existingDossier.first['housing_local_id'] as String;

        // ------------------------------------------------------------------
        // Patient upsert
        // ------------------------------------------------------------------
        final patientData = _buildPatientPayload(raw: patientJson, now: now);
        patientData['local_id'] = patientLocalId;
        patientData['remote_patient_id'] = patientLocalId;
        await _upsertByLocalId(
          txn: txn,
          table: 'patients',
          localId: patientLocalId,
          data: patientData,
        );

        // ------------------------------------------------------------------
        // Housing upsert
        // ------------------------------------------------------------------
        final housingData = _buildHousingPayload(raw: housingJson, now: now);
        housingData['local_id'] = housingLocalId;
        housingData['remote_housing_id'] = housingLocalId;
        housingData['patient_local_id'] = patientLocalId;
        await _upsertByLocalId(
          txn: txn,
          table: 'housings',
          localId: housingLocalId,
          data: housingData,
        );

        // ------------------------------------------------------------------
        // Dossier upsert
        // ------------------------------------------------------------------
        final dossierData = _buildDossierPayload(raw: raw, now: now);
        dossierData['local_id'] = dossierId;
        dossierData['remote_dossier_id'] = dossierId;
        dossierData['patient_local_id'] = patientLocalId;
        dossierData['housing_local_id'] = housingLocalId;
        dossierData['plans_json'] = jsonEncode(const ['PF1', 'PF2', 'PF3']);
        dossierData['created_at'] =
            raw['createdAt']?.toString() ?? now;
        await _upsertByLocalId(
          txn: txn,
          table: 'dossiers',
          localId: dossierId,
          data: dossierData,
        );
      }

      // ----------------------------------------------------------------
      // Réconciliation des suppressions remote (chantier sync #1).
      //
      // Pour chaque table dont la liste remote vient d'être pullée
      // intégralement, on supprime toute ligne localement `synced`
      // dont l'identifiant n'apparaît plus dans la liste remote.
      // Les drafts locaux (sync_state != synced) sont préservés.
      //
      // Garde-fou : le payload remote est non-vide (vérifié au-dessus
      // dans `refreshWorkspaceFromRemote`) — donc une réponse API
      // vide ne déclenche jamais de purge de masse.
      // ----------------------------------------------------------------
      await _reconcileDeletions(
        txn: txn,
        table: 'dossiers',
        idColumn: 'local_id',
        remoteIds: remoteDossierIds,
      );
      await _reconcileDeletions(
        txn: txn,
        table: 'housings',
        idColumn: 'local_id',
        remoteIds: remoteHousingIds,
      );
      await _reconcileDeletions(
        txn: txn,
        table: 'patients',
        idColumn: 'local_id',
        remoteIds: remotePatientIds,
      );
      // Cascade applicative : nettoyage des rows liées aux dossiers
      // disparus (FK SQLite non garantie selon le schéma). On scope à
      // ce qui devient orphelin (parent_local_id absent du remote).
      await _purgeOrphansByParent(
        txn: txn,
        table: 'visit_recommendations',
        parentColumn: 'dossier_local_id',
        validParentIds: remoteDossierIds,
      );
      await _purgeOrphansByParent(
        txn: txn,
        table: 'documents',
        parentColumn: 'patient_local_id',
        validParentIds: remotePatientIds,
      );
    });
  }

  /// Supprime de [table] toutes les lignes en état `synced` dont
  /// l'identifiant ([idColumn]) n'apparaît plus dans [remoteIds].
  /// Les lignes en `pendingSync` ou `localOnly` (drafts) sont
  /// préservées : elles seront pushées au prochain cycle, et c'est le
  /// serveur qui décidera (création nouvelle, ou rejet 4xx → conflit).
  ///
  /// Si [remoteIds] est vide, on ne supprime rien (le caller doit
  /// avoir déjà filtré ce cas — éviter une purge totale en cas
  /// d'erreur silencieuse côté API).
  Future<int> _reconcileDeletions({
    required Transaction txn,
    required String table,
    required String idColumn,
    required Set<String> remoteIds,
  }) async {
    if (remoteIds.isEmpty) return 0;
    final placeholders = List.filled(remoteIds.length, '?').join(',');
    final args = <Object?>[
      SyncState.synced.name,
      ...remoteIds,
    ];
    final deleted = await txn.delete(
      table,
      where: 'sync_state = ? AND $idColumn NOT IN ($placeholders)',
      whereArgs: args,
    );
    if (deleted > 0) {
      // ignore: avoid_print
      print(
        '[reconcile] $table : $deleted ligne(s) purgée(s) (suppression remote)',
      );
    }
    return deleted;
  }

  /// Supprime les lignes orphelines : celles dont la colonne
  /// [parentColumn] référence un parent qui n'est plus dans
  /// [validParentIds]. Toujours scopé aux rows `synced` pour ne pas
  /// jeter un draft local en attente de push.
  Future<int> _purgeOrphansByParent({
    required Transaction txn,
    required String table,
    required String parentColumn,
    required Set<String> validParentIds,
  }) async {
    if (validParentIds.isEmpty) return 0;
    final placeholders = List.filled(validParentIds.length, '?').join(',');
    final args = <Object?>[
      SyncState.synced.name,
      ...validParentIds,
    ];
    final deleted = await txn.delete(
      table,
      where:
          'sync_state = ? AND $parentColumn NOT IN ($placeholders)',
      whereArgs: args,
    );
    if (deleted > 0) {
      // ignore: avoid_print
      print(
        '[reconcile] $table : $deleted orphelin(s) purgé(s) (parent disparu)',
      );
    }
    return deleted;
  }

  /// Insert or UPDATE a row identified by `local_id`. If a row exists, the
  /// provided [data] is merged via UPDATE so columns not included in [data]
  /// keep their current values (important for local-only flags that the
  /// server doesn't return). Otherwise a fresh INSERT is performed.
  Future<void> _upsertByLocalId({
    required Transaction txn,
    required String table,
    required String localId,
    required Map<String, dynamic> data,
  }) async {
    final existing = await txn.query(
      table,
      columns: ['local_id'],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (existing.isEmpty) {
      await txn.insert(table, data,
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      // `local_id` is the primary key — don't update it.
      final updateFields = Map<String, dynamic>.from(data)
        ..remove('local_id');
      await txn.update(
        table,
        updateFields,
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    }
  }

  /// Maps a server-returned patient JSON to a SQLite row map covering the
  /// patients table's persisted columns. Values missing from [raw] fall
  /// back to safe defaults.
  Map<String, dynamic> _buildPatientPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    final trusted = (raw['trustedPerson'] as Map?)?.cast<String, dynamic>() ??
        const {};
    return {
      'first_name': raw['firstName']?.toString() ?? '',
      'last_name': raw['lastName']?.toString() ?? '',
      'second_first_name': raw['secondFirstName']?.toString() ?? '',
      'second_last_name': raw['secondLastName']?.toString() ?? '',
      'birth_date': raw['birthDate']?.toString() ?? '',
      'phone': raw['phone']?.toString() ?? '',
      'email': raw['email']?.toString() ?? '',
      'address': raw['address']?.toString() ?? '',
      'city': raw['city']?.toString() ?? '',
      'city_id': raw['cityId']?.toString() ?? '',
      'zip_code': raw['zipCode']?.toString() ?? '',
      'family_situation': raw['familySituation']?.toString() ?? '',
      'occupation_status': raw['occupationStatus']?.toString() ?? '',
      'income_category': raw['incomeCategory']?.toString() ?? '',
      'number_people': _asInt(raw['numberPeople']),
      'fiscal_revenue': _asDouble(raw['fiscalRevenue']),
      'occupants_json': raw['occupants'] is List
          ? jsonEncode(raw['occupants'])
          : null,
      'apa': _asBoolInt(raw['apa']),
      'invalidity': _asBoolInt(raw['invalidity']),
      'invalidity_txt': raw['invalidityTxt']?.toString() ?? '',
      'home_help': _asBoolInt(raw['homeHelp']),
      'home_help_txt': raw['homeHelpTxt']?.toString() ?? '',
      'dependence_txt': raw['dependenceTxt']?.toString() ?? '',
      'caisse_retraite_principale':
          raw['caisseRetraitePrincipale']?.toString() ?? '',
      'caisses_retraite_complementaires':
          raw['caissesRetraiteComplementaires']?.toString() ?? '',
      'trusted_person_json': jsonEncode({
        'name': trusted['name']?.toString() ?? '',
        'phone': trusted['phone']?.toString() ?? '',
        'email': trusted['email']?.toString() ?? '',
      }),
      'updated_at': now,
      // Voir _buildDossierPayload : on stocke l'updatedAt serveur, pas
      // l'horodatage local du merge.
      'remote_updated_at': _extractRemoteUpdatedAt(raw) ?? now,
      'sync_state': SyncState.synced.name,
    };
  }

  /// Maps a server-returned housing JSON to a SQLite row map covering every
  /// column persisted in the `housings` table, including the ones that are
  /// otherwise orphaned (no matching Dart model field): cheminement_*,
  /// heating_details_json, *_rooms_json, volets_*, etc.
  Map<String, dynamic> _buildHousingPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    // React/server heating shape: { electric, gas, oil, heatPump, collective,
    // wood, pellet, other }. Normalize to our Flutter label keys for storage
    // (matching what accessibility_tab writes locally).
    Map<String, dynamic> heatingDetailsJson = const {};
    final heating = raw['heatingDetails'];
    if (heating is Map) {
      heatingDetailsJson = {
        'Électrique': heating['electric'] == true,
        'Gaz': heating['gas'] == true,
        'Fioul': heating['oil'] == true,
        'Pompe à chaleur': heating['heatPump'] == true,
        'Bois': heating['wood'] == true,
        'Granulés': heating['pellet'] == true,
        'Collectif': heating['collective'] == true,
        'Autre': heating['other'] == true,
      };
    }

    // Primary heating mode (enum — guessed from the first true detail).
    final heatingMode = heatingDetailsJson['Électrique'] == true
        ? HeatingMode.ELECTRIC.name
        : heatingDetailsJson['Gaz'] == true
            ? HeatingMode.GAS.name
            : heatingDetailsJson['Bois'] == true ||
                    heatingDetailsJson['Granulés'] == true
                ? HeatingMode.WOOD.name
                : heatingDetailsJson['Fioul'] == true
                    ? HeatingMode.OIL.name
                    : HeatingMode.OTHER.name;

    return {
      'type': _asHousingTypeName(raw['typology']),
      'year_value': _asInt(raw['yearConstruction']),
      'surface': _asDouble(raw['surface']),
      'heating_mode': heatingMode,
      'accessibility_notes':
          raw['accessibilityNotes']?.toString() ??
              raw['accessObservation']?.toString() ??
              '',
      'year_construction': raw['yearConstruction']?.toString() ?? '',
      'year_habitation': raw['yearHabitation']?.toString() ?? '',
      'levels': _asInt(raw['levels']),
      'typology': raw['typology']?.toString() ?? 'Maison',
      'basement': _asBoolInt(raw['basement']),
      'basement_desc': raw['basementDesc']?.toString() ?? '',
      'rdc': _asBoolInt(raw['rdc']),
      'rdc_desc': raw['rdcDesc']?.toString() ?? '',
      'floor': _asBoolInt(raw['floor']),
      'floor_desc': raw['floorDesc']?.toString() ?? '',
      'garage': _asBoolInt(raw['garage']),
      'veranda': _asBoolInt(raw['veranda']),
      'balcon': _asBoolInt(raw['balcon']),
      'terrasse': _asBoolInt(raw['terrasse']),
      'jardin': _asBoolInt(raw['jardin']),
      'heating_details_json': jsonEncode(heatingDetailsJson),
      'volets_roulants_manuels_localisation':
          raw['voletsRoulantsManuelsLocalisation']?.toString() ?? '',
      'volets_roulants_manuels_entier':
          _asBoolInt(raw['voletsRoulantsManuelsEntier']),
      'volets_roulants_electriques_localisation':
          raw['voletsRoulantsElectriquesLocalisation']?.toString() ?? '',
      'volets_roulants_electriques_entier':
          _asBoolInt(raw['voletsRoulantsElectriquesEntier']),
      'volets_persiennes_localisation':
          raw['voletsPersiennesLocalisation']?.toString() ?? '',
      'volets_persiennes_entier':
          _asBoolInt(raw['voletsPersiennesEntier']),
      'cheminement_escalier_exterieur':
          _asBoolInt(raw['cheminementEscalierExterieur']),
      'cheminement_escalier_interieur':
          _asBoolInt(raw['cheminementEscalierInterieur']),
      'cheminement_pente_douce': _asBoolInt(raw['cheminementPenteDouce']),
      'cheminement_plat': _asBoolInt(raw['cheminementPlat']),
      'cheminement_quelques_marches':
          _asBoolInt(raw['cheminementQuelquesMarches']),
      'cheminement_par_arriere': _asBoolInt(raw['cheminementParArriere']),
      'cheminement_seuil_porte': _asBoolInt(raw['cheminementSeuilPorte']),
      'porte_garage_id': raw['porteGarageId']?.toString() ?? '',
      'portail_id': raw['portailId']?.toString() ?? '',
      'motorisation_porte_garage':
          raw['motorisationPorteGarage']?.toString() ?? '',
      'motorisation_portail':
          raw['motorisationPortail']?.toString() ?? '',
      'easy_access': _asBoolInt(raw['easyAccess']),
      'comments': raw['comments']?.toString() ?? '',
      'access_observation': raw['accessObservation']?.toString() ?? '',
      'updated_at': now,
      // Voir _buildDossierPayload : on stocke l'updatedAt serveur, pas
      // l'horodatage local du merge (sert au check optimistic au push).
      'remote_updated_at': _extractRemoteUpdatedAt(raw) ?? now,
      'sync_state': SyncState.synced.name,
    };
  }

  /// Maps a server-returned dossier JSON to a SQLite row map for `dossiers`.
  Map<String, dynamic> _buildDossierPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    return {
      'status': _asDossierStatusName(raw['status']),
      'ergo_id': raw['ergoId']?.toString() ?? '',
      'visit_date': raw['visitDate']?.toString(),
      'autonomy_notes': raw['autonomyNotes']?.toString() ?? '',
      'compte_anah': raw['compteAnah']?.toString() ?? '',
      'nature_accompagnement':
          raw['natureAccompagnement']?.toString() ?? '',
      'envoi_rapport': raw['envoiRapport']?.toString() ?? '',
      'personnes_presentes_visite':
          raw['personnesPresentesVisite']?.toString() ?? '',
      'medical_context_json': raw['medicalContext'] is Map
          ? jsonEncode(raw['medicalContext'])
          : null,
      'autonomy_json':
          raw['autonomy'] is Map ? jsonEncode(raw['autonomy']) : null,
      'updated_at': now,
      // remote_updated_at = horodatage authoritatif du serveur (et non
      // l'heure locale du merge). Indispensable pour le contrôle
      // d'optimistic concurrency au push : le client renverra cette
      // valeur dans `expectedUpdatedAt` et le serveur (via
      // `sendConflictIfStale`) refusera l'update si quelqu'un d'autre a
      // modifié la ligne entre-temps.
      'remote_updated_at': _extractRemoteUpdatedAt(raw) ?? now,
      'sync_state': SyncState.synced.name,
    };
  }

  /// Lit le timestamp authoritatif renvoyé par NocoDB pour une row.
  /// Tolère les différentes conventions de nommage rencontrées
  /// (`updatedAt`, `updated_at`, `UpdatedAt`, fallback sur la date de
  /// création quand la row n'a jamais été modifiée).
  String? _extractRemoteUpdatedAt(Map<String, dynamic> raw) {
    for (final key in const [
      'updatedAt',
      'updated_at',
      'UpdatedAt',
      'createdAt',
      'created_at',
      'CreatedAt',
    ]) {
      final v = raw[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString();
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Parse helpers (shared by the *Payload builders above)
  // ---------------------------------------------------------------------------

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  /// Converts various truthy values (bool, 0/1, "true"/"oui") into SQLite
  /// 0/1 — matching the app's convention for storing booleans.
  int _asBoolInt(dynamic v) {
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v != 0 ? 1 : 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return (s == 'true' || s == '1' || s == 'oui' || s == 'yes') ? 1 : 0;
    }
    return 0;
  }

  String _asHousingTypeName(dynamic typology) {
    final label = typology?.toString().trim() ?? '';
    return label == 'Appartement'
        ? HousingType.APARTMENT.name
        : HousingType.HOUSE.name;
  }

  String _asDossierStatusName(dynamic status) {
    switch (status?.toString()) {
      case 'Validé':
        return DossierStatus.GRANT_VALIDATED.name;
      case 'En cours':
        return DossierStatus.IN_PROGRESS.name;
      case 'Clos':
        return DossierStatus.CLOSED.name;
      case 'À visiter':
      default:
        return DossierStatus.TO_VISIT.name;
    }
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
        'occupation_status': remote.patient.occupationStatus,
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
    // Filtre sur `pending` uniquement (cf. `updatePatient`) : on évite
    // de merger une payload obsolète sur une op `running` ou `completed`.
    final existing = await db.query('sync_operations',
        where: 'id = ? AND status = ?',
        whereArgs: [opId, SyncOperationStatus.pending.name],
        limit: 1);
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
        occupationStatus:
            row['patient_occupation_status'] as String? ?? '',
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
        yearConstruction:
            row['housing_year_construction'] as String? ?? '',
        yearHabitation: row['housing_year_habitation'] as String? ?? '',
        levels: row['housing_levels'] as int?,
        typology: row['housing_typology'] as String? ?? 'Maison',
        basement: (row['housing_basement'] as int? ?? 0) == 1,
        basementDescription:
            row['housing_basement_desc'] as String? ?? '',
        basementRooms:
            _decodeRoomsJson(row['housing_basement_rooms'] as String?),
        rdc: (row['housing_rdc'] as int? ?? 0) == 1,
        rdcDescription: row['housing_rdc_desc'] as String? ?? '',
        rdcRooms: _decodeRoomsJson(row['housing_rdc_rooms'] as String?),
        floor: (row['housing_floor'] as int? ?? 0) == 1,
        floorDescription: row['housing_floor_desc'] as String? ?? '',
        floorRooms:
            _decodeRoomsJson(row['housing_floor_rooms'] as String?),
        secondFloor: (row['housing_second_floor'] as int? ?? 0) == 1,
        secondFloorDescription:
            row['housing_second_floor_desc'] as String? ?? '',
        secondFloorRooms: _decodeRoomsJson(
            row['housing_second_floor_rooms'] as String?),
        thirdFloor: (row['housing_third_floor'] as int? ?? 0) == 1,
        thirdFloorDescription:
            row['housing_third_floor_desc'] as String? ?? '',
        thirdFloorRooms:
            _decodeRoomsJson(row['housing_third_floor_rooms'] as String?),
        garage: (row['housing_garage'] as int? ?? 0) == 1,
        veranda: (row['housing_veranda'] as int? ?? 0) == 1,
        balcon: (row['housing_balcon'] as int? ?? 0) == 1,
        terrasse: (row['housing_terrasse'] as int? ?? 0) == 1,
        jardin: (row['housing_jardin'] as int? ?? 0) == 1,
        heatingDetails: _decodeHeatingDetails(
            row['housing_heating_details'] as String?),
        voletsRoulantsManuelsLocalisation:
            row['housing_volets_man_loc'] as String? ?? '',
        voletsRoulantsManuelsEntier:
            (row['housing_volets_man_entier'] as int? ?? 0) == 1,
        voletsRoulantsElectriquesLocalisation:
            row['housing_volets_elec_loc'] as String? ?? '',
        voletsRoulantsElectriquesEntier:
            (row['housing_volets_elec_entier'] as int? ?? 0) == 1,
        voletsPersiennesLocalisation:
            row['housing_volets_pers_loc'] as String? ?? '',
        voletsPersiennesEntier:
            (row['housing_volets_pers_entier'] as int? ?? 0) == 1,
        porteGarageId: row['housing_porte_garage_id'] as String? ?? '',
        portailId: row['housing_portail_id'] as String? ?? '',
        motorisationPorteGarage:
            row['housing_motorisation_porte_garage'] as String? ?? '',
        motorisationPortail:
            row['housing_motorisation_portail'] as String? ?? '',
        easyAccess: (row['housing_easy_access'] as int? ?? 0) == 1,
        comments: row['housing_comments'] as String? ?? '',
        accessObservation:
            row['housing_access_observation'] as String? ?? '',
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

  List<String> _decodeRoomsJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {/* fall through */}
    return const [];
  }

  Map<String, bool> _decodeHeatingDetails(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v == true));
      }
    } catch (_) {/* fall through */}
    return const {};
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
    // Ne merge qu'avec une op encore `pending`. Si l'op précédente est
    // déjà `running`/`completed`/`failed`/`conflict`, le sync engine a
    // pris le payload en mémoire et le pousse en parallèle — re-merger
    // par-dessus créerait une race où l'op courante envoie une payload
    // obsolète. En filtrant, on repart d'une payload propre pour la
    // prochaine op.
    final existing = await db.query('sync_operations',
        where: 'id = ? AND status = ?',
        whereArgs: [opId, SyncOperationStatus.pending.name],
        limit: 1);
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
      'occupation_status': 'occupationStatus',
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

    // Enqueue a sync operation so the medical context + autonomy reach
    // NocoDB. We route through the existing /api/dossiers/:id PATCH
    // endpoint which already knows how to persist medicalContext + autonomy
    // via upsertContexte server-side. Re-entrant updates on the same
    // dossier coalesce into a single op via ConflictAlgorithm.replace.
    final opUpdates = <String, dynamic>{};
    if (medicalContext != null) {
      opUpdates['medicalContext'] = medicalContext.toJson();
    }
    if (autonomy != null) {
      opUpdates['autonomy'] = autonomy.toJson();
    }
    if (opUpdates.isEmpty) return;

    final opId = 'contexte_update_$dossierId';
    final existingOp = await db.query('sync_operations',
        where: 'id = ?', whereArgs: [opId], limit: 1);
    Map<String, dynamic> merged = opUpdates;
    if (existingOp.isNotEmpty) {
      try {
        final prev = jsonDecode(existingOp.first['payload_json'] as String)
            as Map<String, dynamic>;
        final prevUpdates =
            (prev['updates'] as Map?)?.cast<String, dynamic>();
        if (prevUpdates != null) {
          merged = {...prevUpdates, ...opUpdates};
        }
      } catch (_) {/* fall through */}
    }
    await db.insert(
      'sync_operations',
      {
        'id': opId,
        'entity_type': 'contexte_de_vie',
        'entity_local_id': dossierId,
        'operation_type': 'update',
        'payload_json': jsonEncode({
          'dossierId': dossierId,
          'updates': merged,
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
    final sdbJson = diag.sdbInstances.map((e) => e.toJson()).toList();
    final wcJson = diag.wcInstances.map((e) => e.toJson()).toList();
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'sdb_instances_json': jsonEncode(sdbJson),
      'wc_instances_json': jsonEncode(wcJson),
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'diag_${dossierId}_${_uuid()}';
      await db.insert('diagnostic_sanitaires', data);
    } else {
      await db.update('diagnostic_sanitaires', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }

    // Enqueue push → PUT /api/diagnostic-sanitaires/:dossierId
    final opId = 'diag_update_$dossierId';
    await db.insert(
      'sync_operations',
      {
        'id': opId,
        'entity_type': 'diagnostic_sanitaires',
        'entity_local_id': dossierId,
        'operation_type': 'update',
        'payload_json': jsonEncode({
          'dossierId': dossierId,
          'sdbInstances': sdbJson,
          'wcInstances': wcJson,
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
    // EN LOCAL : on persiste TOUS les items (y compris ceux sans fiche
    // wiki liée) → une préconisation "vide" en cours de saisie n'est pas
    // perdue si l'app redémarre avant que l'utilisateur ait choisi
    // l'item bibliothèque.
    final itemsJson = items.map((e) => e.toJson()).toList();
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'items_json': jsonEncode(itemsJson),
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'rec_${dossierId}_${_uuid()}';
      await db.insert('visit_recommendations', data);
    } else {
      await db.update('visit_recommendations', data, where: 'dossier_local_id = ?', whereArgs: [dossierId]);
    }

    // VERS LE SERVEUR : on ne pousse que les items COMPLETS (wikiItemId
    // non vide). Le serveur refuse (400) toute préconisation non liée à
    // une fiche wiki. Si aucun item complet, on skip le sync_op.
    final syncItems = items
        .where((item) => item.wikiItemId.trim().isNotEmpty)
        .map((e) => e.toJson())
        .toList();

    // Enqueue push → PUT /api/visit-recommendations/:dossierId
    final opId = 'visitrec_update_$dossierId';
    if (syncItems.isNotEmpty || items.isEmpty) {
      // `items.isEmpty` = l'utilisateur a tout supprimé, on push la liste
      // vide pour que le serveur retire ses records. Sinon on attend
      // qu'au moins un item ait une fiche wiki liée.
      await db.insert(
        'sync_operations',
        {
          'id': opId,
          'entity_type': 'visit_recommendations',
          'entity_local_id': dossierId,
          'operation_type': 'update',
          'payload_json': jsonEncode({
            'dossierId': dossierId,
            'items': syncItems,
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
    } else {
      // Aucun item complet à pousser. Retire l'éventuelle sync_op
      // précédente (sinon elle ré-échouerait avec le même 400).
      await db.delete('sync_operations', where: 'id = ?', whereArgs: [opId]);
    }
  }

  /// Pulls the remote diagnostic sanitaires payload for [dossierId] and
  /// merges it into SQLite WITHOUT enqueuing a sync operation.
  ///
  /// Skips the merge if the local row is currently in `pendingSync` —
  /// that means the user has uncommitted local edits waiting to be
  /// pushed, and we don't want to clobber them with the server copy.
  Future<bool> refreshDiagnosticSanitaireFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final remote = await api.fetchDiagnosticSanitairePayload(dossierId);
    if (remote == null) return false;

    final db = await _database.database;
    final existing = await db.query(
      'diagnostic_sanitaires',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (existing.isNotEmpty &&
        existing.first['sync_state'] == SyncState.pendingSync.name) {
      return false;
    }

    final sdb = (remote['sdbInstances'] as List?) ?? const [];
    final wc = (remote['wcInstances'] as List?) ?? const [];
    final now = DateTime.now().toIso8601String();
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'sdb_instances_json': jsonEncode(sdb),
      'wc_instances_json': jsonEncode(wc),
      'updated_at': now,
      'sync_state': SyncState.synced.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'diag_${dossierId}_${_uuid()}';
      await db.insert('diagnostic_sanitaires', data);
    } else {
      await db.update(
        'diagnostic_sanitaires',
        data,
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
      );
    }
    return true;
  }

  /// Pulls the remote visit recommendations for [dossierId] and merges
  /// them into SQLite WITHOUT enqueuing a sync operation. Skips if the
  /// local row is in `pendingSync` (uncommitted local edits).
  Future<bool> refreshVisitRecommendationsFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final remoteItems = await api.fetchVisitRecommendationsPayload(dossierId);

    final db = await _database.database;
    final existing = await db.query(
      'visit_recommendations',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (existing.isNotEmpty &&
        existing.first['sync_state'] == SyncState.pendingSync.name) {
      return false;
    }

    // MERGE remote + drafts locaux (items sans wikiItemId, non pushés car
    // le serveur les refuse). Sans ce merge, un draft en cours de saisie
    // serait perdu au prochain refresh après le push des items complets.
    final List<Map<String, dynamic>> localDrafts = [];
    if (existing.isNotEmpty) {
      final raw = existing.first['items_json'] as String? ?? '[]';
      try {
        final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final item in decoded) {
          final wikiId = (item['wikiItemId'] as String?) ?? '';
          if (wikiId.trim().isEmpty) localDrafts.add(item);
        }
      } catch (_) {}
    }
    final merged = [...remoteItems, ...localDrafts];

    final now = DateTime.now().toIso8601String();
    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'items_json': jsonEncode(merged),
      'updated_at': now,
      // Si on a des drafts, on garde pendingSync pour que le prochain
      // refresh ne tente pas de les écraser. Sinon synced.
      'sync_state': localDrafts.isEmpty
          ? SyncState.synced.name
          : SyncState.pendingSync.name,
    };
    if (existing.isEmpty) {
      data['local_id'] = 'rec_${dossierId}_${_uuid()}';
      await db.insert('visit_recommendations', data);
    } else {
      await db.update(
        'visit_recommendations',
        data,
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
      );
    }
    return true;
  }
}
