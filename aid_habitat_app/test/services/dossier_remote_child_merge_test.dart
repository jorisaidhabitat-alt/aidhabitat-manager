import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late DossierRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final localDatabase = LocalDatabase.forTesting(db);
    await localDatabase.createSchemaForTesting();
    repository = DossierRepository(database: localDatabase);
  });

  tearDown(() async {
    await db.close();
  });

  test('le pull hydrate toutes les tables structurées du relevé', () async {
    await repository.mergeRemoteDiagnosticSanitairePayload('dossier-1', {
      'sdbInstances': [
        {'id': 'sdb-1', 'levelField': 'rdc'},
      ],
      'wcInstances': [
        {'id': 'wc-1', 'levelField': 'etage1'},
      ],
    });
    await repository.mergeRemoteMesuresPayload('dossier-1', {
      'deboutHauteurCoude': 102,
      'assisHauteurAssise': 48,
      'assisProfondeurGenoux': 54,
      'assisHauteurCoudes': 72,
      'observations': 'Mesures distantes',
    });
    await repository.mergeRemoteObservationsPayload('dossier-1', {
      'observationEquipements': 'Équipements distants',
      'projetSouhaitUsage': 'Projet distant',
      'resumePreconisations': 'Résumé distant',
    });
    await repository.mergeRemoteVisitRecommendationsPayload('dossier-1', [
      {'id': 'reco-1', 'wikiItemId': 'wiki-1', 'wikiTitle': 'Barre d’appui'},
    ]);

    expect(await db.query('diagnostic_sanitaires'), hasLength(1));
    expect(await db.query('mesures_anthropometriques'), hasLength(1));
    expect(await db.query('observations_synthese'), hasLength(1));
    expect(await db.query('visit_recommendations'), hasLength(1));

    final observations = (await db.query('observations_synthese')).single;
    expect(observations['projet_souhait_usage'], 'Projet distant');
    final recommendations =
        jsonDecode(
              (await db.query('visit_recommendations')).single['items_json']!
                  as String,
            )
            as List<dynamic>;
    expect(recommendations.single['wikiItemId'], 'wiki-1');
  });

  test('le pull ne remplace aucune modification locale en attente', () async {
    final now = DateTime.now().toIso8601String();
    await db.insert('diagnostic_sanitaires', {
      'local_id': 'diag-local',
      'dossier_local_id': 'dossier-1',
      'sdb_instances_json': '[{"id":"local"}]',
      'wc_instances_json': '[]',
      'updated_at': now,
      'sync_state': 'pendingSync',
    });
    await db.insert('mesures_anthropometriques', {
      'local_id': 'mes-local',
      'dossier_local_id': 'dossier-1',
      'observations': 'Mesures locales',
      'updated_at': now,
      'sync_state': 'pendingSync',
    });
    await db.insert('observations_synthese', {
      'local_id': 'obs-local',
      'dossier_local_id': 'dossier-1',
      'projet_souhait_usage': 'Projet local',
      'updated_at': now,
      'sync_state': 'pendingSync',
    });

    expect(
      await repository.mergeRemoteDiagnosticSanitairePayload('dossier-1', {
        'sdbInstances': [
          {'id': 'remote'},
        ],
        'wcInstances': const [],
      }),
      isFalse,
    );
    expect(
      await repository.mergeRemoteMesuresPayload('dossier-1', {
        'observations': 'Mesures distantes',
      }),
      isFalse,
    );
    expect(
      await repository.mergeRemoteObservationsPayload('dossier-1', {
        'projetSouhaitUsage': 'Projet distant',
      }),
      isFalse,
    );

    expect(
      (await db.query('mesures_anthropometriques')).single['observations'],
      'Mesures locales',
    );
    expect(
      (await db.query('observations_synthese')).single['projet_souhait_usage'],
      'Projet local',
    );
  });

  test(
    'une écriture récente protège le cache des anciennes répliques',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('observations_synthese', {
        'local_id': 'obs-local',
        'dossier_local_id': 'dossier-1',
        'projet_souhait_usage': 'Valeur fraîche',
        'updated_at': now,
        'sync_state': 'synced',
      });
      await db.insert('sync_operations', {
        'id': 'observations_update_dossier-1',
        'entity_type': 'observations_synthese',
        'entity_local_id': 'dossier-1',
        'operation_type': 'update',
        'payload_json': '{}',
        'status': 'completed',
        'attempt_count': 1,
        'created_at': now,
        'updated_at': now,
      });

      final merged = await repository.mergeRemoteObservationsPayload(
        'dossier-1',
        {'projetSouhaitUsage': 'Ancienne valeur distante'},
      );

      expect(merged, isFalse);
      expect(
        (await db.query(
          'observations_synthese',
        )).single['projet_souhait_usage'],
        'Valeur fraîche',
      );
    },
  );

  test('un brouillon de préconisation survit au pull distant', () async {
    final now = DateTime.now().toIso8601String();
    await db.insert('visit_recommendations', {
      'local_id': 'reco-local',
      'dossier_local_id': 'dossier-1',
      'items_json': jsonEncode([
        {'id': 'draft-1', 'wikiItemId': '', 'customTitle': 'Brouillon'},
      ]),
      'updated_at': now,
      'sync_state': 'pendingSync',
    });

    final merged = await repository.mergeRemoteVisitRecommendationsPayload(
      'dossier-1',
      [
        {'id': 'remote-1', 'wikiItemId': 'wiki-1'},
      ],
    );

    expect(merged, isTrue);
    final row = (await db.query('visit_recommendations')).single;
    final items = jsonDecode(row['items_json']! as String) as List<dynamic>;
    expect(items, hasLength(2));
    expect(items.last['customTitle'], 'Brouillon');
    expect(row['sync_state'], 'pendingSync');
  });

  test('une préconisation en conflit ne peut pas être écrasée', () async {
    final now = DateTime.now().toIso8601String();
    await db.insert('visit_recommendations', {
      'local_id': 'reco-local',
      'dossier_local_id': 'dossier-1',
      'items_json': jsonEncode([
        {'id': 'local-1', 'wikiItemId': 'wiki-local'},
      ]),
      'updated_at': now,
      'sync_state': 'conflict',
    });

    final merged = await repository.mergeRemoteVisitRecommendationsPayload(
      'dossier-1',
      [
        {'id': 'remote-1', 'wikiItemId': 'wiki-remote'},
      ],
    );

    expect(merged, isFalse);
    final row = (await db.query('visit_recommendations')).single;
    final items = jsonDecode(row['items_json']! as String) as List<dynamic>;
    expect(items.single['wikiItemId'], 'wiki-local');
    expect(row['sync_state'], 'conflict');
  });
}
