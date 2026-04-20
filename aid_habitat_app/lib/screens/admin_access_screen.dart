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

  // ---------------------------------------------------------------------
  // Création / modification / suppression / mot de passe explicite
  // (tout est piloté depuis NocoDB via le backend Express).
  // ---------------------------------------------------------------------

  Future<void> _openCreateDialog() async {
    final result = await showDialog<_MemberFormResult>(
      context: context,
      builder: (_) => const _MemberFormDialog(),
    );
    if (result == null) return;
    try {
      await _dataService.createAccessMember(
        email: result.email,
        displayName: result.displayName,
        role: result.role,
        establishmentId: result.establishmentId,
        password: result.password,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Membre créé. Enregistré sur NocoDB.')),
      );
      await _loadMembers(refreshing: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Création impossible : $error')),
      );
    }
  }

  Future<void> _openEditDialog(AdminAccessMember member) async {
    final result = await showDialog<_MemberFormResult>(
      context: context,
      builder: (_) => _MemberFormDialog(initial: member),
    );
    if (result == null) return;
    try {
      await _dataService.updateAccessMember(
        email: member.email,
        displayName: result.displayName,
        establishmentId: result.establishmentId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Membre mis à jour sur NocoDB.')),
      );
      await _loadMembers(refreshing: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Mise à jour impossible : $error')),
      );
    }
  }

  Future<void> _confirmDelete(AdminAccessMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce membre ?'),
        content: Text(
          'Le compte "${member.displayName}" (${member.email}) sera supprimé '
          'de NocoDB et ses identifiants seront révoqués.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dataService.deleteAccessMember(member.email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Membre supprimé.')),
      );
      await _loadMembers(refreshing: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Suppression impossible : $error')),
      );
    }
  }

  Future<void> _openSetPasswordDialog(AdminAccessMember member) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _SetPasswordDialog(email: member.email),
    );
    if (password == null || password.isEmpty) return;
    try {
      final applied = await _dataService.setAccessPassword(
        email: member.email,
        password: password,
      );
      if (!mounted) return;
      setState(() {
        _members = _members
            .map((entry) => entry.email == member.email
                ? AdminAccessMember(
                    email: entry.email,
                    displayName: entry.displayName,
                    role: entry.role,
                    selectable: entry.selectable,
                    establishmentLabel: entry.establishmentLabel,
                    ergoLabel: entry.ergoLabel,
                    hasPassword: true,
                    generatedPassword: applied ?? password,
                    createdAt: entry.createdAt,
                  )
                : entry)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mot de passe défini.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de définir le mot de passe : $error')),
      );
    }
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
              FilledButton.icon(
                onPressed: _openCreateDialog,
                icon: const Icon(LucideIcons.userPlus, size: 16),
                label: const Text('Nouveau membre'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF907CA1),
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
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
                      border: Border.all(color: const Color(0xFFE2E8F0)),
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
                          width: 180,
                          child: Column(
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _copy(member),
                                icon: const Icon(LucideIcons.copy, size: 16),
                                label: Text(
                                  _copiedEmail == member.email
                                      ? 'Copié'
                                      : 'Copier id / mdp',
                                ),
                              ),
                              const SizedBox(height: 6),
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
                                      : 'Réinit. aléatoire',
                                ),
                              ),
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed: () => _openSetPasswordDialog(member),
                                icon: const Icon(LucideIcons.keyRound, size: 16),
                                label: const Text('Définir mdp'),
                              ),
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed: () => _openEditDialog(member),
                                icon: const Icon(LucideIcons.pencil, size: 16),
                                label: const Text('Modifier'),
                              ),
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed: () => _confirmDelete(member),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red.shade700,
                                ),
                                icon: const Icon(LucideIcons.trash2, size: 16),
                                label: const Text('Supprimer'),
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
        border: Border.all(color: const Color(0xFFE2E8F0)),
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
            border: Border.all(color: const Color(0xFFE2E8F0)),
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

class _MemberFormResult {
  final String email;
  final String displayName;
  final LocalUserRole role;
  final String? establishmentId;
  final String? password;
  const _MemberFormResult({
    required this.email,
    required this.displayName,
    required this.role,
    this.establishmentId,
    this.password,
  });
}

class _MemberFormDialog extends StatefulWidget {
  final AdminAccessMember? initial;
  const _MemberFormDialog({this.initial});

  @override
  State<_MemberFormDialog> createState() => _MemberFormDialogState();
}

class _MemberFormDialogState extends State<_MemberFormDialog> {
  late final TextEditingController _emailCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _establishmentCtrl;
  late final TextEditingController _passwordCtrl;
  LocalUserRole _role = LocalUserRole.ergo;
  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _emailCtrl = TextEditingController(text: init?.email ?? '');
    _nameCtrl = TextEditingController(text: init?.displayName ?? '');
    _establishmentCtrl = TextEditingController(text: init?.establishmentLabel ?? '');
    _passwordCtrl = TextEditingController();
    _role = init?.role ?? LocalUserRole.ergo;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _establishmentCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Modifier le membre' : 'Nouveau membre'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _emailCtrl,
              enabled: !_isEdit,
              decoration: InputDecoration(
                labelText: 'Email',
                helperText: _isEdit ? 'Non modifiable (clé unique)' : null,
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Nom affiché'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _establishmentCtrl,
              decoration: const InputDecoration(
                labelText: 'ID Établissement (optionnel)',
                helperText: 'Laisser vide si global',
              ),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<LocalUserRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Rôle'),
                items: const [
                  DropdownMenuItem(value: LocalUserRole.ergo, child: Text('Ergothérapeute')),
                  DropdownMenuItem(value: LocalUserRole.admin, child: Text('Administrateur')),
                ],
                onChanged: (value) => setState(() => _role = value ?? LocalUserRole.ergo),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(
                  labelText: 'Mot de passe (optionnel)',
                  helperText: 'Laisser vide pour génération aléatoire',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF907CA1)),
          onPressed: () {
            final email = _emailCtrl.text.trim().toLowerCase();
            final name = _nameCtrl.text.trim();
            if (!_isEdit && (email.isEmpty || !email.contains('@') || name.isEmpty)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Email et nom requis.')),
              );
              return;
            }
            if (_isEdit && name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nom requis.')),
              );
              return;
            }
            Navigator.pop(
              context,
              _MemberFormResult(
                email: _isEdit ? widget.initial!.email : email,
                displayName: name,
                role: _role,
                establishmentId: _establishmentCtrl.text.trim().isEmpty
                    ? null
                    : _establishmentCtrl.text.trim(),
                password: _passwordCtrl.text.trim().isEmpty
                    ? null
                    : _passwordCtrl.text.trim(),
              ),
            );
          },
          child: Text(_isEdit ? 'Enregistrer' : 'Créer'),
        ),
      ],
    );
  }
}

class _SetPasswordDialog extends StatefulWidget {
  final String email;
  const _SetPasswordDialog({required this.email});

  @override
  State<_SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends State<_SetPasswordDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _obscure = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Définir un mot de passe'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.email,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              obscureText: _obscure,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Nouveau mot de passe',
                helperText: '8 caractères minimum',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF907CA1)),
          onPressed: () {
            final value = _ctrl.text.trim();
            if (value.length < 8) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Mot de passe trop court (min 8).')),
              );
              return;
            }
            Navigator.pop(context, value);
          },
          child: const Text('Définir'),
        ),
      ],
    );
  }
}

