import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Données capturées par `CreateBeneficiaryScreen` et passées à
/// `_handleBeneficiaryCreated` côté `main_screen`. On regroupe en
/// `BeneficiaryDraft` plutôt qu'en 7 paramètres positionnels pour
/// réduire la friction des appels et clarifier le contrat.
class BeneficiaryDraft {
  const BeneficiaryDraft({
    required this.firstName,
    required this.lastName,
    required this.natureAccompagnement,
    required this.numberPeople,
    required this.fiscalRevenue,
    required this.address,
    required this.city,
    required this.zipCode,
  });

  final String firstName;
  final String lastName;
  final String natureAccompagnement; // 'ergo' | 'complet' | 'diagnostic'
  final int numberPeople;
  final double fiscalRevenue;
  final String address;
  final String city;
  final String zipCode;
}

/// Formulaire de création d'un nouveau dossier bénéficiaire.
///
/// Demande utilisateur 2026-04-30 : capturer dès la création TOUS les
/// champs admin du bloc « Bénéficiaire » du relevé de visite (nom,
/// prénom, type d'accompagnement, nombre d'occupants, RFR, adresse
/// complète) — l'objectif étant que le dossier ait tout de suite assez
/// de données pour générer un rapport PDF cohérent, même avant qu'un
/// ergo ait ouvert le relevé de visite. Les autres champs (téléphone,
/// situation familiale, dépendances…) restent éditables ensuite dans
/// l'onglet bénéficiaire.
///
/// Marche fully offline : `_dataService.createDossierOffline` persiste
/// en SQLite et enqueue une op `dossier:create` pour la sync.
class CreateBeneficiaryScreen extends StatefulWidget {
  const CreateBeneficiaryScreen({
    super.key,
    required this.onCreated,
    required this.onCancel,
    this.defaultErgoId = '',
  });

  /// Appelé avec un `BeneficiaryDraft` complet quand l'ergo confirme.
  final Future<void> Function(BeneficiaryDraft draft) onCreated;
  final VoidCallback onCancel;
  final String defaultErgoId;

  @override
  State<CreateBeneficiaryScreen> createState() =>
      _CreateBeneficiaryScreenState();
}

class _CreateBeneficiaryScreenState extends State<CreateBeneficiaryScreen> {
  final _lastNameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _zipCodeController = TextEditingController();
  final _fiscalRevenueController = TextEditingController();

  final _lastNameFocus = FocusNode();
  final _scrollController = ScrollController();

  // Type d'accompagnement : 'ergo' | 'complet' | 'diagnostic'.
  // Vide tant que l'ergo n'a pas choisi — la validation l'impose.
  String _natureAccompagnement = '';

  int _numberPeople = 1;

  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastNameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _lastNameController.dispose();
    _firstNameController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _zipCodeController.dispose();
    _fiscalRevenueController.dispose();
    _lastNameFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final lastName = _lastNameController.text.trim();
    final firstName = _firstNameController.text.trim();
    final address = _addressController.text.trim();
    final city = _cityController.text.trim();
    final zipCode = _zipCodeController.text.trim();
    final fiscalRevenueRaw = _fiscalRevenueController.text
        .trim()
        .replaceAll(' ', '')
        .replaceAll(',', '.');
    final fiscalRevenue = double.tryParse(fiscalRevenueRaw);

    // Validation : tous les champs sont obligatoires (demande utilisateur).
    String? validationError;
    if (lastName.isEmpty) {
      validationError = 'Le nom de famille est obligatoire';
    } else if (firstName.isEmpty) {
      validationError = 'Le prénom est obligatoire';
    } else if (_natureAccompagnement.isEmpty) {
      validationError = 'Choisissez le type d\'accompagnement';
    } else if (_numberPeople < 1) {
      validationError = 'Le nombre d\'occupants doit être au moins 1';
    } else if (fiscalRevenue == null || fiscalRevenue <= 0) {
      validationError = 'Renseignez le revenu fiscal de référence';
    } else if (address.isEmpty) {
      validationError = 'L\'adresse est obligatoire';
    } else if (zipCode.isEmpty) {
      validationError = 'Le code postal est obligatoire';
    } else if (city.isEmpty) {
      validationError = 'La ville est obligatoire';
    }
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await widget.onCreated(
        BeneficiaryDraft(
          firstName: firstName,
          lastName: lastName,
          natureAccompagnement: _natureAccompagnement,
          numberPeople: _numberPeople,
          fiscalRevenue: fiscalRevenue!,
          address: address,
          city: city,
          zipCode: zipCode,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = 'Erreur lors de la création : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with back button
          Row(
            children: [
              InkWell(
                onTap: widget.onCancel,
                borderRadius: BorderRadius.circular(50),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    LucideIcons.arrowLeft,
                    size: 20,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              const Text(
                'Nouveau dossier',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Form card (scrollable, since the form a grandi).
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Icon + intro
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEDE8F5),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                LucideIcons.userPlus,
                                color: Color(0xFF8B6FA0),
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Informations du bénéficiaire',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Tous les champs sont obligatoires. '
                                    'Les autres infos s\'éditent dans le dossier.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // Identité ----------------------------------------
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildLabeledField(
                                label: 'Nom *',
                                child: _buildTextField(
                                  controller: _lastNameController,
                                  focusNode: _lastNameFocus,
                                  hint: 'Nom de famille',
                                  capitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildLabeledField(
                                label: 'Prénom *',
                                child: _buildTextField(
                                  controller: _firstNameController,
                                  hint: 'Prénom',
                                  capitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Type d'accompagnement ---------------------------
                        _buildLabeledField(
                          label: 'Type d\'accompagnement *',
                          child: _buildAccompagnementChips(),
                        ),
                        const SizedBox(height: 20),

                        // Nombre d'occupants + RFR ------------------------
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: _buildLabeledField(
                                label: 'Nombre d\'occupants *',
                                child: _buildNumberPeopleStepper(),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: _buildLabeledField(
                                label: 'RFR du foyer * (€)',
                                child: _buildTextField(
                                  controller: _fiscalRevenueController,
                                  hint: 'ex. 18 500',
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  inputFormatters: [
                                    // Chiffres + virgule/point/espace
                                    // (espace = séparateur milliers FR).
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'[0-9 ,.]'),
                                    ),
                                  ],
                                  textInputAction: TextInputAction.next,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Adresse complète --------------------------------
                        _buildLabeledField(
                          label: 'Adresse *',
                          child: _buildTextField(
                            controller: _addressController,
                            hint: 'N° et nom de rue',
                            capitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.next,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: _buildLabeledField(
                                label: 'Code postal *',
                                child: _buildTextField(
                                  controller: _zipCodeController,
                                  hint: 'ex. 69001',
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(5),
                                  ],
                                  textInputAction: TextInputAction.next,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 4,
                              child: _buildLabeledField(
                                label: 'Ville *',
                                child: _buildTextField(
                                  controller: _cityController,
                                  hint: 'Ville',
                                  capitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _handleSubmit(),
                                ),
                              ),
                            ),
                          ],
                        ),

                        // Error
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.alertTriangle,
                                  size: 16,
                                  color: Colors.red.shade600,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Colors.red.shade700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 28),

                        // Submit button
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _isSaving ? null : _handleSubmit,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF8B6FA0),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                            ),
                            child: _isSaving
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Icon(LucideIcons.plus, size: 20),
                                      SizedBox(width: 8),
                                      Text(
                                        'Créer le dossier',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Petits builders pour garder le `build` lisible.
  // ---------------------------------------------------------------------------

  Widget _buildLabeledField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    FocusNode? focusNode,
    TextInputAction textInputAction = TextInputAction.next,
    TextCapitalization capitalization = TextCapitalization.none,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    void Function(String)? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      textCapitalization: capitalization,
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF7F7FA),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  /// 3 chips Diag ergo / MPA ergo / MPA complet — mutuellement
  /// exclusives. Les CLÉS stockées (`diagnostic` / `ergo` / `complet`)
  /// correspondent aux valeurs attendues côté serveur
  /// (`mapBeneficiaryUpdatesToFields` + bloc dossier) — seuls les
  /// libellés affichés ont changé (rename 2026-05-04).
  Widget _buildAccompagnementChips() {
    const options = [
      ('diagnostic', 'Diag ergo'),
      ('ergo', 'MPA ergo'),
      ('complet', 'MPA complet'),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = _natureAccompagnement == opt.$1;
        return InkWell(
          onTap: () => setState(() => _natureAccompagnement = opt.$1),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFFEDE8F5)
                  : const Color(0xFFF7F7FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? const Color(0xFF8B6FA0)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              opt.$2,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(0xFF8B6FA0)
                    : Colors.black87,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Stepper -/+ pour le nombre d'occupants. Bornes : 1..10 (au-dessus
  /// l'ergo doit ouvrir un dossier groupé, ce qui n'est pas géré ici).
  Widget _buildNumberPeopleStepper() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(LucideIcons.minus, size: 18),
            color: const Color(0xFF8B6FA0),
            onPressed: _numberPeople > 1
                ? () => setState(() => _numberPeople--)
                : null,
          ),
          Text(
            '$_numberPeople',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.plus, size: 18),
            color: const Color(0xFF8B6FA0),
            onPressed: _numberPeople < 10
                ? () => setState(() => _numberPeople++)
                : null,
          ),
        ],
      ),
    );
  }
}
