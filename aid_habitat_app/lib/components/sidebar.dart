import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import 'account_dialog.dart';
import 'cached_remote_image.dart';

class Sidebar extends StatefulWidget {
  final String currentView;
  final Function(String) onNavigate;
  final LocalAppUser currentUser;
  final Future<void> Function() onLogout;
  final int pendingSyncCount;
  final bool isSyncing;
  final VoidCallback? onSyncTap;

  const Sidebar({
    super.key,
    required this.currentView,
    required this.onNavigate,
    required this.currentUser,
    required this.onLogout,
    this.pendingSyncCount = 0,
    this.isSyncing = false,
    this.onSyncTap,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  List<Map<String, dynamic>> get _menuItems => [
    {
      'id': 'dashboard',
      'label': 'Accueil',
      'icon': LucideIcons.home,
    },
    {'id': 'dossiers', 'label': 'Dossiers', 'icon': LucideIcons.folderOpen},
    {'id': 'wiki', 'label': 'Bibliothèque', 'icon': LucideIcons.bookOpen},
    {'id': 'precos', 'label': 'Caisses', 'icon': LucideIcons.heart},
    {'id': 'anah', 'label': 'Anah', 'icon': LucideIcons.coins},
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
// border-slate-100
      ),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height,
          ),
          child: IntrinsicHeight(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
          // Logo Area — click to return to dashboard
          Padding(
            padding: const EdgeInsets.only(top: 32.0),
            child: Tooltip(
              message: 'Accueil',
              preferBelow: false,
              margin: const EdgeInsets.only(left: 80),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              child: InkWell(
                onTap: () => widget.onNavigate('dashboard'),
                borderRadius: BorderRadius.circular(50),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFCBD5E1), // slate-300
                      width: 1.5,
                    ),
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


          // Profile / Bottom — single avatar button that opens the account
          // dialog (profile photo, password, logout, admin access).
          Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: Tooltip(
              message:
                  "${widget.currentUser.displayName} • ${widget.currentUser.role.label}",
              preferBelow: false,
              margin: const EdgeInsets.only(left: 80),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              child: InkWell(
                onTap: _openAccountDialog,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 48,
                  height: 48,
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
                  clipBehavior: Clip.antiAlias,
                  child: (widget.currentUser.profilePhotoUrl.isNotEmpty ||
                          widget.currentUser
                              .pendingProfilePhotoDataUrl.isNotEmpty)
                      ? CachedRemoteImage(
                          url: widget.currentUser.profilePhotoUrl,
                          pendingDataUrl: widget
                              .currentUser.pendingProfilePhotoDataUrl,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          errorWidget: Center(
                            child: Text(
                              _initials(widget.currentUser.displayName),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )
                      : Center(
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
            ),
          ),
        ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAccountDialog() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => AccountDialog(
        currentUser: widget.currentUser,
        onLogout: widget.onLogout,
        onOpenAdmin: widget.currentUser.role == LocalUserRole.admin
            ? () => widget.onNavigate('admin')
            : null,
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
