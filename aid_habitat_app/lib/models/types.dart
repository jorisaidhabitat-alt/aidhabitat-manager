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

  const LocalAppUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.establishmentId,
    this.ergoLabel,
    this.scopes = const [],
  });
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

  const WikiItem({
    required this.id,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.tags,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
  });

  WikiItem copyWith({
    String? title,
    String? description,
    String? imageUrl,
    List<String>? tags,
    String? category,
    String? updatedAt,
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
    );
  }
}

class TrustedPerson {
  final String name;
  final String phone;
  final String email;

  TrustedPerson({required this.name, required this.phone, required this.email});
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
    required this.trustedPerson,
  });
}

class Housing {
  final HousingType type;
  final int? year;
  final double? surface;
  final HeatingMode heating;
  final String accessibilityNotes;

  Housing({
    required this.type,
    this.year,
    this.surface,
    required this.heating,
    required this.accessibilityNotes,
  });
}

class FinancialPlan {
  final String id;
  // Simplified for now as per TS
  const FinancialPlan({required this.id});
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
  });
}

class DocItem {
  final String id;
  final String type; // 'image' | 'pdf' | 'doc'
  final String name;
  final String title;
  final String? url;
  final String date;
  final String? localPath;
  final List<String> tags;
  final SyncState syncState;

  DocItem({
    required this.id,
    required this.type,
    required this.name,
    required this.title,
    this.url,
    required this.date,
    this.localPath,
    this.tags = const [],
    this.syncState = SyncState.localOnly,
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
