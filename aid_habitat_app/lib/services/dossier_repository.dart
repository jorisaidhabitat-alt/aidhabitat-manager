import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class DossierRepository {
  DossierRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<void> initialize() async {
    await _database.ensureSeeded();
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
}
