import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/cached_remote_image.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../services/data_service.dart';
import '../services/media_cache_service.dart';
import '../services/retirement_funds_repository.dart';

class RetirementFundsScreen extends StatefulWidget {
  const RetirementFundsScreen({super.key});

  @override
  State<RetirementFundsScreen> createState() => _RetirementFundsScreenState();
}

class _RetirementFundsScreenState extends State<RetirementFundsScreen> {
  final RetirementFundsRepository _repository = RetirementFundsRepository();
  final DataService _dataService = DataService();
  final TextEditingController _searchController = TextEditingController();

  List<RetirementFund> _funds = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFunds();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFunds() async {
    try {
      // Load from local SQLite cache immediately.
      final cached = await _repository.fetchAllFunds();
      if (mounted) {
        setState(() {
          _funds = cached;
          _isLoading = false;
          _error = null;
        });
      }

      // Refresh from remote in background.
      final didRefresh = await _dataService.refreshRetirementFundsFromRemote();
      if (!didRefresh || !mounted) return;

      final refreshed = await _repository.fetchAllFunds();
      if (!mounted) return;
      setState(() => _funds = refreshed);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _funds.isEmpty ? 'Chargement impossible' : null;
      });
    }
  }

  Future<void> _refreshFromRemote() async {
    final updated = await _dataService.refreshRetirementFundsFromRemote();
    if (!updated || !mounted) return;
    final funds = await _dataService.fetchRetirementFunds();
    if (!mounted) return;
    setState(() {
      _funds = funds;
    });
    // Warm the logo cache so caisses stay visible offline.
    MediaCacheService.instance.prefetchAll(
      funds.map((f) => f.logoUrl).where((u) => u.trim().isNotEmpty),
    );
  }

  Future<void> _openFund(RetirementFund fund) async {
    await showSoftDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => _RetirementFundDialog(
        fund: fund,
        onSaved: (saved) {
          if (!mounted) return;
          setState(() {
            _funds = _funds
                .map((entry) => entry.id == saved.id ? saved : entry)
                .toList(growable: false);
          });
        },
      ),
    );
  }

  List<RetirementFund> get _filteredFunds {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _funds;
    return _funds
        .where((fund) {
          final haystack =
              '${fund.name} ${fund.audience} ${fund.requestMethod} ${fund.therapistNote}'
                  .toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête : titre + sous-titre directs (pas de carte blanche),
          // champ de recherche en pill blanc à droite — parité 1:1 avec
          // l'en-tête Bibliothèque.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'Caisses de retraite complémentaires',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Style aligné avec la barre de recherche de
              // "Mes dossiers" : pastille pill (radius 999), fond blanc,
              // contour gris #E2E8F0, icône search + champ sans
              // bordures internes.
              SizedBox(
                width: 320,
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.search,
                          size: 18, color: Color(0xFF64748B)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText: 'Klésia, AG2R, Pro BTP...',
                            hintStyle:
                                TextStyle(color: Color(0xFF94A3B8)),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isCollapsed: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: Center(
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            )
          else if (_filteredFunds.isEmpty)
            const Expanded(child: Center(child: Text('Aucun organisme trouvé')))
          else
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  // Hauteur réduite (310 → 230) pour éviter l'espace blanc
                  // entre les infos (nom · date · téléphone) et le bas de
                  // la carte — demande utilisateur. 230 = 120 (hero logo) +
                  // 12 padding + ~20 nom + 8 + ~14 date + 14 + ~30 chip
                  // téléphone + 12 padding = cartes bien remplies.
                  mainAxisExtent: 230,
                ),
                itemCount: _filteredFunds.length,
                itemBuilder: (context, index) {
                  final fund = _filteredFunds[index];
                  return _FundCard(
                    fund: fund,
                    dateLabel: _buildDateLabel(fund),
                    onTap: () => _openFund(fund),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Returns a date label preferring `lastEditedAt` ("Modifié le…"), falling
  /// back to `createdAt` ("Ajoutée le…"). If neither is available, returns
  /// "Nouvelle caisse".
  String _buildDateLabel(RetirementFund fund) {
    final edited = fund.lastEditedAt;
    if (edited != null && edited.isNotEmpty) {
      final formatted = _formatDate(edited);
      if (formatted != null) return 'Modifiée le $formatted';
    }
    final created = fund.createdAt;
    if (created != null && created.isNotEmpty) {
      final formatted = _formatDate(created);
      if (formatted != null) return 'Ajoutée le $formatted';
    }
    return 'Nouvelle caisse';
  }

  String? _formatDate(String iso) {
    final date = DateTime.tryParse(iso);
    if (date == null) return null;
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }
}

// ---------------------------------------------------------------------------
// Helpers shared between list + dialog
// ---------------------------------------------------------------------------

String _formatLastEditedAtHeader(String? value) {
  if (value == null || value.isEmpty) return 'Jamais modifié';
  final date = DateTime.tryParse(value);
  if (date == null) return 'Jamais modifié';
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return 'Mis à jour le $day/$month/${date.year} à $hour:$minute';
}

enum _SaveState { idle, saving, saved, error }

// ---------------------------------------------------------------------------
// Grid card — logo-first, modern hero layout
// ---------------------------------------------------------------------------

class _FundCard extends StatefulWidget {
  final RetirementFund fund;
  final String dateLabel;
  final VoidCallback onTap;

  const _FundCard({
    required this.fund,
    required this.dateLabel,
    required this.onTap,
  });

  @override
  State<_FundCard> createState() => _FundCardState();
}

class _FundCardState extends State<_FundCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fund = widget.fund;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: _hover
            ? (Matrix4.identity()..translateByDouble(0.0, -3.0, 0.0, 1.0))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: const Color(0xFF7C6DAA).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- Hero logo ----------
              // Fond blanc uni — pas d'overlay. Le numéro de téléphone
              // est désormais affiché en pastille SOUS la date (demande
              // utilisateur), comme un widget propre dans la zone texte.
              Container(
                height: 120,
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.all(14),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _FundLogoImage(fund: fund),
                  ),
                ),
              ),

              // ---------- Text content ----------
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fund.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Info : date en UPPERCASE — "Modifiée le …" si
                      // une édition existe, "Ajoutée le …" sinon.
                      Text(
                        widget.dateLabel.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF94A3B8),
                          letterSpacing: 1.2,
                        ),
                      ),
                      // Widget : pastille téléphone SOUS la date — fond
                      // gris très clair, icône + numéro en slate-700.
                      if (fund.phone.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(50),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  LucideIcons.phone,
                                  size: 12,
                                  color: Color(0xFF475569),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    fund.phone,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _HeroChip retiré : remplacé par une pastille noire semi-transparente
// superposée sur le hero (parité visuelle avec les cartes Bibliothèque).

class _RetirementFundDialog extends StatefulWidget {
  const _RetirementFundDialog({required this.fund, required this.onSaved});

  final RetirementFund fund;
  final ValueChanged<RetirementFund> onSaved;

  @override
  State<_RetirementFundDialog> createState() => _RetirementFundDialogState();
}

class _RetirementFundDialogState extends State<_RetirementFundDialog> {
  final DataService _dataService = DataService();

  late final TextEditingController _nameController;
  late final TextEditingController _audienceController;
  late final TextEditingController _requestDelayController;
  late final TextEditingController _aidAmountController;
  late final TextEditingController _requestMethodController;
  late final TextEditingController _therapistNoteController;
  late final TextEditingController _websiteController;
  late final TextEditingController _phoneController;

  late RetirementFund _currentFund;
  _SaveState _saveState = _SaveState.idle;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _currentFund = widget.fund;
    _nameController = TextEditingController(text: widget.fund.name);
    _audienceController = TextEditingController(text: widget.fund.audience);
    _requestDelayController =
        TextEditingController(text: widget.fund.requestDelay);
    _aidAmountController = TextEditingController(text: widget.fund.aidAmount);
    _requestMethodController =
        TextEditingController(text: widget.fund.requestMethod);
    _therapistNoteController =
        TextEditingController(text: widget.fund.therapistNote);
    _websiteController = TextEditingController(text: widget.fund.website);
    _phoneController = TextEditingController(text: widget.fund.phone);

    for (final c in [
      _nameController,
      _audienceController,
      _requestDelayController,
      _aidAmountController,
      _requestMethodController,
      _therapistNoteController,
      _websiteController,
      _phoneController,
    ]) {
      c.addListener(_markDirty);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _audienceController,
      _requestDelayController,
      _aidAmountController,
      _requestMethodController,
      _therapistNoteController,
      _websiteController,
      _phoneController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (_saveState != _SaveState.idle) {
      setState(() => _saveState = _SaveState.idle);
    } else {
      // still rebuild so "Appeler" / "Ouvrir le site" links update with value
      setState(() {});
    }
  }

  Future<void> _save() async {
    setState(() => _saveState = _SaveState.saving);
    final draft = _currentFund.copyWith(
      name: _nameController.text.trim(),
      audience: _audienceController.text,
      requestDelay: _requestDelayController.text,
      aidAmount: _aidAmountController.text,
      requestMethod: _requestMethodController.text,
      therapistNote: _therapistNoteController.text,
      website: _websiteController.text.trim(),
      phone: _phoneController.text.trim(),
    );
    try {
      final saved = await _dataService.updateRetirementFund(draft);
      if (!mounted) return;
      setState(() {
        _currentFund = saved;
        _saveState = _SaveState.saved;
        _isEditing = false; // leave edit mode after successful save
      });
      widget.onSaved(saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveState = _SaveState.error);
    }
  }

  /// Renders a textarea (edit mode) or a read-only text block (view mode).
  Widget _buildTextField(TextEditingController controller) {
    if (_isEditing) return _Textarea(controller: controller);
    final text = controller.text.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text.isEmpty ? '—' : text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color:
              text.isEmpty ? Colors.grey.shade400 : const Color(0xFF0F172A),
          height: 1.45,
        ),
      ),
    );
  }

  void _cancelEdit() {
    // Reset controllers to the current persisted values
    _nameController.text = _currentFund.name;
    _audienceController.text = _currentFund.audience;
    _requestDelayController.text = _currentFund.requestDelay;
    _aidAmountController.text = _currentFund.aidAmount;
    _requestMethodController.text = _currentFund.requestMethod;
    _therapistNoteController.text = _currentFund.therapistNote;
    _websiteController.text = _currentFund.website;
    _phoneController.text = _currentFund.phone;
    setState(() {
      _isEditing = false;
      _saveState = _SaveState.idle;
    });
  }

  Future<void> _launchTel() async {
    final raw = _phoneController.text.trim();
    if (raw.isEmpty) return;
    final normalized = raw.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri.parse('tel:$normalized');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _launchWebsite() async {
    final raw = _websiteController.text.trim();
    if (raw.isEmpty) return;
    final href =
        raw.startsWith('http://') || raw.startsWith('https://') ? raw : 'https://$raw';
    final uri = Uri.parse(href);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Layout 2026-04-29 :
    //  • `maxHeight` réduit (820 → 680) pour tenir sur iPad paysage
    //    (~736 pt utilisable après insetPadding) sans être coupée en haut.
    //  • `insetPadding` symétrique vertical (24 pt) → la popup respire et
    //    reste centrée verticalement à coup sûr.
    //  • `mainAxisSize: MainAxisSize.min` + `Flexible(loose)` (au lieu de
    //    `Expanded`) → la Column se rétrécit à la hauteur intrinsèque de
    //    son contenu. Avant, Expanded forçait le SingleChildScrollView à
    //    remplir toute la hauteur disponible, d'où le grand espace blanc
    //    sous les boutons quand le contenu était plus court que 820 pt.
    //    Si le contenu dépasse `maxHeight`, le SingleChildScrollView
    //    scrolle normalement (clamp implicite par la ConstrainedBox).
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: Colors.white,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // Sans clipBehavior, le dégradé du header (Container plein) déborde
      // en rectangle par-dessus les coins arrondis en haut. `antiAlias`
      // applique la `shape` à TOUS les enfants → le header reprend la
      // courbure des coins du bas (demande utilisateur 2026-04-29).
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // ---- HEADER -----------------------------------------------------------

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8F4FB), Color(0xFFFDFCFE)],
        ),
      ),
      // Padding du header (demande utilisateur 2026-04-29 : « ajoute
      // du padding entre le contenu et le bord du haut » → top relevé
      // de 10 → 20 pt pour décoller le logo/texte du bord supérieur de
      // la popup). Bottom 12 conservé : pas de gap avec le body
      // (le body a son propre padding de 28 pt).
      padding: const EdgeInsets.fromLTRB(16, 20, 12, 12),
      // UNE SEULE Row : logo + nom/date + boutons d'action — tous
      // alignés au centre vertical de la rangée pour respecter la
      // demande « met les boutons editer et croix à la même hauteur
      // que les autres éléments de la partie haute ».
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Logo carré 56×84 pt (60 plus tôt → encore -8 pt pour
          // raccourcir la rangée). Toujours lisible — l'image
          // intérieure a son propre BoxFit.contain qui s'adapte.
          Container(
            height: 56,
            width: 84,
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _FundLogoImage(fund: _currentFund),
          ),
          const SizedBox(width: 12),
          // Bloc texte : nom au-dessus, date en dessous.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Nom — fontSize 22 (lisible, 1-2 lignes possibles).
                // TextField conservé en mode édition.
                _isEditing
                    ? TextField(
                        controller: _nameController,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                        decoration: const InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                                color: Color(0xFF7C6DAA), width: 2),
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide:
                                BorderSide(color: Colors.transparent),
                          ),
                        ),
                      )
                    : Text(
                        _currentFund.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                const SizedBox(height: 4),
                // Last edited chip — aligné à gauche.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.clock3,
                          size: 11, color: Colors.grey.shade500),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _formatLastEditedAtHeader(
                              _currentFund.lastEditedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Boutons d'action — fusionnés dans la même Row que le logo
          // et le texte, vertically centered (demande utilisateur
          // 2026-04-29). En vue lecture : crayon. En édition : annuler
          // + sauvegarder. Toujours suivis du bouton fermer.
          if (_isEditing) ...[
            _IconCircleButton(
              icon: LucideIcons.undo2,
              onPressed:
                  _saveState == _SaveState.saving ? null : _cancelEdit,
              tooltip: 'Annuler',
            ),
            const SizedBox(width: 6),
            _SaveStateIndicator(state: _saveState, onSave: _save),
          ] else
            _IconCircleButton(
              icon: LucideIcons.pencil,
              onPressed: () => setState(() => _isEditing = true),
              tooltip: 'Modifier',
              filled: true,
            ),
          const SizedBox(width: 6),
          _IconCircleButton(
            icon: LucideIcons.x,
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Fermer',
          ),
        ],
      ),
    );
  }

  // ---- BODY -------------------------------------------------------------

  Widget _buildBody() {
    return SingleChildScrollView(
      // Padding symétrique haut/bas (28 pt partout) — demande utilisateur
      // 2026-04-29 : « ajoute du padding en haut à la même distance que
      // en bas ». Avant : top=20, bottom=28 → la 1ère section collait
      // visuellement au header.
      padding: const EdgeInsets.all(28),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final twoColumns = constraints.maxWidth > 680;
          final cardWidth = twoColumns
              ? (constraints.maxWidth - 24) / 2
              : constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Section: À propos ----
              _SectionTitle(
                icon: LucideIcons.info,
                label: 'À propos',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 24,
                runSpacing: 18,
                children: [
                  SizedBox(
                    width: cardWidth,
                    child: _FieldRow(
                      icon: LucideIcons.users,
                      label: 'Profils éligibles',
                      child: _buildTextField(_audienceController),
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _FieldRow(
                      icon: LucideIcons.clock3,
                      label: 'Délai de traitement',
                      child: _buildTextField(_requestDelayController),
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _FieldRow(
                      icon: LucideIcons.wallet,
                      label: 'Montant possible',
                      child: _buildTextField(_aidAmountController),
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _FieldRow(
                      icon: LucideIcons.fileText,
                      label: 'Format de demande',
                      child: _buildTextField(_requestMethodController),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),

              // ---- Section: Note ergothérapeute ----
              _TherapistNoteCard(
                controller: _therapistNoteController,
                readOnly: !_isEditing,
              ),
              const SizedBox(height: 28),

              // ---- Section: Contact ----
              _SectionTitle(
                icon: LucideIcons.phoneCall,
                label: 'Contact',
              ),
              const SizedBox(height: 14),
              if (_isEditing)
                // Edit mode: inline inputs so the user can change phone/website
                Wrap(
                  spacing: 24,
                  runSpacing: 18,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _FieldRow(
                        icon: LucideIcons.phone,
                        label: 'Téléphone',
                        child: _Input(controller: _phoneController),
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _FieldRow(
                        icon: LucideIcons.globe,
                        label: 'Site officiel',
                        child: _Input(controller: _websiteController),
                      ),
                    ),
                  ],
                )
              else
                // View mode: two big action buttons, nothing else
                Row(
                  children: [
                    Expanded(
                      child: _ContactActionButton(
                        icon: LucideIcons.phone,
                        label: 'Appeler',
                        subtitle: _phoneController.text.trim().isEmpty
                            ? 'Aucun numéro renseigné'
                            : _phoneController.text.trim(),
                        enabled: _phoneController.text.trim().isNotEmpty,
                        onTap: _launchTel,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _ContactActionButton(
                        icon: LucideIcons.globe,
                        label: 'Ouvrir le site',
                        subtitle: _websiteController.text.trim().isEmpty
                            ? 'Aucun site renseigné'
                            : _websiteController.text.trim(),
                        enabled: _websiteController.text.trim().isNotEmpty,
                        onTap: _launchWebsite,
                      ),
                    ),
                  ],
                ),
              if (_saveState == _SaveState.saved ||
                  _saveState == _SaveState.error) ...[
                const SizedBox(height: 20),
                _buildSaveStatus(),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildSaveStatus() {
    if (_saveState == _SaveState.saved) {
      return const Text(
        'ENREGISTRÉ',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
          color: Color(0xFF059669),
        ),
      );
    }
    return const Text(
      "ERREUR D'ENREGISTREMENT",
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
        color: Color(0xFFDC2626),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section title — used to group fields inside the modernized dialog
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xFFEDE8F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: const Color(0xFF7C6DAA)),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFFE2E8F0),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Field row — inline label + field (no card wrapper, used in redesigned dialog)
// ---------------------------------------------------------------------------

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.icon,
    required this.label,
    required this.child,
  });

  final IconData icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: const Color(0xFF94A3B8)),
            const SizedBox(width: 6),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
                color: Color(0xFF64748B),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Therapist note full-width yellow card
// ---------------------------------------------------------------------------

class _TherapistNoteCard extends StatelessWidget {
  const _TherapistNoteCard({
    required this.controller,
    this.readOnly = false,
  });
  final TextEditingController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final text = controller.text.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7D6),
        border: Border.all(color: const Color(0xFFE6D7A8)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                LucideIcons.stickyNote,
                size: 12,
                color: Color(0xFF8A6A00),
              ),
              SizedBox(width: 6),
              Text(
                'NOTE ERGOTHÉRAPEUTE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: Color(0xFF8A6A00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (readOnly)
            Text(
              text.isEmpty
                  ? 'Aucune note pour cette caisse.'
                  : text,
              style: TextStyle(
                fontSize: 13,
                color: text.isEmpty
                    ? const Color(0xFFA88A3F)
                    : const Color(0xFF5C4300),
                fontWeight: FontWeight.w600,
                fontStyle: text.isEmpty ? FontStyle.italic : FontStyle.normal,
                height: 1.35,
              ),
            )
          else
            TextField(
              controller: controller,
              maxLines: null,
              minLines: 2,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF5C4300),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: 'Consignes internes, astuces, points de vigilance…',
                hintStyle: TextStyle(color: Color(0xFFA88A3F), fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Text inputs — styled like React with slate-50 fill + bold text
// ---------------------------------------------------------------------------

class _Textarea extends StatelessWidget {
  const _Textarea({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: null,
      minLines: 2,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0F172A),
        height: 1.35,
      ),
      decoration: InputDecoration(
        filled: true,
        fillColor: const Color(0xFFF7F7FA),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0F172A),
      ),
      decoration: InputDecoration(
        filled: true,
        fillColor: const Color(0xFFF7F7FA),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Save state indicator — idle (purple save button), saving/saved/error
// ---------------------------------------------------------------------------

class _SaveStateIndicator extends StatelessWidget {
  const _SaveStateIndicator({required this.state, required this.onSave});

  final _SaveState state;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    if (state == _SaveState.idle) {
      return Tooltip(
        message: 'Enregistrer',
        child: Material(
          color: const Color(0xFF7C6DAA),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onSave,
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(LucideIcons.save, size: 18, color: Colors.white),
            ),
          ),
        ),
      );
    }

    final config = switch (state) {
      _SaveState.saving => const _IndicatorConfig(
          bg: Color(0xFFFFFBEB),
          border: Color(0xFFFDE68A),
          fg: Color(0xFFB45309),
          label: 'Enregistrement en cours',
        ),
      _SaveState.saved => const _IndicatorConfig(
          bg: Color(0xFFECFDF5),
          border: Color(0xFFA7F3D0),
          fg: Color(0xFF047857),
          label: 'Enregistrement terminé',
        ),
      _SaveState.error => const _IndicatorConfig(
          bg: Color(0xFFFEF2F2),
          border: Color(0xFFFCA5A5),
          fg: Color(0xFFB91C1C),
          label: 'Erreur de sauvegarde',
        ),
      _ => const _IndicatorConfig(
          bg: Colors.white,
          border: Color(0xFFE2E8F0),
          fg: Color(0xFF64748B),
          label: '',
        ),
    };

    Widget icon;
    switch (state) {
      case _SaveState.saving:
        icon = SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: config.fg),
        );
        break;
      case _SaveState.saved:
        icon = Icon(LucideIcons.checkCheck, size: 18, color: config.fg);
        break;
      case _SaveState.error:
        icon = Icon(LucideIcons.x, size: 18, color: config.fg);
        break;
      case _SaveState.idle:
        icon = const SizedBox.shrink();
    }

    return Tooltip(
      message: config.label,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: config.bg,
          shape: BoxShape.circle,
          border: Border.all(color: config.border),
        ),
        child: Center(child: icon),
      ),
    );
  }
}

class _IndicatorConfig {
  const _IndicatorConfig({
    required this.bg,
    required this.border,
    required this.fg,
    required this.label,
  });
  final Color bg;
  final Color border;
  final Color fg;
  final String label;
}

/// Large tap target shown in view mode for Phone / Website — replaces the
/// inline inputs so the dialog reads as a fiche, not a form.
class _ContactActionButton extends StatelessWidget {
  const _ContactActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool enabled;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: enabled ? const Color(0xFF7C6DAA) : const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.arrowUpRight,
                    size: 16, color: Colors.white.withValues(alpha: 0.9)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconCircleButton extends StatelessWidget {
  const _IconCircleButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  /// When true, uses the primary purple brand color (used for primary actions
  /// like entering edit mode).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final Color bg;
    final Color fg;
    if (filled) {
      bg = const Color(0xFF7C6DAA);
      fg = Colors.white;
    } else {
      bg = const Color(0xFFF1F5F9);
      fg = const Color(0xFF475569);
    }
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 18, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders a retirement fund logo using the on-disk media cache. Uses the
/// exact URL returned by the API (no extension cascade) so the logo keeps
/// working offline once seen. Falls back to the fund's initials on failure.
class _FundLogoImage extends StatelessWidget {
  const _FundLogoImage({required this.fund});
  final RetirementFund fund;

  @override
  Widget build(BuildContext context) {
    final fallback = _FundInitials(name: fund.name);
    if (fund.logoUrl.trim().isEmpty) return fallback;
    return CachedRemoteImage(
      key: ValueKey(fund.logoUrl),
      url: fund.logoUrl,
      fit: BoxFit.contain,
      placeholder: fallback,
      errorWidget: fallback,
    );
  }
}

class _FundInitials extends StatelessWidget {
  const _FundInitials({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
            ? parts.first.substring(0, 1).toUpperCase()
            : '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFFEEE7F2),
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: Color(0xFF6B567E),
        ),
      ),
    );
  }
}
