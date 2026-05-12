import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_config.dart';

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
  final http.Client _client = http.Client();

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
      final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
      final response = await _client.get(
        Uri.parse('$base/api/retirement-funds-principal'),
        headers: {
          'X-App-Session': AppConfig.appSessionToken,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final list = (data?['funds'] as List?) ?? const [];
      final funds = list
          .whereType<Map<String, dynamic>>()
          .map(_PrincipalFund.fromJson)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _funds = funds;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _funds.isEmpty ? 'Chargement impossible' : null;
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

  @override
  Widget build(BuildContext context) {
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
