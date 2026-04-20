import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'account_dialog.dart';
import '../models/types.dart';

class Sidebar extends StatefulWidget {
  final String currentView;
  final Function(String) onNavigate;
  final LocalAppUser currentUser;
  final Future<void> Function() onLogout;

  const Sidebar({
    super.key,
    required this.currentView,
    required this.onNavigate,
    required this.currentUser,
    required this.onLogout,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  List<Map<String, dynamic>> get _menuItems => [
    {
      'id': 'dashboard',
      'label': 'Accueil',
      'icon': LucideIcons.layoutDashboard,
    },
    {'id': 'dossiers', 'label': 'Dossiers', 'icon': LucideIcons.folderOpen},
    {'id': 'wiki', 'label': 'Wiki', 'icon': LucideIcons.bookOpen},
    {'id': 'precos', 'label': 'Caisses', 'icon': LucideIcons.heart},
    if (widget.currentUser.role == LocalUserRole.admin)
      {'id': 'admin', 'label': 'Admin', 'icon': LucideIcons.shieldCheck},
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96, // w-24
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(32), // rounded-r-[2rem]
          bottomRight: Radius.circular(32),
        ),
        border: Border(
          right: BorderSide(color: Color(0xFFF1F5F9)),
        ), // border-slate-100
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Logo Area
          Padding(
            padding: const EdgeInsets.only(top: 32.0),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black, width: 2),
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Navigation
          Column(
            mainAxisSize: MainAxisSize.min,
            children: _menuItems.map((item) {
              final bool isActive =
                  widget.currentView == item['id'] ||
                  (widget.currentView == 'visit' && item['id'] == 'dossiers');

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0),
                child: Tooltip(
                  message: item['label'],
                  preferBelow: false,
                  margin: const EdgeInsets.only(left: 80),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: const TextStyle(color: Colors.white, fontSize: 12),
                  child: InkWell(
                    onTap: () => widget.onNavigate(item['id']),
                    borderRadius: BorderRadius.circular(50),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFFC5D2D8)
                            : const Color(0xFFC5D2D8).withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        item['icon'],
                        size: 22,
                        color: isActive ? Colors.black : Colors.grey.shade400,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          // Profile / Bottom
          Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: Column(
              children: [
                Tooltip(
                  message:
                      "${widget.currentUser.displayName} • ${widget.currentUser.role.label}",
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF907CA1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        _initials(widget.currentUser.displayName),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Tooltip(
                  message: 'Compte local',
                  child: InkWell(
                    onTap: () async {
                      final didChangePassword = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) =>
                            AccountDialog(currentUser: widget.currentUser),
                      );
                      if (didChangePassword != true || !context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Mot de passe local mis à jour'),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(50),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Icon(
                        LucideIcons.settings,
                        size: 18,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Tooltip(
                  message: 'Se déconnecter',
                  child: InkWell(
                    onTap: () => widget.onLogout(),
                    borderRadius: BorderRadius.circular(50),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Icon(
                        LucideIcons.logOut,
                        size: 18,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _initials(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'AH';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }
}
