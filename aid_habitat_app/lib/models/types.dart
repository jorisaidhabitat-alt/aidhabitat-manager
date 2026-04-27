enum DossierStatus {
  TO_VISIT,
  VISITED,
  IN_PROGRESS,
  WAITING_QUOTES,
  QUOTES_RECEIVED,
  WAITING_GRANT,
  GRANT_VALIDATED,
  WORKS_STARTED,
  WORKS_COMPLETED,
  CLOSED,
  ARCHIVED,
}

enum HousingType { HOUSE, APARTMENT }

enum HeatingMode { ELECTRIC, GAS, WOOD, OIL, OTHER }

enum SyncState { localOnly, pendingSync, syncing, synced, syncError, conflict }

enum SyncOperationStatus { pending, running, completed, failed }

enum LocalUserRole { admin, ergo }

const kAutonomyItemNames = [
  'Déplacements/transferts',
  'Escaliers',
  'Conduite automobile',
  'Transports en commun',
  'Toilette/habillage',
  'Continence',
  'Repas (y compris courses)',
  'Tâches ménagères',
  'Démarches admin',
  'Cognition',
  'Communication',
];

class LocalAccessScope {
  final String type;
  final String value;

  const LocalAccessScope({required this.type, required this.value});
}

class LocalAppUser {
  final String id;
  final String email;
  final String displayName;
  final LocalUserRole role;
  final String? establishmentId;
  final String? ergoLabel;
  final List<LocalAccessScope> scopes;
  final String profilePhotoUrl;
  /// Base64 data URL of a profile photo captured offline that has not yet
  /// been uploaded. The UI should prefer this over [profilePhotoUrl] while
  /// the sync is pending.
  final String pendingProfilePhotoDataUrl;

  const LocalAppUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.establishmentId,
    this.ergoLabel,
    this.scopes = const [],
    this.profilePhotoUrl = '',
    this.pendingProfilePhotoDataUrl = '',
  });

  LocalAppUser copyWith({
    String? id,
    String? email,
    String? displayName,
    LocalUserRole? role,
    String? establishmentId,
    String? ergoLabel,
    List<LocalAccessScope>? scopes,
    String? profilePhotoUrl,
    String? pendingProfilePhotoDataUrl,
  }) {
    return LocalAppUser(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      establishmentId: establishmentId ?? this.establishmentId,
      ergoLabel: ergoLabel ?? this.ergoLabel,
      scopes: scopes ?? this.scopes,
      profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
      pendingProfilePhotoDataUrl:
          pendingProfilePhotoDataUrl ?? this.pendingProfilePhotoDataUrl,
    );
  }
}

class AdminAccessMember {
  final String email;
  final String displayName;
  final LocalUserRole role;
  final bool selectable;
  final String establishmentLabel;
  final String ergoLabel;
  final bool hasPassword;
  final String generatedPassword;
  final String? createdAt;

  const AdminAccessMember({
    required this.email,
    required this.displayName,
    required this.role,
    required this.selectable,
    required this.establishmentLabel,
    required this.ergoLabel,
    required this.hasPassword,
    required this.generatedPassword,
    this.createdAt,
  });
}

class RetirementFund {
  final String id;
  final String name;
  final String phone;
  final String audience;
  final String requestMethod;
  final String requestDelay;
  final String aidAmount;
  final String therapistNote;
  final String website;
  final String logoUrl;
  final String? lastEditedAt;
  final String? createdAt;

  const RetirementFund({
    required this.id,
    required this.name,
    required this.phone,
    required this.audience,
    required this.requestMethod,
    required this.requestDelay,
    required this.aidAmount,
    required this.therapistNote,
    required this.website,
    required this.logoUrl,
    this.lastEditedAt,
    this.createdAt,
  });

  RetirementFund copyWith({
    String? name,
    String? phone,
    String? audience,
    String? requestMethod,
    String? requestDelay,
    String? aidAmount,
    String? therapistNote,
    String? website,
    String? logoUrl,
    String? lastEditedAt,
    String? createdAt,
  }) {
    return RetirementFund(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      audience: audience ?? this.audience,
      requestMethod: requestMethod ?? this.requestMethod,
      requestDelay: requestDelay ?? this.requestDelay,
      aidAmount: aidAmount ?? this.aidAmount,
      therapistNote: therapistNote ?? this.therapistNote,
      website: website ?? this.website,
      logoUrl: logoUrl ?? this.logoUrl,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class WikiItem {
  final String id;
  final String title;
  final String description;
  final String imageUrl;
  final List<String> tags;
  final String category;
  final String createdAt;
  final String updatedAt;

  /// Base64 data URL of an image captured offline and not yet uploaded.
  /// Always empty for items coming back from the server.
  final String pendingImageDataUrl;

  const WikiItem({
    required this.id,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.tags,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    this.pendingImageDataUrl = '',
  });

  WikiItem copyWith({
    String? title,
    String? description,
    String? imageUrl,
    List<String>? tags,
    String? category,
    String? updatedAt,
    String? pendingImageDataUrl,
  }) {
    return WikiItem(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      tags: tags ?? this.tags,
      category: category ?? this.category,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pendingImageDataUrl: pendingImageDataUrl ?? this.pendingImageDataUrl,
    );
  }
}

class TrustedPerson {
  final String name;
  final String phone;
  final String email;

  TrustedPerson({required this.name, required this.phone, required this.email});

  TrustedPerson copyWith({String? name, String? phone, String? email}) {
    return TrustedPerson(
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
    );
  }
}

class Occupant {
  final String firstName;
  final String lastName;
  final String birthDate;
  final bool apa;
  final bool invalidity;
  final String invalidityTxt;
  final bool homeHelp;
  final String homeHelpTxt;
  final String dependenceTxt;
  final String numeroSecuriteSociale;
  final String caisseRetraitePrincipale;
  final String caissesRetraiteComplementaires;

  /// Per-occupant fiscal reference revenue. When the household has several
  /// occupants, each one has their own RFR value; the household category is
  /// derived from the sum divided by the number of occupants.
  final double? fiscalRevenue;

  /// GIR APA (6 → 1). Rempli uniquement quand `apa == true`. Séparé de
  /// `invalidityTxt` pour ne pas écraser la donnée MDPH si les deux cases
  /// sont cochées.
  final String apaGir;

  const Occupant({
    this.firstName = '',
    this.lastName = '',
    this.birthDate = '',
    this.apa = false,
    this.invalidity = false,
    this.invalidityTxt = '',
    this.homeHelp = false,
    this.homeHelpTxt = '',
    this.dependenceTxt = '',
    this.numeroSecuriteSociale = '',
    this.caisseRetraitePrincipale = '',
    this.caissesRetraiteComplementaires = '',
    this.fiscalRevenue,
    this.apaGir = '',
  });

  factory Occupant.fromJson(Map<String, dynamic> json) => Occupant(
    firstName: json['firstName'] as String? ?? '',
    lastName: json['lastName'] as String? ?? '',
    birthDate: json['birthDate'] as String? ?? '',
    apa: json['apa'] as bool? ?? false,
    invalidity: json['invalidity'] as bool? ?? false,
    invalidityTxt: json['invalidityTxt'] as String? ?? '',
    homeHelp: json['homeHelp'] as bool? ?? false,
    homeHelpTxt: json['homeHelpTxt'] as String? ?? '',
    dependenceTxt: json['dependenceTxt'] as String? ?? '',
    numeroSecuriteSociale: json['numeroSecuriteSociale'] as String? ?? '',
    caisseRetraitePrincipale: json['caisseRetraitePrincipale'] as String? ?? '',
    caissesRetraiteComplementaires: json['caissesRetraiteComplementaires'] as String? ?? '',
    fiscalRevenue: (json['fiscalRevenue'] as num?)?.toDouble(),
    apaGir: json['apaGir'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'firstName': firstName,
    'lastName': lastName,
    'birthDate': birthDate,
    'apa': apa,
    'invalidity': invalidity,
    'invalidityTxt': invalidityTxt,
    'homeHelp': homeHelp,
    'homeHelpTxt': homeHelpTxt,
    'dependenceTxt': dependenceTxt,
    'numeroSecuriteSociale': numeroSecuriteSociale,
    'caisseRetraitePrincipale': caisseRetraitePrincipale,
    'caissesRetraiteComplementaires': caissesRetraiteComplementaires,
    'fiscalRevenue': fiscalRevenue,
    'apaGir': apaGir,
  };

  Occupant copyWith({
    String? firstName,
    String? lastName,
    String? birthDate,
    bool? apa,
    bool? invalidity,
    String? invalidityTxt,
    bool? homeHelp,
    String? homeHelpTxt,
    String? dependenceTxt,
    String? numeroSecuriteSociale,
    String? caisseRetraitePrincipale,
    String? caissesRetraiteComplementaires,
    double? fiscalRevenue,
    bool clearFiscalRevenue = false,
    String? apaGir,
  }) {
    return Occupant(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      birthDate: birthDate ?? this.birthDate,
      apa: apa ?? this.apa,
      invalidity: invalidity ?? this.invalidity,
      invalidityTxt: invalidityTxt ?? this.invalidityTxt,
      homeHelp: homeHelp ?? this.homeHelp,
      homeHelpTxt: homeHelpTxt ?? this.homeHelpTxt,
      dependenceTxt: dependenceTxt ?? this.dependenceTxt,
      numeroSecuriteSociale:
          numeroSecuriteSociale ?? this.numeroSecuriteSociale,
      caisseRetraitePrincipale:
          caisseRetraitePrincipale ?? this.caisseRetraitePrincipale,
      caissesRetraiteComplementaires: caissesRetraiteComplementaires ??
          this.caissesRetraiteComplementaires,
      fiscalRevenue: clearFiscalRevenue
          ? null
          : (fiscalRevenue ?? this.fiscalRevenue),
      apaGir: apaGir ?? this.apaGir,
    );
  }
}

class Patient {
  final String id;
  final String firstName;
  final String lastName;
  final String birthDate;
  final String phone;
  final String email;
  final String address;
  final String city;
  final String zipCode;
  final String familySituation;
  final String incomeCategory;
  final String secondFirstName;
  final String secondLastName;
  final List<Occupant> occupants;
  final int? numberPeople;
  final double? fiscalRevenue;
  final bool apa;
  final bool invalidity;
  final String invalidityTxt;
  final bool homeHelp;
  final String homeHelpTxt;
  final String dependenceTxt;
  final String cityId;
  final String caisseRetraitePrincipale;
  final String caissesRetraiteComplementaires;
  final TrustedPerson trustedPerson;

  Patient({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.birthDate,
    required this.phone,
    required this.email,
    required this.address,
    required this.city,
    required this.zipCode,
    required this.familySituation,
    required this.incomeCategory,
    this.secondFirstName = '',
    this.secondLastName = '',
    this.occupants = const [],
    this.numberPeople,
    this.fiscalRevenue,
    this.apa = false,
    this.invalidity = false,
    this.invalidityTxt = '',
    this.homeHelp = false,
    this.homeHelpTxt = '',
    this.dependenceTxt = '',
    this.cityId = '',
    this.caisseRetraitePrincipale = '',
    this.caissesRetraiteComplementaires = '',
    required this.trustedPerson,
  });

  Patient copyWith({
    String? firstName,
    String? lastName,
    String? birthDate,
    String? phone,
    String? email,
    String? address,
    String? city,
    String? zipCode,
    String? familySituation,
    String? incomeCategory,
    TrustedPerson? trustedPerson,
  }) {
    return Patient(
      id: id,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      birthDate: birthDate ?? this.birthDate,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      address: address ?? this.address,
      city: city ?? this.city,
      zipCode: zipCode ?? this.zipCode,
      familySituation: familySituation ?? this.familySituation,
      incomeCategory: incomeCategory ?? this.incomeCategory,
      trustedPerson: trustedPerson ?? this.trustedPerson,
    );
  }
}

class Housing {
  final HousingType type;
  final int? year;
  final double? surface;
  final HeatingMode heating;
  final String accessibilityNotes;
  final String yearConstruction;
  final String yearHabitation;
  final int? levels;
  final String typology;
  final bool basement;
  final String basementDescription;
  final List<String> basementRooms;
  final bool rdc;
  final String rdcDescription;
  final List<String> rdcRooms;
  final bool floor;
  final String floorDescription;
  final List<String> floorRooms;
  final bool secondFloor;
  final String secondFloorDescription;
  final List<String> secondFloorRooms;
  final bool thirdFloor;
  final String thirdFloorDescription;
  final List<String> thirdFloorRooms;
  final bool garage;
  final bool veranda;
  final bool balcon;
  final bool terrasse;
  final bool jardin;
  final Map<String, bool> heatingDetails;
  final bool voletsRoulantsManuels;
  final String voletsRoulantsManuelsLocalisation;
  final bool voletsRoulantsManuelsEntier;
  final bool voletsRoulantsElectriques;
  final String voletsRoulantsElectriquesLocalisation;
  final bool voletsRoulantsElectriquesEntier;
  final bool voletsPersiennes;
  final String voletsPersiennesLocalisation;
  final bool voletsPersiennesEntier;
  final bool cheminementPortail;
  final bool cheminementPorteGarage;
  final bool cheminementMarches;
  final bool cheminementRampe;
  final bool cheminementMainCourante;
  final bool cheminementRevetementAdapte;
  final bool cheminementEclairageAdapte;
  final String porteGarageId;
  final String portailId;
  final String motorisationPorteGarage;
  final String motorisationPortail;
  final bool easyAccess;
  final String comments;
  final String accessObservation;

  Housing({
    required this.type,
    this.year,
    this.surface,
    required this.heating,
    required this.accessibilityNotes,
    this.yearConstruction = '',
    this.yearHabitation = '',
    this.levels,
    this.typology = '',
    this.basement = false,
    this.basementDescription = '',
    this.basementRooms = const [],
    this.rdc = false,
    this.rdcDescription = '',
    this.rdcRooms = const [],
    this.floor = false,
    this.floorDescription = '',
    this.floorRooms = const [],
    this.secondFloor = false,
    this.secondFloorDescription = '',
    this.secondFloorRooms = const [],
    this.thirdFloor = false,
    this.thirdFloorDescription = '',
    this.thirdFloorRooms = const [],
    this.garage = false,
    this.veranda = false,
    this.balcon = false,
    this.terrasse = false,
    this.jardin = false,
    this.heatingDetails = const {},
    this.voletsRoulantsManuels = false,
    this.voletsRoulantsManuelsLocalisation = '',
    this.voletsRoulantsManuelsEntier = false,
    this.voletsRoulantsElectriques = false,
    this.voletsRoulantsElectriquesLocalisation = '',
    this.voletsRoulantsElectriquesEntier = false,
    this.voletsPersiennes = false,
    this.voletsPersiennesLocalisation = '',
    this.voletsPersiennesEntier = false,
    this.cheminementPortail = false,
    this.cheminementPorteGarage = false,
    this.cheminementMarches = false,
    this.cheminementRampe = false,
    this.cheminementMainCourante = false,
    this.cheminementRevetementAdapte = false,
    this.cheminementEclairageAdapte = false,
    this.porteGarageId = '',
    this.portailId = '',
    this.motorisationPorteGarage = '',
    this.motorisationPortail = '',
    this.easyAccess = true,
    this.comments = '',
    this.accessObservation = '',
  });

  Housing copyWith({
    HousingType? type,
    int? year,
    double? surface,
    HeatingMode? heating,
    String? accessibilityNotes,
  }) {
    return Housing(
      type: type ?? this.type,
      year: year ?? this.year,
      surface: surface ?? this.surface,
      heating: heating ?? this.heating,
      accessibilityNotes: accessibilityNotes ?? this.accessibilityNotes,
    );
  }
}

class FinancialPlan {
  final String id;
  // Simplified for now as per TS
  const FinancialPlan({required this.id});
}

class MedicalContext {
  final String pathology;
  final String followUp;
  final String sensory;
  final String heightCm;
  final String weightKg;

  const MedicalContext({
    this.pathology = '',
    this.followUp = '',
    this.sensory = '',
    this.heightCm = '',
    this.weightKg = '',
  });

  factory MedicalContext.fromJson(Map<String, dynamic> json) => MedicalContext(
    pathology: json['pathology'] as String? ?? '',
    followUp: json['followUp'] as String? ?? '',
    sensory: json['sensory'] as String? ?? '',
    heightCm: json['heightCm'] as String? ?? '',
    weightKg: json['weightKg'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'pathology': pathology,
    'followUp': followUp,
    'sensory': sensory,
    'heightCm': heightCm,
    'weightKg': weightKg,
  };
}

class AutonomyItem {
  final String name;
  final bool checked;

  const AutonomyItem({required this.name, this.checked = false});

  factory AutonomyItem.fromJson(Map<String, dynamic> json) => AutonomyItem(
    name: json['name'] as String? ?? '',
    checked: json['checked'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {'name': name, 'checked': checked};

  AutonomyItem copyWith({bool? checked}) => AutonomyItem(name: name, checked: checked ?? this.checked);
}

class OccupantAutonomy {
  final MedicalContext medical;
  final bool autonomyDone;
  /// État "✓" : cet item est validé autonome (parfait, pas d'aide requise).
  final List<AutonomyItem> autonomy;
  /// État "👥" : cet item nécessite une aide humaine (affiché seulement
  /// quand "Aide à domicile" est coché côté Bénéficiaire > Santé).
  final List<AutonomyItem> humanHelp;
  /// État "!" : cet item est à revoir / pose question (attention
  /// requise). Exclusif avec `autonomy[i]` et `humanHelp[i]` au niveau
  /// de la ligne.
  final List<AutonomyItem> attention;

  const OccupantAutonomy({
    this.medical = const MedicalContext(),
    this.autonomyDone = false,
    this.autonomy = const [],
    this.humanHelp = const [],
    this.attention = const [],
  });

  factory OccupantAutonomy.fromJson(Map<String, dynamic> json) => OccupantAutonomy(
    medical: json['medical'] != null ? MedicalContext.fromJson(json['medical'] as Map<String, dynamic>) : const MedicalContext(),
    autonomyDone: json['autonomyDone'] as bool? ?? false,
    autonomy: (json['autonomy'] as List<dynamic>?)?.map((e) => AutonomyItem.fromJson(e as Map<String, dynamic>)).toList() ?? [],
    humanHelp: (json['humanHelp'] as List<dynamic>?)?.map((e) => AutonomyItem.fromJson(e as Map<String, dynamic>)).toList() ?? [],
    attention: (json['attention'] as List<dynamic>?)?.map((e) => AutonomyItem.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );

  Map<String, dynamic> toJson() => {
    'medical': medical.toJson(),
    'autonomyDone': autonomyDone,
    'autonomy': autonomy.map((e) => e.toJson()).toList(),
    'humanHelp': humanHelp.map((e) => e.toJson()).toList(),
    'attention': attention.map((e) => e.toJson()).toList(),
  };
}

class AutonomyData {
  final bool done;
  final List<AutonomyItem> checklist;
  final List<OccupantAutonomy> occupants;

  const AutonomyData({
    this.done = false,
    this.checklist = const [],
    this.occupants = const [],
  });

  factory AutonomyData.fromJson(Map<String, dynamic> json) => AutonomyData(
    done: json['done'] as bool? ?? false,
    checklist: (json['checklist'] as List<dynamic>?)?.map((e) => AutonomyItem.fromJson(e as Map<String, dynamic>)).toList() ?? [],
    occupants: (json['occupants'] as List<dynamic>?)?.map((e) => OccupantAutonomy.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );

  Map<String, dynamic> toJson() => {
    'done': done,
    'checklist': checklist.map((e) => e.toJson()).toList(),
    'occupants': occupants.map((e) => e.toJson()).toList(),
  };
}

class BathroomInstance {
  final String id;
  final String levelField;
  final String levelLabel;
  final bool sdbBaignoire;
  final double? sdbBaignoireHauteur;
  final bool sdbBacDouche;
  final double? sdbBacDoucheHauteur;
  final bool sdbVasqueSuspendue;
  final double? sdbVasqueSuspendueHauteur;
  final bool sdbVasqueColonne;
  final double? sdbVasqueColonneHauteur;
  final bool sdbMeubleVasque;
  final double? sdbMeubleVasqueHauteur;
  final bool sdbBidet;
  final double? sdbBidetHauteur;
  final bool sdbParoiDouche;
  final double? sdbParoiDoucheHauteur;
  final bool sdbSolGlissant;
  final bool sdbMachineALaver;
  final double? sdbMachineALaverHauteur;
  final bool porteSdbLargeurSuffisante;
  final double? porteSdbDimension;
  final bool porteSdbSensAdapte;

  const BathroomInstance({
    required this.id,
    this.levelField = '',
    this.levelLabel = '',
    this.sdbBaignoire = false,
    this.sdbBaignoireHauteur,
    this.sdbBacDouche = false,
    this.sdbBacDoucheHauteur,
    this.sdbVasqueSuspendue = false,
    this.sdbVasqueSuspendueHauteur,
    this.sdbVasqueColonne = false,
    this.sdbVasqueColonneHauteur,
    this.sdbMeubleVasque = false,
    this.sdbMeubleVasqueHauteur,
    this.sdbBidet = false,
    this.sdbBidetHauteur,
    this.sdbParoiDouche = false,
    this.sdbParoiDoucheHauteur,
    this.sdbSolGlissant = false,
    this.sdbMachineALaver = false,
    this.sdbMachineALaverHauteur,
    this.porteSdbLargeurSuffisante = true,
    this.porteSdbDimension,
    this.porteSdbSensAdapte = true,
  });

  factory BathroomInstance.fromJson(Map<String, dynamic> json) => BathroomInstance(
    id: json['id'] as String? ?? '',
    levelField: json['levelField'] as String? ?? '',
    levelLabel: json['levelLabel'] as String? ?? '',
    sdbBaignoire: json['sdbBaignoire'] as bool? ?? false,
    sdbBaignoireHauteur: (json['sdbBaignoireHauteur'] as num?)?.toDouble(),
    sdbBacDouche: json['sdbBacDouche'] as bool? ?? false,
    sdbBacDoucheHauteur: (json['sdbBacDoucheHauteur'] as num?)?.toDouble(),
    sdbVasqueSuspendue: json['sdbVasqueSuspendue'] as bool? ?? false,
    sdbVasqueSuspendueHauteur: (json['sdbVasqueSuspendueHauteur'] as num?)?.toDouble(),
    sdbVasqueColonne: json['sdbVasqueColonne'] as bool? ?? false,
    sdbVasqueColonneHauteur: (json['sdbVasqueColonneHauteur'] as num?)?.toDouble(),
    sdbMeubleVasque: json['sdbMeubleVasque'] as bool? ?? false,
    sdbMeubleVasqueHauteur: (json['sdbMeubleVasqueHauteur'] as num?)?.toDouble(),
    sdbBidet: json['sdbBidet'] as bool? ?? false,
    sdbBidetHauteur: (json['sdbBidetHauteur'] as num?)?.toDouble(),
    sdbParoiDouche: json['sdbParoiDouche'] as bool? ?? false,
    sdbParoiDoucheHauteur: (json['sdbParoiDoucheHauteur'] as num?)?.toDouble(),
    sdbSolGlissant: json['sdbSolGlissant'] as bool? ?? false,
    sdbMachineALaver: json['sdbMachineALaver'] as bool? ?? false,
    sdbMachineALaverHauteur: (json['sdbMachineALaverHauteur'] as num?)?.toDouble(),
    porteSdbLargeurSuffisante: json['porteSdbLargeurSuffisante'] as bool? ?? true,
    porteSdbDimension: (json['porteSdbDimension'] as num?)?.toDouble(),
    porteSdbSensAdapte: json['porteSdbSensAdapte'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'levelField': levelField, 'levelLabel': levelLabel,
    'sdbBaignoire': sdbBaignoire, 'sdbBaignoireHauteur': sdbBaignoireHauteur,
    'sdbBacDouche': sdbBacDouche, 'sdbBacDoucheHauteur': sdbBacDoucheHauteur,
    'sdbVasqueSuspendue': sdbVasqueSuspendue, 'sdbVasqueSuspendueHauteur': sdbVasqueSuspendueHauteur,
    'sdbVasqueColonne': sdbVasqueColonne, 'sdbVasqueColonneHauteur': sdbVasqueColonneHauteur,
    'sdbMeubleVasque': sdbMeubleVasque, 'sdbMeubleVasqueHauteur': sdbMeubleVasqueHauteur,
    'sdbBidet': sdbBidet, 'sdbBidetHauteur': sdbBidetHauteur,
    'sdbParoiDouche': sdbParoiDouche, 'sdbParoiDoucheHauteur': sdbParoiDoucheHauteur,
    'sdbSolGlissant': sdbSolGlissant,
    'sdbMachineALaver': sdbMachineALaver, 'sdbMachineALaverHauteur': sdbMachineALaverHauteur,
    'porteSdbLargeurSuffisante': porteSdbLargeurSuffisante, 'porteSdbDimension': porteSdbDimension,
    'porteSdbSensAdapte': porteSdbSensAdapte,
  };
}

class WcInstance {
  final String id;
  final String levelField;
  final String levelLabel;
  final bool wcCuvetteBonneHauteur;
  final bool wcCuvetteTropBasse;
  final double? wcCuvetteHauteur;
  final bool wcBarreRelevement;
  final bool porteWcLargeurSuffisante;
  final double? porteWcDimension;
  final bool porteWcSensAdapte;
  final String observationEquipementsUtilisation;

  const WcInstance({
    required this.id,
    this.levelField = '',
    this.levelLabel = '',
    this.wcCuvetteBonneHauteur = true,
    this.wcCuvetteTropBasse = false,
    this.wcCuvetteHauteur,
    this.wcBarreRelevement = false,
    this.porteWcLargeurSuffisante = true,
    this.porteWcDimension,
    this.porteWcSensAdapte = true,
    this.observationEquipementsUtilisation = '',
  });

  factory WcInstance.fromJson(Map<String, dynamic> json) => WcInstance(
    id: json['id'] as String? ?? '',
    levelField: json['levelField'] as String? ?? '',
    levelLabel: json['levelLabel'] as String? ?? '',
    wcCuvetteBonneHauteur: json['wcCuvetteBonneHauteur'] as bool? ?? true,
    wcCuvetteTropBasse: json['wcCuvetteTropBasse'] as bool? ?? false,
    wcCuvetteHauteur: (json['wcCuvetteHauteur'] as num?)?.toDouble(),
    wcBarreRelevement: json['wcBarreRelevement'] as bool? ?? false,
    porteWcLargeurSuffisante: json['porteWcLargeurSuffisante'] as bool? ?? true,
    porteWcDimension: (json['porteWcDimension'] as num?)?.toDouble(),
    porteWcSensAdapte: json['porteWcSensAdapte'] as bool? ?? true,
    observationEquipementsUtilisation: json['observationEquipementsUtilisation'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'levelField': levelField, 'levelLabel': levelLabel,
    'wcCuvetteBonneHauteur': wcCuvetteBonneHauteur, 'wcCuvetteTropBasse': wcCuvetteTropBasse,
    'wcCuvetteHauteur': wcCuvetteHauteur, 'wcBarreRelevement': wcBarreRelevement,
    'porteWcLargeurSuffisante': porteWcLargeurSuffisante, 'porteWcDimension': porteWcDimension,
    'porteWcSensAdapte': porteWcSensAdapte,
    'observationEquipementsUtilisation': observationEquipementsUtilisation,
  };
}

class DiagnosticSanitaire {
  final String dossierId;
  final List<BathroomInstance> sdbInstances;
  final List<WcInstance> wcInstances;

  const DiagnosticSanitaire({
    required this.dossierId,
    this.sdbInstances = const [],
    this.wcInstances = const [],
  });

  factory DiagnosticSanitaire.fromJson(Map<String, dynamic> json) => DiagnosticSanitaire(
    dossierId: json['dossierId'] as String? ?? '',
    sdbInstances: (json['sdbInstances'] as List<dynamic>?)?.map((e) => BathroomInstance.fromJson(e as Map<String, dynamic>)).toList() ?? [],
    wcInstances: (json['wcInstances'] as List<dynamic>?)?.map((e) => WcInstance.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );

  Map<String, dynamic> toJson() => {
    'dossierId': dossierId,
    'sdbInstances': sdbInstances.map((e) => e.toJson()).toList(),
    'wcInstances': wcInstances.map((e) => e.toJson()).toList(),
  };
}

class MesuresAnthropometriques {
  final String dossierId;
  final double? deboutHauteurCoude;
  final double? assisHauteurAssise;
  final double? assisProfondeurGenoux;
  final double? assisHauteurCoudes;
  final String observations;

  const MesuresAnthropometriques({
    required this.dossierId,
    this.deboutHauteurCoude,
    this.assisHauteurAssise,
    this.assisProfondeurGenoux,
    this.assisHauteurCoudes,
    this.observations = '',
  });

  factory MesuresAnthropometriques.fromJson(Map<String, dynamic> json) => MesuresAnthropometriques(
    dossierId: json['dossierId'] as String? ?? '',
    deboutHauteurCoude: (json['deboutHauteurCoude'] as num?)?.toDouble(),
    assisHauteurAssise: (json['assisHauteurAssise'] as num?)?.toDouble(),
    assisProfondeurGenoux: (json['assisProfondeurGenoux'] as num?)?.toDouble(),
    assisHauteurCoudes: (json['assisHauteurCoudes'] as num?)?.toDouble(),
    observations: json['observations'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'dossierId': dossierId,
    'deboutHauteurCoude': deboutHauteurCoude,
    'assisHauteurAssise': assisHauteurAssise,
    'assisProfondeurGenoux': assisProfondeurGenoux,
    'assisHauteurCoudes': assisHauteurCoudes,
    'observations': observations,
  };
}

class ObservationsSynthese {
  final String dossierId;
  final String observationEquipements;
  final String projetSouhaitUsage;
  final String resumePreconisations;

  const ObservationsSynthese({
    required this.dossierId,
    this.observationEquipements = '',
    this.projetSouhaitUsage = '',
    this.resumePreconisations = '',
  });

  factory ObservationsSynthese.fromJson(Map<String, dynamic> json) => ObservationsSynthese(
    dossierId: json['dossierId'] as String? ?? '',
    observationEquipements: json['observationEquipements'] as String? ?? '',
    projetSouhaitUsage: json['projetSouhaitUsage'] as String? ?? '',
    resumePreconisations: json['resumePreconisations'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'dossierId': dossierId,
    'observationEquipements': observationEquipements,
    'projetSouhaitUsage': projetSouhaitUsage,
    'resumePreconisations': resumePreconisations,
  };
}

class VisitRecommendationItem {
  final String id;
  final String wikiItemId;
  final String wikiTitle;
  final String wikiImageUrl;
  final String wikiTag;
  final String customTitle;
  final String note;
  final String createdAt;
  final String updatedAt;

  const VisitRecommendationItem({
    required this.id,
    this.wikiItemId = '',
    this.wikiTitle = '',
    this.wikiImageUrl = '',
    this.wikiTag = '',
    this.customTitle = '',
    this.note = '',
    this.createdAt = '',
    this.updatedAt = '',
  });

  factory VisitRecommendationItem.fromJson(Map<String, dynamic> json) =>
      VisitRecommendationItem(
        id: json['id'] as String? ?? '',
        wikiItemId: json['wikiItemId'] as String? ?? '',
        wikiTitle: json['wikiTitle'] as String? ?? '',
        wikiImageUrl: json['wikiImageUrl'] as String? ?? '',
        wikiTag: json['wikiTag'] as String? ?? '',
        customTitle: json['customTitle'] as String? ?? '',
        note: json['note'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'wikiItemId': wikiItemId,
        'wikiTitle': wikiTitle,
        'wikiImageUrl': wikiImageUrl,
        'wikiTag': wikiTag,
        'customTitle': customTitle,
        'note': note,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  VisitRecommendationItem copyWith({
    String? wikiItemId,
    String? wikiTitle,
    String? wikiImageUrl,
    String? wikiTag,
    String? customTitle,
    String? note,
    String? updatedAt,
  }) {
    return VisitRecommendationItem(
      id: id,
      wikiItemId: wikiItemId ?? this.wikiItemId,
      wikiTitle: wikiTitle ?? this.wikiTitle,
      wikiImageUrl: wikiImageUrl ?? this.wikiImageUrl,
      wikiTag: wikiTag ?? this.wikiTag,
      customTitle: customTitle ?? this.customTitle,
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Displayed title: customTitle overrides wikiTitle.
  String get displayTitle =>
      customTitle.trim().isNotEmpty ? customTitle : wikiTitle;
}

class Dossier {
  final String id;
  final Patient patient;
  final DossierStatus status;
  final String ergoId;
  final String? visitDate;
  final Housing housing;
  final String autonomyNotes;
  final Map<String, FinancialPlan> plans;
  final String createdAt;
  final SyncState syncState;
  final MedicalContext? medicalContext;
  final AutonomyData? autonomy;
  final String compteAnah;
  final String natureAccompagnement;
  final String envoiRapport;
  final String personnesPresentesVisite;

  Dossier({
    required this.id,
    required this.patient,
    required this.status,
    required this.ergoId,
    this.visitDate,
    required this.housing,
    required this.autonomyNotes,
    required this.plans,
    required this.createdAt,
    this.syncState = SyncState.synced,
    this.medicalContext,
    this.autonomy,
    this.compteAnah = '',
    this.natureAccompagnement = '',
    this.envoiRapport = '',
    this.personnesPresentesVisite = '',
  });

  Dossier copyWith({
    Patient? patient,
    DossierStatus? status,
    String? ergoId,
    String? visitDate,
    Housing? housing,
    String? autonomyNotes,
    Map<String, FinancialPlan>? plans,
    SyncState? syncState,
  }) {
    return Dossier(
      id: id,
      patient: patient ?? this.patient,
      status: status ?? this.status,
      ergoId: ergoId ?? this.ergoId,
      visitDate: visitDate ?? this.visitDate,
      housing: housing ?? this.housing,
      autonomyNotes: autonomyNotes ?? this.autonomyNotes,
      plans: plans ?? this.plans,
      createdAt: createdAt,
      syncState: syncState ?? this.syncState,
    );
  }
}

class DocItem {
  final String id;
  final String type; // 'image' | 'pdf' | 'doc'
  final String name;
  final String title;
  final String? url;
  final String date;
  final String? localPath;
  /// Web-only: base64 data URL (`data:<mime>;base64,…`) of the freshly
  /// captured bytes, stored until the sync engine uploads them and
  /// populates [url]. Always null on native targets (which use [localPath]).
  final String? dataUrl;
  final List<String> tags;
  final SyncState syncState;

  /// Position d'une photo dans sa catégorie de l'onglet Photos du
  /// relevé de visite (Logement / Accessibilité / Sanitaires). Plus
  /// petit = plus haut dans la grille, donc occupe le slot 1, 2, … du
  /// PDF généré. `null` pour les documents qui ne sont pas catégorisés
  /// pour le rapport (anciens docs, autres tags). Local-only pour
  /// l'instant — non synchronisé à NocoDB en v1.
  final int? categoryOrder;

  DocItem({
    required this.id,
    required this.type,
    required this.name,
    required this.title,
    this.url,
    required this.date,
    this.localPath,
    this.dataUrl,
    this.tags = const [],
    this.syncState = SyncState.localOnly,
    this.categoryOrder,
  });
}

class Visit {
  final String id;
  final String dossierId;
  final String patientName;
  final String date;
  final String location;
  final String status; // 'Done' | 'Upcoming'

  Visit({
    required this.id,
    required this.dossierId,
    required this.patientName,
    required this.date,
    required this.location,
    required this.status,
  });
}

class SyncOperation {
  final String id;
  final String entityType;
  final String entityLocalId;
  final String operationType;
  final String payloadJson;
  final SyncOperationStatus status;
  final int attemptCount;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  SyncOperation({
    required this.id,
    required this.entityType,
    required this.entityLocalId,
    required this.operationType,
    required this.payloadJson,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
  });
}

extension DossierStatusLabel on DossierStatus {
  String get label {
    switch (this) {
      case DossierStatus.TO_VISIT:
        return 'À visiter';
      case DossierStatus.VISITED:
        return 'Visité';
      case DossierStatus.IN_PROGRESS:
        return 'En cours';
      case DossierStatus.WAITING_QUOTES:
        return 'Attente devis';
      case DossierStatus.QUOTES_RECEIVED:
        return 'Devis reçus';
      case DossierStatus.WAITING_GRANT:
        return 'Attente subvention';
      case DossierStatus.GRANT_VALIDATED:
        return 'Subvention validée';
      case DossierStatus.WORKS_STARTED:
        return 'Travaux démarrés';
      case DossierStatus.WORKS_COMPLETED:
        return 'Travaux terminés';
      case DossierStatus.CLOSED:
        return 'Clôturé';
      case DossierStatus.ARCHIVED:
        return 'Archivé';
    }
  }
}

extension SyncStateLabel on SyncState {
  String get label {
    switch (this) {
      case SyncState.localOnly:
        return 'Local uniquement';
      case SyncState.pendingSync:
        return 'En attente';
      case SyncState.syncing:
        return 'Synchronisation';
      case SyncState.synced:
        return 'Synchronisé';
      case SyncState.syncError:
        return 'Erreur sync';
      case SyncState.conflict:
        return 'Conflit';
    }
  }
}

extension LocalUserRoleLabel on LocalUserRole {
  String get label {
    switch (this) {
      case LocalUserRole.admin:
        return 'Admin';
      case LocalUserRole.ergo:
        return 'Ergo';
    }
  }
}

// ---------------------------------------------------------------------------
// Reference data (served by GET /api/references)
// ---------------------------------------------------------------------------

class CommuneRef {
  final String id;
  final String label;
  final String zipCode;
  final String epciId;
  final String epciLabel;

  const CommuneRef({
    required this.id,
    required this.label,
    this.zipCode = '',
    this.epciId = '',
    this.epciLabel = '',
  });

  factory CommuneRef.fromJson(Map<String, dynamic> json) => CommuneRef(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    zipCode: json['zipCode']?.toString() ?? '',
    epciId: json['epciId']?.toString() ?? '',
    epciLabel: json['epciLabel']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'zipCode': zipCode,
    'epciId': epciId,
    'epciLabel': epciLabel,
  };
}

class BaremeAnahRef {
  final String id;
  final int householdSize;
  final double? revenueTresModeste;
  final double? revenueModeste;
  final double? revenueIntermediaire;
  final double? revenueHaut;
  final int? plafondYear;

  const BaremeAnahRef({
    required this.id,
    required this.householdSize,
    this.revenueTresModeste,
    this.revenueModeste,
    this.revenueIntermediaire,
    this.revenueHaut,
    this.plafondYear,
  });

  factory BaremeAnahRef.fromJson(Map<String, dynamic> json) => BaremeAnahRef(
    id: json['id']?.toString() ?? '',
    householdSize: (json['householdSize'] as num?)?.toInt() ?? 0,
    revenueTresModeste: (json['revenueTresModeste'] as num?)?.toDouble(),
    revenueModeste: (json['revenueModeste'] as num?)?.toDouble(),
    revenueIntermediaire: (json['revenueIntermediaire'] as num?)?.toDouble(),
    revenueHaut: (json['revenueHaut'] as num?)?.toDouble(),
    plafondYear: (json['plafondYear'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'householdSize': householdSize,
    'revenueTresModeste': revenueTresModeste,
    'revenueModeste': revenueModeste,
    'revenueIntermediaire': revenueIntermediaire,
    'revenueHaut': revenueHaut,
    'plafondYear': plafondYear,
  };
}

class EpciRef {
  final String id;
  final String label;

  const EpciRef({required this.id, required this.label});

  factory EpciRef.fromJson(Map<String, dynamic> json) => EpciRef(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
  };
}

class ReferencesPayload {
  final List<CommuneRef> communes;
  final List<BaremeAnahRef> baremesAnah;
  final List<EpciRef> epcis;

  const ReferencesPayload({
    this.communes = const [],
    this.baremesAnah = const [],
    this.epcis = const [],
  });
}
