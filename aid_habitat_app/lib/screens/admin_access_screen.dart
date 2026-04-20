import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';

class AdminAccessScreen extends StatefulWidget {
  const AdminAccessScreen({super.key});

  @override
  State<AdminAccessScreen> createState() => _AdminAccessScreenState();
}

class _AdminAccessScreenState extends State<AdminAccessScreen> {
  final DataService _dataService = DataService();

  List<AdminAccessMember> _members = const [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _error;
  String? _copiedEmail;
  String? _resettingEmail;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers({bool refreshing = false}) async {
    if (refreshing) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() => _isLoading = true);
    }

    try {
      final members = await _dataService.fetchAdminAccessMembers();
      if (!mounted) return;
      setState(() {
        _members = members;
        _error = null;
        _isLoading = false;
        _isRefreshing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Impossible de charger les accès';
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  Future<void> _copy(AdminAccessMember member) async {
    await Clipboard.setData(
      ClipboardData(text: '${member.email}\n${member.generatedPassword}'),
    );
    if (!mounted) return;
    setState(() => _copiedEmail = member.email);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _copiedEmail = null);
    });
  }

  Future<void> _reset(AdminAccessMember member) async {
    setState(() => _resettingEmail = member.email);
    try {
      final password = await _dataService.regenerateAccessPassword(
        member.email,
      );
      if (!mounted) return;
      setState(() {
        _members = _members
            .map(
              (entry) => entry.email == member.email
                  ? AdminAccessMember(
                      email: entry.email,
                      displayName: entry.displayName,
                      role: entry.role,
                      selectable: entry.selectable,
                      establishmentLabel: entry.establishmentLabel,
                      ergoLabel: entry.ergoLabel,
                      hasPassword: true,
                      generatedPassword: password ?? entry.generatedPassword,
                      createdAt: entry.createdAt,
                    )
                  : entry,
            )
            .toList(growable: false);
        _resettingEmail = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mot de passe réinitialisé')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _resettingEmail = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Réinitialisation impossible')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = (
      members: _members.length,
      selectable: _members.where((member) => member.selectable).length,
      admins: _members
          .where((member) => member.role == LocalUserRole.admin)
          .length,
      passwords: _members.where((member) => member.hasPassword).length,
    );

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Administration des accès',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Gestion des comptes applicatifs autorisés.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              FilledButton.tonal(
                onPressed: _isRefreshing
                    ? null
                    : () => _loadMembers(refreshing: true),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.refreshCw,
                      size: 16,
                      color: _isRefreshing
                          ? Colors.grey.shade500
                          : const Color(0xFF334155),
                    ),
                    const SizedBox(width: 8),
                    const Text('Actualiser'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _AdminStatCard(
                  label: 'Membres',
                  value: stats.members,
                  icon: LucideIcons.users,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AdminStatCard(
                  label: 'Ergos',
                  value: stats.selectable,
                  icon: LucideIcons.userCog,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AdminStatCard(
                  label: 'Admins',
                  value: stats.admins,
                  icon: LucideIcons.shieldCheck,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AdminStatCard(
                  label: 'Mots de passe',
                  value: stats.passwords,
                  icon: LucideIcons.keyRound,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: Center(
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _members.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final member = _members[index];
                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _RolePill(role: member.role),
                                  if (!member.selectable)
                                    const _MutedPill(
                                      label: 'Non sélectionnable',
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                member.displayName,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                member.email,
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _MetaBlock(
                            label: 'Établissement',
                            value: member.establishmentLabel.isEmpty
                                ? 'Global'
                                : member.establishmentLabel,
                          ),
                        ),
                        Expanded(
                          child: _MetaBlock(
                            label: 'Alias dossier',
                            value: member.ergoLabel.isEmpty
                                ? 'Tous les dossiers'
                                : member.ergoLabel,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: _MetaBlock(
                            label: 'Mot de passe courant',
                            value: member.generatedPassword.isEmpty
                                ? 'Aucun mot de passe généré'
                                : member.generatedPassword,
                            isMonospace: true,
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 140,
                          child: Column(
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _copy(member),
                                icon: const Icon(LucideIcons.copy, size: 16),
                                label: Text(
                                  _copiedEmail == member.email
                                      ? 'Copié'
                                      : 'Copier',
                                ),
                              ),
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: _resettingEmail == member.email
                                    ? null
                                    : () => _reset(member),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF907CA1),
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(
                                  LucideIcons.refreshCw,
                                  size: 16,
                                ),
                                label: Text(
                                  _resettingEmail == member.email
                                      ? 'Patiente...'
                                      : 'Réinitialiser',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AdminStatCard extends StatelessWidget {
  const _AdminStatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: Colors.grey.shade600)),
                const SizedBox(height: 4),
                Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: const Color(0xFF475569)),
          ),
        ],
      ),
    );
  }
}

class _MetaBlock extends StatelessWidget {
  const _MetaBlock({
    required this.label,
    required this.value,
    this.isMonospace = false,
  });

  final String label;
  final String value;
  final bool isMonospace;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontFamily: isMonospace ? 'monospace' : null,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.role});

  final LocalUserRole role;

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == LocalUserRole.admin;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isAdmin ? const Color(0xFF0F172A) : const Color(0xFFD8D0DC),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isAdmin ? 'Admin' : 'Ergo',
        style: TextStyle(
          color: isAdmin ? Colors.white : const Color(0xFF554A63),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MutedPill extends StatelessWidget {
  const _MutedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF475569),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
