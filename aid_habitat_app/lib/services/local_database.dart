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

  // ---------------------------------------------------------------------------
  // Incremental migrations — each step preserves existing data.
  //
  // IMPORTANT: When adding a new schema version, bump _dbVersion and add a
  // new case to _onUpgrade. Never drop tables that contain user data.
  // ---------------------------------------------------------------------------

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Run each migration step in sequence so upgrading from any old version
    // to any new version works correctly (e.g. 1->4 runs steps 2, 3, 4).
    if (oldVersion < 2) {
      await _migrateV1ToV2(db);
    }
    if (oldVersion < 3) {
      await _migrateV2ToV3(db);
    }
    if (oldVersion < 4) {
      await _migrateV3ToV4(db);
    }
    if (oldVersion < 5) {
      await _migrateV4ToV5(db);
    }
  }

  /// v1 → v2: Original schema had no remote_updated_at or sync_state columns
  /// on patients and housings. Add them if missing.
  Future<void> _migrateV1ToV2(Database db) async {
    await _addColumnIfMissing(db, 'patients', 'remote_updated_at', 'TEXT');
    await _addColumnIfMissing(db, 'patients', 'sync_state', "TEXT NOT NULL DEFAULT 'synced'");
    await _addColumnIfMissing(db, 'housings', 'remote_updated_at', 'TEXT');
    await _addColumnIfMissing(db, 'housings', 'sync_state', "TEXT NOT NULL DEFAULT 'synced'");
  }

  /// v2 → v3: Added user_access_scopes table and ergo_label to app_users.
  Future<void> _migrateV2ToV3(Database db) async {
    await _createTableIfMissing(db, 'user_access_scopes', '''
      CREATE TABLE user_access_scopes (
        local_id TEXT PRIMARY KEY,
        user_local_id TEXT NOT NULL,
        scope_type TEXT NOT NULL,
        scope_value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await _addColumnIfMissing(db, 'app_users', 'ergo_label', 'TEXT');
  }

  /// v3 → v4: Add indexes for common queries and dossier_local_id to
  /// documents & note_pages for proper dossier scoping.
  Future<void> _migrateV3ToV4(Database db) async {
    await _addColumnIfMissing(db, 'documents', 'dossier_local_id', 'TEXT');
    await _addColumnIfMissing(db, 'note_pages', 'dossier_local_id', 'TEXT');

    // Indexes to speed up common lookups
    await db.execute('CREATE INDEX IF NOT EXISTS idx_dossiers_patient ON dossiers(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_dossiers_sync ON dossiers(sync_state)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_patient ON documents(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_sync ON documents(sync_state)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_note_pages_patient ON note_pages(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_sync_ops_status ON sync_operations(status)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_user_scopes_user ON user_access_scopes(user_local_id)');
  }

  /// v4 → v5: Add wiki_items and retirement_funds tables for offline reference
  /// data caching.
  Future<void> _migrateV4ToV5(Database db) async {
    await _createTableIfMissing(db, 'wiki_items', _createWikiItemsSQL);
    await _createTableIfMissing(db, 'retirement_funds', _createRetirementFundsSQL);
    await _createTableIfMissing(db, 'reference_sync_meta', _createReferenceSyncMetaSQL);
  }

  static const _createWikiItemsSQL = '''
    CREATE TABLE wiki_items (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      image_url TEXT NOT NULL DEFAULT '',
      tags_json TEXT NOT NULL DEFAULT '[]',
      category TEXT NOT NULL DEFAULT '',
      created_at TEXT,
      updated_at TEXT,
      last_synced_at TEXT NOT NULL
    )
  ''';

  static const _createRetirementFundsSQL = '''
    CREATE TABLE retirement_funds (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      phone TEXT NOT NULL DEFAULT '',
      audience TEXT NOT NULL DEFAULT '',
      request_method TEXT NOT NULL DEFAULT '',
      request_delay TEXT NOT NULL DEFAULT '',
      aid_amount TEXT NOT NULL DEFAULT '',
      therapist_note TEXT NOT NULL DEFAULT '',
      website TEXT NOT NULL DEFAULT '',
      logo_url TEXT NOT NULL DEFAULT '',
      last_edited_at TEXT,
      last_synced_at TEXT NOT NULL
    )
  ''';

  static const _createReferenceSyncMetaSQL = '''
    CREATE TABLE reference_sync_meta (
      table_name TEXT PRIMARY KEY,
      last_synced_at TEXT NOT NULL
    )
  ''';

  // ---------------------------------------------------------------------------
  // Helpers for safe incremental migrations
  // ---------------------------------------------------------------------------

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final columnNames = columns.map((c) => c['name'] as String).toSet();
    if (!columnNames.contains(column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  Future<void> _createTableIfMissing(
    Database db,
    String table,
    String createSql,
  ) async {
    final existing = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    if (existing.isEmpty) {
      await db.execute(createSql);
    }
  }

  // ---------------------------------------------------------------------------
  // Initial schema creation (for brand new installs)
  // ---------------------------------------------------------------------------

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
        second_first_name TEXT NOT NULL DEFAULT '',
        second_last_name TEXT NOT NULL DEFAULT '',
        occupants_json TEXT,
        number_people INTEGER,
        fiscal_revenue REAL,
        apa INTEGER NOT NULL DEFAULT 0,
        invalidity INTEGER NOT NULL DEFAULT 0,
        invalidity_txt TEXT NOT NULL DEFAULT '',
        home_help INTEGER NOT NULL DEFAULT 0,
        home_help_txt TEXT NOT NULL DEFAULT '',
        dependence_txt TEXT NOT NULL DEFAULT '',
        city_id TEXT NOT NULL DEFAULT '',
        caisse_retraite_principale TEXT NOT NULL DEFAULT '',
        caisses_retraite_complementaires TEXT NOT NULL DEFAULT '',
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
        year_construction TEXT NOT NULL DEFAULT '',
        year_habitation TEXT NOT NULL DEFAULT '',
        levels INTEGER,
        typology TEXT NOT NULL DEFAULT 'Maison',
        basement INTEGER NOT NULL DEFAULT 0,
        basement_desc TEXT NOT NULL DEFAULT '',
        rdc INTEGER NOT NULL DEFAULT 0,
        rdc_desc TEXT NOT NULL DEFAULT '',
        floor INTEGER NOT NULL DEFAULT 0,
        floor_desc TEXT NOT NULL DEFAULT '',
        garage INTEGER NOT NULL DEFAULT 0,
        veranda INTEGER NOT NULL DEFAULT 0,
        balcon INTEGER NOT NULL DEFAULT 0,
        terrasse INTEGER NOT NULL DEFAULT 0,
        jardin INTEGER NOT NULL DEFAULT 0,
        heating_details_json TEXT NOT NULL DEFAULT '{}',
        volets_roulants_manuels_localisation TEXT NOT NULL DEFAULT '',
        volets_roulants_manuels_entier INTEGER NOT NULL DEFAULT 0,
        volets_roulants_electriques_localisation TEXT NOT NULL DEFAULT '',
        volets_roulants_electriques_entier INTEGER NOT NULL DEFAULT 0,
        volets_persiennes_localisation TEXT NOT NULL DEFAULT '',
        volets_persiennes_entier INTEGER NOT NULL DEFAULT 0,
        cheminement_escalier_exterieur INTEGER NOT NULL DEFAULT 0,
        cheminement_escalier_interieur INTEGER NOT NULL DEFAULT 0,
        cheminement_pente_douce INTEGER NOT NULL DEFAULT 0,
        cheminement_plat INTEGER NOT NULL DEFAULT 0,
        cheminement_quelques_marches INTEGER NOT NULL DEFAULT 0,
        cheminement_par_arriere INTEGER NOT NULL DEFAULT 0,
        cheminement_seuil_porte INTEGER NOT NULL DEFAULT 0,
        porte_garage_id TEXT NOT NULL DEFAULT '',
        portail_id TEXT NOT NULL DEFAULT '',
        motorisation_porte_garage TEXT NOT NULL DEFAULT '',
        motorisation_portail TEXT NOT NULL DEFAULT '',
        easy_access INTEGER NOT NULL DEFAULT 0,
        comments TEXT NOT NULL DEFAULT '',
        access_observation TEXT NOT NULL DEFAULT '',
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
        compte_anah TEXT NOT NULL DEFAULT '',
        nature_accompagnement TEXT NOT NULL DEFAULT '',
        envoi_rapport TEXT NOT NULL DEFAULT '',
        personnes_presentes_visite TEXT NOT NULL DEFAULT '',
        medical_context_json TEXT,
        autonomy_json TEXT,
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
        dossier_local_id TEXT,
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
        dossier_local_id TEXT,
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

    // Reference data tables (offline cache)
    await db.execute(_createWikiItemsSQL);
    await db.execute(_createRetirementFundsSQL);
    await db.execute(_createReferenceSyncMetaSQL);

    // Indexes for common queries
    await db.execute('CREATE INDEX IF NOT EXISTS idx_dossiers_patient ON dossiers(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_dossiers_sync ON dossiers(sync_state)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_patient ON documents(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_sync ON documents(sync_state)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_note_pages_patient ON note_pages(patient_local_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_sync_ops_status ON sync_operations(status)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_user_scopes_user ON user_access_scopes(user_local_id)');

    await _seedInitialWorkspace(db);
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
        'second_first_name': '',
        'second_last_name': '',
        'occupants_json': null,
        'number_people': null,
        'fiscal_revenue': null,
        'apa': 0,
        'invalidity': 0,
        'invalidity_txt': '',
        'home_help': 0,
        'home_help_txt': '',
        'dependence_txt': '',
        'city_id': '',
        'caisse_retraite_principale': '',
        'caisses_retraite_complementaires': '',
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
        'year_construction': '',
        'year_habitation': '',
        'levels': null,
        'typology': 'Maison',
        'basement': 0,
        'basement_desc': '',
        'rdc': 0,
        'rdc_desc': '',
        'floor': 0,
        'floor_desc': '',
        'garage': 0,
        'veranda': 0,
        'balcon': 0,
        'terrasse': 0,
        'jardin': 0,
        'heating_details_json': '{}',
        'volets_roulants_manuels_localisation': '',
        'volets_roulants_manuels_entier': 0,
        'volets_roulants_electriques_localisation': '',
        'volets_roulants_electriques_entier': 0,
        'volets_persiennes_localisation': '',
        'volets_persiennes_entier': 0,
        'cheminement_escalier_exterieur': 0,
        'cheminement_escalier_interieur': 0,
        'cheminement_pente_douce': 0,
        'cheminement_plat': 0,
        'cheminement_quelques_marches': 0,
        'cheminement_par_arriere': 0,
        'cheminement_seuil_porte': 0,
        'porte_garage_id': '',
        'portail_id': '',
        'motorisation_porte_garage': '',
        'motorisation_portail': '',
        'easy_access': 0,
        'comments': '',
        'access_observation': '',
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
        'compte_anah': '',
        'nature_accompagnement': '',
        'envoi_rapport': '',
        'personnes_presentes_visite': '',
        'medical_context_json': null,
        'autonomy_json': null,
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
