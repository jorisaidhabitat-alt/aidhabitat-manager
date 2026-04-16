import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/mock_data.dart';
import '../models/types.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _dbName = 'aid_habitat_offline.db';
  static const _dbVersion = 5;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = await getDatabasesPath();
    _database = await openDatabase(
      p.join(dbPath, _dbName),
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _database!;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion == newVersion) return;
    if (oldVersion < 4) await _migrateV3ToV4(db);
    if (oldVersion < 5) await _migrateV4ToV5(db);
  }

  Future<void> _migrateV3ToV4(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wiki_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        image_url TEXT NOT NULL,
        tags_json TEXT NOT NULL,
        category TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _migrateV4ToV5(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS retirement_funds (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        audience TEXT NOT NULL,
        request_method TEXT NOT NULL,
        request_delay TEXT NOT NULL,
        aid_amount TEXT NOT NULL,
        therapist_note TEXT NOT NULL,
        website TEXT NOT NULL,
        logo_url TEXT NOT NULL,
        last_edited_at TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE app_users (
        local_id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        role TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        establishment_id TEXT,
        ergo_label TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        user_local_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE user_access_scopes (
        local_id TEXT PRIMARY KEY,
        user_local_id TEXT NOT NULL,
        scope_type TEXT NOT NULL,
        scope_value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE patients (
        local_id TEXT PRIMARY KEY,
        remote_patient_id TEXT,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL,
        birth_date TEXT NOT NULL,
        phone TEXT NOT NULL,
        email TEXT NOT NULL,
        address TEXT NOT NULL,
        city TEXT NOT NULL,
        zip_code TEXT NOT NULL,
        family_situation TEXT NOT NULL,
        income_category TEXT NOT NULL,
        trusted_person_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        remote_updated_at TEXT,
        sync_state TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE housings (
        local_id TEXT PRIMARY KEY,
        remote_housing_id TEXT,
        patient_local_id TEXT NOT NULL,
        type TEXT NOT NULL,
        year_value INTEGER,
        surface REAL,
        heating_mode TEXT NOT NULL,
        accessibility_notes TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        remote_updated_at TEXT,
        sync_state TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE dossiers (
        local_id TEXT PRIMARY KEY,
        remote_dossier_id TEXT,
        patient_local_id TEXT NOT NULL,
        housing_local_id TEXT NOT NULL,
        status TEXT NOT NULL,
        ergo_id TEXT NOT NULL,
        visit_date TEXT,
        autonomy_notes TEXT NOT NULL,
        plans_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        remote_updated_at TEXT,
        sync_state TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE documents (
        local_id TEXT PRIMARY KEY,
        patient_local_id TEXT NOT NULL,
        title TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_ext TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        local_file_path TEXT,
        remote_file_path TEXT,
        remote_public_url TEXT,
        tags_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL,
        pending_delete INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE note_pages (
        local_id TEXT PRIMARY KEY,
        patient_local_id TEXT NOT NULL,
        tab_key TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        text_content TEXT NOT NULL,
        drawing_json TEXT,
        drawing_local_path TEXT,
        drawing_remote_path TEXT,
        drawing_remote_url TEXT,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL,
        UNIQUE(patient_local_id, tab_key, page_number)
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_operations (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_local_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE wiki_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        image_url TEXT NOT NULL,
        tags_json TEXT NOT NULL,
        category TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE retirement_funds (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        audience TEXT NOT NULL,
        request_method TEXT NOT NULL,
        request_delay TEXT NOT NULL,
        aid_amount TEXT NOT NULL,
        therapist_note TEXT NOT NULL,
        website TEXT NOT NULL,
        logo_url TEXT NOT NULL,
        last_edited_at TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await _seedInitialWorkspace(db);
  }

  Future<void> _dropAllTables(Database db) async {
    for (final table in const [
      'retirement_funds',
      'wiki_items',
      'sync_operations',
      'note_pages',
      'documents',
      'dossiers',
      'housings',
      'patients',
      'user_access_scopes',
      'app_session',
      'app_users',
    ]) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
  }

  Future<void> ensureSeeded() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM dossiers'),
    );
    if ((count ?? 0) > 0) return;
    await _seedInitialWorkspace(db);
  }

  Future<void> _seedInitialWorkspace(Database db) async {
    for (final dossier in MOCK_DOSSIERS) {
      final patient = dossier.patient;
      final housing = dossier.housing;
      final timestamp = DateTime.now().toIso8601String();

      await db.insert('patients', {
        'local_id': patient.id,
        'remote_patient_id': null,
        'first_name': patient.firstName,
        'last_name': patient.lastName,
        'birth_date': patient.birthDate,
        'phone': patient.phone,
        'email': patient.email,
        'address': patient.address,
        'city': patient.city,
        'zip_code': patient.zipCode,
        'family_situation': patient.familySituation,
        'income_category': patient.incomeCategory,
        'trusted_person_json': jsonEncode({
          'name': patient.trustedPerson.name,
          'phone': patient.trustedPerson.phone,
          'email': patient.trustedPerson.email,
        }),
        'updated_at': timestamp,
        'remote_updated_at': null,
        'sync_state': dossier.syncState.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final housingLocalId = 'housing_${dossier.id}';
      await db.insert('housings', {
        'local_id': housingLocalId,
        'remote_housing_id': null,
        'patient_local_id': patient.id,
        'type': housing.type.name,
        'year_value': housing.year,
        'surface': housing.surface,
        'heating_mode': housing.heating.name,
        'accessibility_notes': housing.accessibilityNotes,
        'updated_at': timestamp,
        'remote_updated_at': null,
        'sync_state': dossier.syncState.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('dossiers', {
        'local_id': dossier.id,
        'remote_dossier_id': null,
        'patient_local_id': patient.id,
        'housing_local_id': housingLocalId,
        'status': dossier.status.name,
        'ergo_id': dossier.ergoId,
        'visit_date': dossier.visitDate,
        'autonomy_notes': dossier.autonomyNotes,
        'plans_json': jsonEncode(dossier.plans.keys.toList()),
        'created_at': dossier.createdAt,
        'updated_at': timestamp,
        'remote_updated_at': null,
        'sync_state': dossier.syncState.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      if (dossier.syncState != SyncState.synced) {
        await db.insert('sync_operations', {
          'id': 'seed_${dossier.id}',
          'entity_type': 'dossier',
          'entity_local_id': dossier.id,
          'operation_type': dossier.syncState == SyncState.syncError
              ? 'retry'
              : 'seed_sync',
          'payload_json': jsonEncode({'dossierId': dossier.id}),
          'status': dossier.syncState == SyncState.syncError
              ? SyncOperationStatus.failed.name
              : SyncOperationStatus.pending.name,
          'attempt_count': dossier.syncState == SyncState.syncError ? 1 : 0,
          'last_error': dossier.syncState == SyncState.syncError
              ? 'Synchronisation NocoDB non configurée'
              : null,
          'created_at': timestamp,
          'updated_at': timestamp,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }
}
