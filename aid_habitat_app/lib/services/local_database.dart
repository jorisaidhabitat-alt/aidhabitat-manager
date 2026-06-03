import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
// Audit P0 #4 Layer 2 (2026-05-15) : `sqflite_sqlcipher` permet
// `openDatabase(password: ...)` pour chiffrer toute la base SQLite
// avec AES-256 (SQLCipher 4 par défaut). Compatible iOS, macOS,
// Android. Sur web, on retombe sur `sqflite_common_ffi_web` qui n'a
// pas de support SQLCipher → la PWA reste non chiffrée mais protégée
// par l'origin isolation Safari + sandbox iOS.
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'secure_session_storage.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _dbName = 'aid_habitat_offline.db';
  static const _debugFallbackDbName = 'aid_habitat_offline.debug_fallback.db';
  static const _dbVersion = 18;

  Database? _database;
  bool _forceDebugPlaintextFallback = false;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = await getDatabasesPath();
    final encryptedPath = p.join(dbPath, _dbName);
    final fallbackPath = p.join(dbPath, _debugFallbackDbName);

    if (_shouldEncrypt() && !_forceDebugPlaintextFallback) {
      try {
        _database = await _openEncrypted(encryptedPath);
      } catch (error) {
        if (_canUseDebugPlaintextFallback(error)) {
          _forceDebugPlaintextFallback = true;
          debugPrint(
            '[security] Keychain indisponible sur ce macOS debug '
            '→ fallback SQLite non chiffré local ($fallbackPath). '
            'Cause: $error',
          );
          _database = await openDatabase(
            fallbackPath,
            version: _dbVersion,
            onCreate: _onCreate,
            onUpgrade: _onUpgrade,
          );
        } else {
          rethrow;
        }
      }
    } else {
      final plainPath = _forceDebugPlaintextFallback
          ? fallbackPath
          : encryptedPath;
      // Web (PWA) : sqflite_common_ffi_web ne supporte pas SQLCipher.
      // On garde l'ouverture historique non chiffrée. Origin isolation
      // Safari + sandbox iOS limitent l'exposition.
      _database = await openDatabase(
        plainPath,
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }
    return _database!;
  }

  /// Vrai quand on est sur une cible où `sqflite_sqlcipher` peut
  /// fonctionner (iOS, macOS, Android). Sur le web Flutter, le factory
  /// est `sqflite_common_ffi_web` (SQLite WASM) et SQLCipher n'y est
  /// pas disponible → on retombe sur le chemin historique non chiffré.
  ///
  /// On utilise `defaultTargetPlatform` de `flutter/foundation` plutôt
  /// que `dart:io.Platform` pour rester compilable sur le build web
  /// sans warning ou exception au runtime (tree-shaking propre).
  bool _shouldEncrypt() {
    if (kIsWeb) return false;
    final t = defaultTargetPlatform;
    return t == TargetPlatform.iOS ||
        t == TargetPlatform.macOS ||
        t == TargetPlatform.android;
  }

  bool _canUseDebugPlaintextFallback(Object error) {
    if (!kDebugMode ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.macOS) {
      return false;
    }
    final message = error.toString();
    return message.contains('-34018') ||
        message.contains('A required entitlement isn\'t present') ||
        message.contains('Impossible de stocker la master key SQLCipher');
  }

  /// Ouvre la base via SQLCipher avec la master key stockée dans
  /// `SecureSessionStorage`. Gère la **migration depuis une base en
  /// clair pré-fix** : si on détecte un fichier non-chiffrable avec la
  /// clé (= installé avant le fix P0 #4 Layer 2), on le supprime et on
  /// recrée vide. Les données se re-tireront depuis NocoDB au prochain
  /// pull — perte = uniquement les écritures locales non encore sync.
  Future<Database> _openEncrypted(String fullPath) async {
    final masterKey = await SecureSessionStorage.instance.ensureMasterKey();

    Future<Database> openWithKey() => sqlcipher.openDatabase(
      fullPath,
      password: masterKey,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    try {
      return await openWithKey();
    } catch (firstError) {
      // SQLCipher refuse d'ouvrir : soit fichier corrompu, soit base
      // legacy en clair (= installé avant ce fix). Comme on ne peut
      // pas distinguer les deux côté Dart, on tente la migration
      // pragmatique « wipe + recreate ». La perte est limitée car
      // NocoDB est la source de vérité.
      // Refonte 2026-05-16 (audit P0 #3) : AVANT de supprimer la DB
      // legacy, on la BACKUP dans un fichier `.bak.<timestamp>` à côté.
      // Sans ce backup, toutes les modifs offline non encore synchronisées
      // étaient perdues — le commentaire historique disait « La perte
      // est limitée car NocoDB est la source de vérité » mais c'est
      // faux pour les ops `pending` jamais poussées. Désormais, un
      // support tech peut récupérer manuellement le fichier `.bak`
      // en cas de drame (corruption WAL, master key invalidée, etc.).
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      debugPrint(
        '[security] SQLCipher openDatabase a échoué : $firstError. '
        'Backup du fichier legacy en .bak.$timestamp puis recréation chiffrée.',
      );
      try {
        final legacyFile = File(fullPath);
        if (await legacyFile.exists()) {
          // Backup avant suppression. `rename` est atomique sur le même
          // filesystem — pas de risque de corruption pendant la copie.
          final backupPath = '$fullPath.bak.$timestamp';
          await legacyFile.rename(backupPath);
          debugPrint('[security] DB legacy sauvée → $backupPath');
        }
        // Les fichiers WAL/SHM contiennent des transactions non commit —
        // on les déplace aussi (au lieu de delete) pour préserver toute
        // donnée non encore flushée dans le main file.
        for (final suffix in ['-journal', '-wal', '-shm']) {
          final sideCar = File('$fullPath$suffix');
          if (await sideCar.exists()) {
            final sideCarBackup = '$fullPath$suffix.bak.$timestamp';
            await sideCar.rename(sideCarBackup);
          }
        }
      } catch (backupError) {
        debugPrint(
          '[security] backup DB legacy échoué : $backupError — '
          'tentative de delete en dernier recours pour débloquer le boot.',
        );
        // Si on ne peut pas backup (disk full, permission denied), on
        // tombe sur l'ancien comportement delete pour ne pas bloquer
        // l'app au démarrage. Mieux : app utilisable + perte partielle
        // que app cassée définitivement.
        try {
          final legacyFile = File(fullPath);
          if (await legacyFile.exists()) await legacyFile.delete();
          for (final suffix in ['-journal', '-wal', '-shm']) {
            final sideCar = File('$fullPath$suffix');
            if (await sideCar.exists()) await sideCar.delete();
          }
        } catch (_) {
          /* best-effort */
        }
      }
      // Deuxième tentative — création fraîche chiffrée.
      return await openWithKey();
    }
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
    if (oldVersion < 6) {
      await _migrateV5ToV6(db);
    }
    if (oldVersion < 7) {
      await _migrateV6ToV7(db);
    }
    if (oldVersion < 8) {
      await _migrateV7ToV8(db);
    }
    if (oldVersion < 9) {
      await _migrateV8ToV9(db);
    }
    if (oldVersion < 10) {
      await _migrateV9ToV10(db);
    }
    if (oldVersion < 11) {
      await _migrateV10ToV11(db);
    }
    if (oldVersion < 12) {
      await _migrateV11ToV12(db);
    }
    if (oldVersion < 13) {
      await _migrateV12ToV13(db);
    }
    if (oldVersion < 14) {
      await _migrateV13ToV14(db);
    }
    if (oldVersion < 15) {
      await _migrateV14ToV15(db);
    }
    if (oldVersion < 16) {
      await _migrateV15ToV16(db);
    }
    if (oldVersion < 17) {
      await _migrateV16ToV17(db);
    }
    if (oldVersion < 18) {
      await _migrateV17ToV18(db);
    }
  }

  /// v17 → v18 : sécurité — purge des mots de passe `access_members.
  /// generated_password` et `app_session.remote_token` qui pouvaient
  /// traîner en clair sur SQLite depuis des installs pré-fix audit
  /// 2026-05-15 (P0 #3 + #4 Layer 1).
  ///
  /// - `access_members.generated_password` : avant le fix P0 #3, le
  ///   serveur exposait le password en clair dans /api/admin/access-
  ///   members → certains comptes Flutter pouvaient en avoir une copie
  ///   cachée localement. On RAZ par sécurité, l'admin re-génèrera
  ///   via "Réinitialiser" si besoin (réception dans la response POST).
  /// - `app_session.remote_token` : avant le fix P0 #4 Layer 1, le
  ///   token de session était stocké en clair ici. Désormais il est
  ///   dans Keychain via `SecureSessionStorage`. La purge ici est une
  ///   double sécurité au-cas-où la migration `restoreRemoteSession`
  ///   n'aurait pas été appelée (ex: crash entre `openDatabase` et
  ///   `AuthService.restoreRemoteSession`).
  ///
  /// Idempotent : si les colonnes sont déjà vides, l'UPDATE est no-op.
  Future<void> _migrateV17ToV18(Database db) async {
    try {
      await db.update('access_members', {'generated_password': ''});
    } catch (_) {
      // Table inexistante (cas edge install fraîche) — ignore.
    }
    try {
      await db.update('app_session', {'remote_token': ''});
    } catch (_) {
      // Idem.
    }
  }

  /// v16 → v17 : flag `beneficiary_prepared` sur `dossiers` — coche
  /// « Bénéficiaire préparé » dans le bloc bénéficiaire de l'écran
  /// dossier (demande utilisateur 2026-05-05). Quand `1`, l'UI passe
  /// le bandeau bénéficiaire en violet foncé et la liste « Mes
  /// dossiers » entoure l'avatar de vert (vs jaune par défaut).
  ///
  /// Local-only en v1 — pas de colonne miroir sur NocoDB. Si l'ergo
  /// recharge le dossier depuis un autre device, le flag repart à 0.
  /// Acceptable pour cette première itération (sync à voir plus tard).
  Future<void> _migrateV16ToV17(Database db) async {
    await _addColumnIfMissing(
      db,
      'dossiers',
      'beneficiary_prepared',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v15 → v16 : flag `easy_access_set` sur `housings` pour distinguer
  /// « accès depuis la rue non renseigné » de « explicitement à revoir »
  /// (demande utilisateur 2026-04-29). Avant cette colonne, le champ
  /// `easy_access INTEGER NOT NULL DEFAULT 0` mélangeait les deux états :
  /// la valeur 0 par défaut affichait toujours la pill « À revoir »
  /// même si l'ergo n'avait jamais cliqué dessus, et le validateur de
  /// pré-génération ne pouvait pas signaler le champ comme manquant.
  ///
  /// Sémantique :
  ///   - `easy_access_set = 0` → l'ergo n'a pas répondu (pas de pill UI).
  ///   - `easy_access_set = 1` → l'ergo a explicitement choisi
  ///     « Facile » (`easy_access=1`) ou « À revoir » (`easy_access=0`).
  ///
  /// Toutes les rows existantes héritent de `easy_access_set=0` au moment
  /// de la migration : on considère que les valeurs 0/1 historiques
  /// n'étaient pas fiables (mélange de pré-sélection + saisies réelles).
  /// L'ergo devra re-cliquer Facile/À revoir au prochain reload des
  /// dossiers concernés. Idempotent grâce à `_addColumnIfMissing`.
  Future<void> _migrateV15ToV16(Database db) async {
    await _addColumnIfMissing(
      db,
      'housings',
      'easy_access_set',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v14 → v15 : reset global des niveaux + pièces dans `housings`
  /// (demande utilisateur 2026-04-28). Symptôme avant ce reset : des
  /// pièces (Salle de bain, WC) restaient cochées sur des niveaux qui
  /// avaient été désélectionnés, créant des SDB/WC fantômes au reload
  /// (l'inférence pour les onglets SDB/WC se base sur la présence du
  /// label dans `*_rooms_json`, indépendamment du flag de niveau).
  ///
  /// Effet :
  ///   - Tous les niveaux désactivés (`basement=0, rdc=0, floor=0,
  ///     second_floor=0, third_floor=0, levels=0`)
  ///   - Tous les `*_rooms_json` remis à `'[]'`
  ///   - Chaque housing passe en `pendingSync` pour propager le reset
  ///     vers NocoDB (sous_sol/rdc/etage repassent à false côté serveur)
  ///   - Une `sync_op` `housing_update` est enqueuée par row touchée
  ///
  /// Idempotent : si la migration a déjà été appliquée (pas de housings
  /// avec un niveau actif et/ou rooms non-vides), c'est un no-op.
  ///
  /// L'ergo devra re-cocher les niveaux et leurs pièces après cette
  /// migration pour les dossiers concernés. Les autres données (volets,
  /// chauffage, surface, sanitaires équipement, mesures…) restent
  /// intactes — seules les colonnes niveaux+rooms sont touchées.
  Future<void> _migrateV14ToV15(Database db) async {
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'housings',
      columns: ['local_id', 'patient_local_id'],
    );
    for (final row in rows) {
      final housingLocalId = row['local_id'] as String?;
      if (housingLocalId == null) continue;
      // Reset des 11 colonnes ciblées + bump updated_at + pendingSync.
      await db.update(
        'housings',
        {
          'basement': 0,
          'rdc': 0,
          'floor': 0,
          'second_floor': 0,
          'third_floor': 0,
          'levels': 0,
          'basement_rooms_json': '[]',
          'rdc_rooms_json': '[]',
          'floor_rooms_json': '[]',
          'second_floor_rooms_json': '[]',
          'third_floor_rooms_json': '[]',
          'updated_at': now,
          'sync_state': 'pendingSync',
        },
        where: 'local_id = ?',
        whereArgs: [housingLocalId],
      );

      // Enqueue une sync_op `housing` pour propager vers NocoDB.
      // Le sync engine consomme ce type via `_processHousingOperation`
      // qui PATCH `/api/logements/by-beneficiary/:id`. Côté serveur on
      // ne pousse que les flags (sous_sol, rdc, etage, nombre_niveaux)
      // — les `*_rooms_json` sont local-only (pas de colonne NocoDB).
      //
      // Le `local_id` du housing est `housing_<dossierId>` → on
      // retrouve le dossierId pour résoudre le beneficiaryId côté
      // remote (cf. `_resolveRemoteBeneficiaryIdFromDossier`).
      final dossierId = housingLocalId.startsWith('housing_')
          ? housingLocalId.substring('housing_'.length)
          : housingLocalId;
      final opId = 'housing_update_reset_v15_$dossierId';
      await db.insert('sync_operations', {
        'id': opId,
        'entity_type': 'housing',
        'entity_local_id': dossierId,
        'operation_type': 'update',
        'payload_json': jsonEncode({
          'dossierLocalId': dossierId,
          'updates': {
            'basement': false,
            'rdc': false,
            'floor': false,
            'levels': 0,
          },
        }),
        'status': 'pending',
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// v13 → v14 : annotation par page des PDFs dans l'espace Documents.
  /// Avant cette colonne, l'écriture sur un PDF flatten remplaçait le
  /// document local entier par un PNG (perte de la structure PDF →
  /// plus de navigation possible). Maintenant on stocke un JSON
  /// `{ "1": "data:image/png;base64,...", "3": "data:image/png;..." }`
  /// qui mappe un n° de page à son aplat (PDF page + traits ergo
  /// fusionnés). Le PDF original reste intact dans
  /// `local_file_data_url` — la preview applique l'overlay PNG quand
  /// la page courante a une entrée dans la map, sinon rendu PDF brut.
  Future<void> _migrateV13ToV14(Database db) async {
    await _addColumnIfMissing(db, 'documents', 'annotations_json', 'TEXT');
  }

  /// v12 → v13 : statut d'occupation (« Propriétaire / Locataire /
  /// Usufruitier ») pour le bloc Foyer du relevé de visite. Avant cette
  /// colonne, le `_occupationStatus` n'était NI lu NI sauvé côté Flutter
  /// → la sélection de l'utilisateur n'arrivait jamais en NocoDB et le
  /// PDF affichait par défaut la case "Propriétaire" cochée pour tous
  /// les dossiers.
  Future<void> _migrateV12ToV13(Database db) async {
    await _addColumnIfMissing(
      db,
      'patients',
      'occupation_status',
      "TEXT NOT NULL DEFAULT ''",
    );
  }

  /// v11 → v12: générateur de rapport PDF (suite). L'onglet Photos du
  /// relevé de visite groupe les photos par catégorie (Logement /
  /// Accessibilité / Sanitaires) et permet à l'ergo de les
  /// **réordonner** dans une catégorie pour décider quelle photo
  /// occupe le slot 1, 2, 3 du PDF. On ajoute `category_order` —
  /// un entier croissant scoping (patient × tag) — pour persister
  /// cet ordre. NULL = pas encore positionné dans une catégorie.
  Future<void> _migrateV11ToV12(Database db) async {
    await _addColumnIfMissing(db, 'documents', 'category_order', 'INTEGER');
  }

  /// v10 → v11: générateur de rapport PDF — la page « Plan du logement »
  /// du PDF a deux emplacements (avant travaux / après travaux). On
  /// ajoute un flag explicite `plan_phase` sur `note_pages` pour que
  /// l'ergo puisse marquer chaque dessin Plans comme appartenant à
  /// l'une ou l'autre phase. Valeurs : 'avant', 'apres', ou NULL
  /// (non encore classé). Ne touche pas aux dessins existants — ils
  /// resteront NULL jusqu'à ce que l'ergo leur attribue une phase.
  Future<void> _migrateV10ToV11(Database db) async {
    await _addColumnIfMissing(db, 'note_pages', 'plan_phase', 'TEXT');
  }

  /// v9 → v10: Generic key/value store. Used by `ReferencesService` to
  /// persist the references payload (communes, EPCIs, barèmes ANAH) on
  /// disk so the next cold start hydrates synchronously instead of
  /// waiting for the `/api/references` round-trip. Without this, the
  /// "Communauté de communes" badge on the dossier page only appears
  /// once the network call lands — which on iPad PWA after a service
  /// worker cache clear takes 1-2 seconds and is visibly out of sync
  /// with the rest of the page.
  Future<void> _migrateV9ToV10(Database db) async {
    await _createTableIfMissing(db, 'kv_store', _createKvStoreSQL);
  }

  static const _createKvStoreSQL = '''
    CREATE TABLE kv_store (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  /// v8 → v9: Offline image cache for the Flutter web PWA. Native targets
  /// have a filesystem cache via [MediaCacheService], but on web
  /// `path_provider` throws — we store the fetched bytes directly in
  /// SQLite so wiki illustrations + retirement logos keep displaying when
  /// the iPad is offline.
  Future<void> _migrateV8ToV9(Database db) async {
    await _createTableIfMissing(db, 'web_media_cache', _createWebMediaCacheSQL);
  }

  static const _createWebMediaCacheSQL = '''
    CREATE TABLE web_media_cache (
      url_hash TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      bytes BLOB NOT NULL,
      fetched_at TEXT NOT NULL
    )
  ''';

  /// v7 → v8: Web platforms (Flutter PWA) don't have a filesystem, so
  /// `documents.local_file_path` can't hold anything. We add a parallel
  /// `local_file_data_url` column that stores the freshly-captured file
  /// as a `data:<mime>;base64,<bytes>` string. The sync processor reads
  /// whichever column is populated and uploads the bytes to NocoDB.
  Future<void> _migrateV7ToV8(Database db) async {
    await _addColumnIfMissing(db, 'documents', 'local_file_data_url', 'TEXT');
  }

  /// v1 → v2: Original schema had no remote_updated_at or sync_state columns
  /// on patients and housings. Add them if missing.
  Future<void> _migrateV1ToV2(Database db) async {
    await _addColumnIfMissing(db, 'patients', 'remote_updated_at', 'TEXT');
    await _addColumnIfMissing(
      db,
      'patients',
      'sync_state',
      "TEXT NOT NULL DEFAULT 'synced'",
    );
    await _addColumnIfMissing(db, 'housings', 'remote_updated_at', 'TEXT');
    await _addColumnIfMissing(
      db,
      'housings',
      'sync_state',
      "TEXT NOT NULL DEFAULT 'synced'",
    );
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
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dossiers_patient ON dossiers(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dossiers_sync ON dossiers(sync_state)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_patient ON documents(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_sync ON documents(sync_state)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_pages_patient ON note_pages(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_ops_status ON sync_operations(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_user_scopes_user ON user_access_scopes(user_local_id)',
    );
  }

  /// v4 → v5: Add wiki_items and retirement_funds tables for offline reference
  /// data caching.
  Future<void> _migrateV4ToV5(Database db) async {
    await _createTableIfMissing(db, 'wiki_items', _createWikiItemsSQL);
    await _createTableIfMissing(
      db,
      'retirement_funds',
      _createRetirementFundsSQL,
    );
    await _createTableIfMissing(
      db,
      'reference_sync_meta',
      _createReferenceSyncMetaSQL,
    );
  }

  /// v5 → v6: Add per-dossier offline tables used by DossierRepository for
  /// the 4 visit-report medical/sanitaire/measurement/observation sections
  /// plus the visit recommendations list. Without these, every read/write
  /// against them raises "no such table" and silently drops offline data.
  Future<void> _migrateV5ToV6(Database db) async {
    await _createTableIfMissing(db, 'contexte_de_vie', _createContexteDeVieSQL);
    await _createTableIfMissing(
      db,
      'diagnostic_sanitaires',
      _createDiagnosticSanitairesSQL,
    );
    await _createTableIfMissing(
      db,
      'mesures_anthropometriques',
      _createMesuresAnthropometriquesSQL,
    );
    await _createTableIfMissing(
      db,
      'observations_synthese',
      _createObservationsSyntheseSQL,
    );
    await _createTableIfMissing(
      db,
      'visit_recommendations',
      _createVisitRecommendationsSQL,
    );
  }

  /// v6 → v7: Offline capability for admin access, wiki creation/edit,
  /// retirement fund edit, and profile photo upload. All of these used to
  /// bypass the sync queue and fail silently when offline.
  ///
  ///  - `access_members` table: cache of admin access members so the
  ///    admin panel works offline and so new ergos provisioned remotely
  ///    can log in offline after the first sync.
  ///  - `wiki_items.pending_image_data_url`: base64 data URL of a wiki
  ///    image captured offline, uploaded on next sync then cleared.
  ///  - `retirement_funds.pending_logo_data_url`: same pattern for fund
  ///    logos edited offline.
  ///  - `app_users.pending_photo_data_url`: same pattern for profile
  ///    photos uploaded offline.
  ///  - `app_users.sync_state`: marks users with pending profile photo
  ///    uploads so the sync engine can find them.
  Future<void> _migrateV6ToV7(Database db) async {
    await _createTableIfMissing(db, 'access_members', _createAccessMembersSQL);
    await _addColumnIfMissing(
      db,
      'wiki_items',
      'pending_image_data_url',
      'TEXT',
    );
    await _addColumnIfMissing(
      db,
      'wiki_items',
      'sync_state',
      "TEXT NOT NULL DEFAULT 'synced'",
    );
    await _addColumnIfMissing(
      db,
      'retirement_funds',
      'pending_logo_data_url',
      'TEXT',
    );
    await _addColumnIfMissing(
      db,
      'retirement_funds',
      'sync_state',
      "TEXT NOT NULL DEFAULT 'synced'",
    );
    await _addColumnIfMissing(
      db,
      'app_users',
      'pending_photo_data_url',
      'TEXT',
    );
    await _addColumnIfMissing(
      db,
      'app_users',
      'sync_state',
      "TEXT NOT NULL DEFAULT 'synced'",
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_access_members_sync '
      'ON access_members(sync_state)',
    );
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
      last_synced_at TEXT NOT NULL,
      pending_image_data_url TEXT,
      sync_state TEXT NOT NULL DEFAULT 'synced'
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
      last_synced_at TEXT NOT NULL,
      pending_logo_data_url TEXT,
      sync_state TEXT NOT NULL DEFAULT 'synced'
    )
  ''';

  static const _createAccessMembersSQL = '''
    CREATE TABLE access_members (
      email TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      role TEXT NOT NULL,
      selectable INTEGER NOT NULL DEFAULT 1,
      establishment_label TEXT NOT NULL DEFAULT '',
      ergo_label TEXT NOT NULL DEFAULT '',
      has_password INTEGER NOT NULL DEFAULT 0,
      generated_password TEXT NOT NULL DEFAULT '',
      created_at TEXT,
      updated_at TEXT NOT NULL,
      last_synced_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced',
      pending_delete INTEGER NOT NULL DEFAULT 0,
      pending_password TEXT
    )
  ''';

  static const _createReferenceSyncMetaSQL = '''
    CREATE TABLE reference_sync_meta (
      table_name TEXT PRIMARY KEY,
      last_synced_at TEXT NOT NULL
    )
  ''';

  static const _createContexteDeVieSQL = '''
    CREATE TABLE contexte_de_vie (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      patient_local_id TEXT,
      medical_context_json TEXT,
      autonomy_json TEXT,
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced'
    )
  ''';

  static const _createDiagnosticSanitairesSQL = '''
    CREATE TABLE diagnostic_sanitaires (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      sdb_instances_json TEXT,
      wc_instances_json TEXT,
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced'
    )
  ''';

  static const _createMesuresAnthropometriquesSQL = '''
    CREATE TABLE mesures_anthropometriques (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      debout_hauteur_coude REAL,
      assis_hauteur_assise REAL,
      assis_profondeur_genoux REAL,
      assis_hauteur_coudes REAL,
      observations TEXT,
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced'
    )
  ''';

  static const _createObservationsSyntheseSQL = '''
    CREATE TABLE observations_synthese (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      observation_equipements TEXT,
      projet_souhait_usage TEXT,
      resume_preconisations TEXT,
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced'
    )
  ''';

  static const _createVisitRecommendationsSQL = '''
    CREATE TABLE visit_recommendations (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      items_json TEXT NOT NULL DEFAULT '[]',
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL DEFAULT 'synced'
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
        profile_photo_url TEXT NOT NULL DEFAULT '',
        pending_photo_data_url TEXT,
        sync_state TEXT NOT NULL DEFAULT 'synced',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        user_local_id TEXT NOT NULL,
        remote_token TEXT,
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
        occupation_status TEXT NOT NULL DEFAULT '',
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
        basement_rooms_json TEXT NOT NULL DEFAULT '[]',
        rdc INTEGER NOT NULL DEFAULT 0,
        rdc_desc TEXT NOT NULL DEFAULT '',
        rdc_rooms_json TEXT NOT NULL DEFAULT '[]',
        floor INTEGER NOT NULL DEFAULT 0,
        floor_desc TEXT NOT NULL DEFAULT '',
        floor_rooms_json TEXT NOT NULL DEFAULT '[]',
        second_floor INTEGER NOT NULL DEFAULT 0,
        second_floor_desc TEXT NOT NULL DEFAULT '',
        second_floor_rooms_json TEXT NOT NULL DEFAULT '[]',
        third_floor INTEGER NOT NULL DEFAULT 0,
        third_floor_desc TEXT NOT NULL DEFAULT '',
        third_floor_rooms_json TEXT NOT NULL DEFAULT '[]',
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
        easy_access_set INTEGER NOT NULL DEFAULT 0,
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
        beneficiary_prepared INTEGER NOT NULL DEFAULT 0,
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
        local_file_data_url TEXT,
        remote_file_path TEXT,
        remote_public_url TEXT,
        tags_json TEXT NOT NULL,
        category_order INTEGER,
        annotations_json TEXT,
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
        plan_phase TEXT,
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
    await db.execute(_createAccessMembersSQL);
    await db.execute(_createWebMediaCacheSQL);
    await db.execute(_createKvStoreSQL);

    // Per-dossier offline tables (visit report sections + recommendations)
    await db.execute(_createContexteDeVieSQL);
    await db.execute(_createDiagnosticSanitairesSQL);
    await db.execute(_createMesuresAnthropometriquesSQL);
    await db.execute(_createObservationsSyntheseSQL);
    await db.execute(_createVisitRecommendationsSQL);

    // Indexes for common queries
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dossiers_patient ON dossiers(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dossiers_sync ON dossiers(sync_state)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_patient ON documents(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_sync ON documents(sync_state)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_pages_patient ON note_pages(patient_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_ops_status ON sync_operations(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_user_scopes_user ON user_access_scopes(user_local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_access_members_sync ON access_members(sync_state)',
    );

    // No initial seed — the workspace is populated from NocoDB at first login.
  }

  Future<void> ensureSeeded() async {
    // Seeding removed — dossiers come from NocoDB only (via
    // DataService.refreshWorkspaceFromRemote). Offline-created dossiers
    // remain as the user creates them.
    await database;
  }
}
