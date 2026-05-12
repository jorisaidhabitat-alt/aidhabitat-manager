import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_config.dart';
import '../services/nocodb_api_client.dart';

/// Page « Caisses de retraite principales » — référentiel partagé.
///
/// Source : table NocoDB `caisses_de_retraite` (15 entrées) exposée
/// par `GET /api/retirement-funds-principal`. Le serveur set un
/// Cache-Control HTTP de 5 min fresh + 30 min stale-while-revalidate
/// pour réduire la pression sur le Fast Origin Transfer Vercel.
///
/// Design dérivé de `RetirementFundsScreen` (caisses complémentaires)
/// mais simplifié : la table source ne contient que `nom` et
/// `numero_telephone_contact`, donc on retire les champs
/// audience/démarche/montant/site web/logo et on affiche des cartes
/// plus compactes (juste nom + téléphone). Demande utilisateur
/// 2026-05-12.
class RetirementFundsPrincipalScreen extends StatefulWidget {
  const RetirementFundsPrincipalScreen({super.key});

  @override
  State<RetirementFundsPrincipalScreen> createState() =>
      _RetirementFundsPrincipalScreenState();
}

class _RetirementFundsPrincipalScreenState
    extends State<RetirementFundsPrincipalScreen> {
  final TextEditingController _searchController = TextEditingController();
  // Conservé pour le dialog `_NewPrincipalFundDialog` qui fait son
  // POST direct avec ses propres headers.
  final http.Client _client = http.Client();
  final NocodbApiClient _api = NocodbApiClient();

  List<_PrincipalFund> _funds = const [];
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
    _client.close();
    super.dispose();
  }

  Future<void> _loadFunds() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // Utilise `NocodbApiClient.fetchPrincipalRetirementFunds()` qui
      // partage la même logique d'auth (headers + timeout + retry
      // transient guard) que les autres endpoints de l'app. Ma
      // tentative précédente en `http.Client` brut renvoyait 401
      // (probablement `appSessionToken` pas encore set au boot ou
      // headers mal formés).
      final raw = await _api.fetchPrincipalRetirementFunds();
      final funds = raw
          .map((m) => _PrincipalFund(
                id: m['id'] ?? '',
                name: m['name'] ?? '',
                phone: m['phone'] ?? '',
              ))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _funds = funds;
        _isLoading = false;
      });
    } catch (error, stack) {
      // ignore: avoid_print
      print('[retirement_principal] fetch error: $error');
      // ignore: avoid_print
      print(stack);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _funds.isEmpty
            ? 'Chargement impossible — $error'
            : null;
      });
    }
  }

  List<_PrincipalFund> get _filteredFunds {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _funds;
    return _funds
        .where((fund) =>
            '${fund.name} ${fund.phone}'.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _callPhone(String phone) async {
    final sanitized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (sanitized.isEmpty) return;
    final uri = Uri.parse('tel:$sanitized');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Ouvre un dialog de création (nom + téléphone). Demande utilisateur
  /// 2026-05-12 : parité avec Caisses complémentaires.
  Future<void> _createFund() async {
    final created = await showDialog<_PrincipalFund>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => _NewPrincipalFundDialog(
        client: _client,
      ),
    );
    if (created == null || !mounted) return;
    // Re-pull la liste pour avoir la version triée serveur (et garder
    // le cache HTTP cohérent).
    await _loadFunds();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildContent(),
        // Bouton « + Ajouter une caisse de retraite » — parité 1:1 avec
        // la page Caisses complémentaires.
        Positioned(
          right: 24,
          bottom: 24,
          child: FloatingActionButton.extended(
            onPressed: _createFund,
            backgroundColor: const Color(0xFF7C6DAA),
            foregroundColor: Colors.white,
            elevation: 4,
            shape: const StadiumBorder(),
            icon: const Icon(LucideIcons.plus, size: 22),
            label: const Text(
              'Ajouter une caisse de retraite',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête : titre + barre de recherche pill (parité 1:1 avec
          // la page Caisses complémentaires).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'Caisses de retraite principales',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              const SizedBox(width: 24),
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
                            hintText: 'CARSAT, MSA, CNRACL...',
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loadFunds,
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            )
          else if (_filteredFunds.isEmpty)
            const Expanded(
              child: Center(child: Text('Aucune caisse trouvée')),
            )
          else
            Expanded(
              child: GridView.builder(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  // Hauteur réduite (230 → 140) puisqu'on n'affiche
                  // que nom + téléphone (pas de logo / dates / etc.).
                  mainAxisExtent: 140,
                ),
                itemCount: _filteredFunds.length,
                itemBuilder: (context, index) {
                  final fund = _filteredFunds[index];
                  return _PrincipalFundCard(
                    fund: fund,
                    onCallPhone: () => _callPhone(fund.phone),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Carte compacte : nom + chip téléphone tappable.
class _PrincipalFundCard extends StatelessWidget {
  final _PrincipalFund fund;
  final VoidCallback onCallPhone;

  const _PrincipalFundCard({
    required this.fund,
    required this.onCallPhone,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhone = fund.phone.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            fund.name,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
              height: 1.25,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (hasPhone)
            GestureDetector(
              onTap: onCallPhone,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE8F5),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.phone,
                        size: 14, color: Color(0xFF7C6DAA)),
                    const SizedBox(width: 6),
                    Text(
                      fund.phone,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7C6DAA),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            const Text(
              'Téléphone non renseigné',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF94A3B8),
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }
}

class _PrincipalFund {
  final String id;
  final String name;
  final String phone;

  const _PrincipalFund({
    required this.id,
    required this.name,
    required this.phone,
  });

  factory _PrincipalFund.fromJson(Map<String, dynamic> json) =>
      _PrincipalFund(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
      );
}

/// Dialog de création d'une caisse principale. Demande utilisateur
/// 2026-05-12 : bouton « Ajouter une caisse de retraite » sur la page
/// Principales (parité avec Complémentaires). Schema simple : nom
/// (obligatoire) + téléphone — c'est tout ce que la table NocoDB
/// `caisses_de_retraite` stocke.
class _NewPrincipalFundDialog extends StatefulWidget {
  const _NewPrincipalFundDialog({required this.client});

  final http.Client client;

  @override
  State<_NewPrincipalFundDialog> createState() =>
      _NewPrincipalFundDialogState();
}

class _NewPrincipalFundDialogState extends State<_NewPrincipalFundDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Le nom est obligatoire');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
      final response = await widget.client.post(
        Uri.parse('$base/api/retirement-funds-principal'),
        headers: {
          'X-App-Session': AppConfig.appSessionToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'name': name,
          'phone': _phoneController.text.trim(),
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final fundJson = (data['fund'] as Map?)?.cast<String, dynamic>();
      if (fundJson == null) {
        throw Exception('Réponse serveur invalide');
      }
      if (!mounted) return;
      Navigator.of(context).pop(_PrincipalFund.fromJson(fundJson));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Création impossible : $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C6DAA).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.plus,
                      color: Color(0xFF7C6DAA),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Nouvelle caisse de retraite',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 20),
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _PrincipalLabeledField(
                label: 'Nom *',
                controller: _nameController,
                hint: 'ex. CARSAT Bretagne, MSA, CNRACL…',
                autofocus: true,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: 12),
              _PrincipalLabeledField(
                label: 'Téléphone',
                controller: _phoneController,
                hint: 'ex. 39 60',
                enabled: !_isSubmitting,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C6DAA),
                    ),
                    onPressed: _isSubmitting ? null : _submit,
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Créer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrincipalLabeledField extends StatelessWidget {
  const _PrincipalLabeledField({
    required this.label,
    required this.controller,
    this.hint,
    this.autofocus = false,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF7C6DAA),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          autofocus: autofocus,
          enabled: enabled,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF7C6DAA), width: 1.4),
            ),
          ),
        ),
      ],
    );
  }
}
