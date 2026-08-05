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

  test('le pull workspace hydrate le contexte multi-occupants', () async {
    await repository.mergeRemoteDossierPayloads([
      _remoteDossier(autonomy: _autonomy(firstAttention: true)),
    ]);

    final rows = await db.query('contexte_de_vie');
    expect(rows, hasLength(1));
    final autonomy = jsonDecode(rows.single['autonomy_json']! as String);
    expect(autonomy['occupants'], hasLength(2));
    expect(autonomy['occupants'][0]['attention'][0]['checked'], isTrue);
    expect(autonomy['occupants'][1]['autonomy'][0]['checked'], isTrue);
  });

  test('le pull ne remplace pas un contexte local encore en attente', () async {
    final localAutonomy = _autonomy(firstAttention: true);
    await repository.mergeRemoteDossierPayloads([
      _remoteDossier(autonomy: localAutonomy),
    ]);
    await db.update(
      'contexte_de_vie',
      {'autonomy_json': jsonEncode(localAutonomy), 'sync_state': 'pendingSync'},
      where: 'dossier_local_id = ?',
      whereArgs: const ['dossier-prime'],
    );

    await repository.mergeRemoteDossierPayloads([
      _remoteDossier(autonomy: _autonomy(firstAttention: false)),
    ]);

    final row = (await db.query('contexte_de_vie')).single;
    final autonomy = jsonDecode(row['autonomy_json']! as String);
    expect(autonomy['occupants'][0]['attention'][0]['checked'], isTrue);
    expect(row['sync_state'], 'pendingSync');
  });

  test(
    'le statut préparé est partagé sans écraser une mutation locale',
    () async {
      await repository.mergeRemoteDossierPayloads([
        _remoteDossier(
          autonomy: _autonomy(firstAttention: false),
          beneficiaryPrepared: true,
        ),
      ]);

      var dossier = (await db.query('dossiers')).single;
      expect(dossier['beneficiary_prepared'], 1);

      await repository.setBeneficiaryPrepared(
        dossierLocalId: 'dossier-prime',
        prepared: false,
      );
      dossier = (await db.query('dossiers')).single;
      expect(dossier['beneficiary_prepared'], 0);
      expect(dossier['sync_state'], 'pendingSync');

      final operations = await db.query(
        'sync_operations',
        where: 'entity_type = ? AND entity_local_id = ?',
        whereArgs: const ['dossier', 'dossier-prime'],
      );
      expect(operations, hasLength(1));

      await repository.mergeRemoteDossierPayloads([
        _remoteDossier(
          autonomy: _autonomy(firstAttention: false),
          beneficiaryPrepared: true,
        ),
      ]);
      dossier = (await db.query('dossiers')).single;
      expect(dossier['beneficiary_prepared'], 0);
    },
  );
}

Map<String, dynamic> _remoteDossier({
  required Map<String, dynamic> autonomy,
  bool? beneficiaryPrepared,
}) {
  return {
    'id': 'dossier-prime',
    'status': 'À visiter',
    'ergoId': 'Coralie',
    'createdAt': '2026-08-04T10:00:00.000Z',
    'workspaceUpdatedAt': '2026-08-04T12:00:00.000Z',
    'patient': {
      'id': 'nocodb-beneficiaire-57',
      'firstName': 'Thierry',
      'lastName': 'Prime',
      'numberPeople': 2,
      'trustedPerson': {'name': '', 'phone': '', 'email': ''},
    },
    'housing': <String, dynamic>{},
    'medicalContext': <String, dynamic>{},
    'autonomy': autonomy,
    if (beneficiaryPrepared != null) 'beneficiaryPrepared': beneficiaryPrepared,
  };
}

Map<String, dynamic> _autonomy({required bool firstAttention}) {
  Map<String, dynamic> item(bool checked) => {
    'name': 'Déplacements/transferts',
    'checked': checked,
  };

  return {
    'done': false,
    'checklist': [item(false)],
    'occupants': [
      {
        'medical': <String, dynamic>{},
        'autonomyDone': false,
        'autonomy': [item(false)],
        'attention': [item(firstAttention)],
        'humanHelp': [item(true)],
      },
      {
        'medical': <String, dynamic>{},
        'autonomyDone': true,
        'autonomy': [item(true)],
        'attention': [item(false)],
        'humanHelp': [item(false)],
      },
    ],
  };
}
