import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/data_service.dart';

/// ANAH module screen — mirrors the React web `AnahView` feature:
/// - Fetches `/api/anah-status` on mount
/// - Shows availability (green/red badge) + last-check timestamp
/// - Primary button opens MaPrimeAdapt' registration URL in the browser
/// - Secondary button opens the ANAH public site
class AnahScreen extends StatefulWidget {
  const AnahScreen({super.key});

  @override
  State<AnahScreen> createState() => _AnahScreenState();
}

class _AnahScreenState extends State<AnahScreen> {
  final DataService _dataService = DataService();
  bool _loading = true;
  bool _available = false;
  String _registrationUrl = 'https://monprojet.anah.gouv.fr/';
  String _publicUrl = 'https://www.anah.gouv.fr/';
  String _reason = '';
  String _checkedAt = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _dataService.fetchAnahStatus();
      if (!mounted) return;
      setState(() {
        _available = status['available'] as bool? ?? false;
        _registrationUrl = status['registrationUrl']?.toString() ??
            'https://monprojet.anah.gouv.fr/';
        _publicUrl =
            status['publicUrl']?.toString() ?? 'https://www.anah.gouv.fr/';
        _reason = status['reason']?.toString() ?? '';
        _checkedAt = status['checkedAt']?.toString() ?? '';
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible d\'ouvrir $url')),
      );
    }
  }

  String _formatCheckedAt() {
    if (_checkedAt.isEmpty) return '';
    try {
      final dt = DateTime.parse(_checkedAt).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return 'Vérifié à $h:$m';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Anah',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Portail des aides de l\'Agence nationale de l\'habitat — accès au service MaPrimeAdapt\'.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStatusBadge(),
                      const SizedBox(height: 16),
                      const Text(
                        'MaPrimeAdapt\'',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Accédez au portail officiel pour déposer un dossier de demande d\'aide ou suivre son état.',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          height: 1.4,
                        ),
                      ),
                      if (_reason.isNotEmpty && !_available) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFFCA5A5),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                LucideIcons.alertCircle,
                                size: 18,
                                color: Color(0xFFB91C1C),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _reason,
                                  style: const TextStyle(
                                    color: Color(0xFFB91C1C),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _loading
                              ? null
                              : () => _openUrl(_registrationUrl),
                          icon: const Icon(LucideIcons.externalLink, size: 18),
                          label: const Text('Ouvrir MaPrimeAdapt\''),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF907CA1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            textStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _loading ? null : () => _openUrl(_publicUrl),
                          icon: const Icon(LucideIcons.globe, size: 18),
                          label: const Text('Site de l\'ANAH'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF334155),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: const BorderSide(
                              color: Color(0xFFCBD5E1),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatCheckedAt(),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _loading ? null : _check,
                            icon: Icon(
                              LucideIcons.refreshCw,
                              size: 14,
                              color: _loading
                                  ? Colors.grey.shade400
                                  : const Color(0xFF907CA1),
                            ),
                            label: Text(
                              _loading ? 'Vérification...' : 'Vérifier à nouveau',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _loading
                                    ? Colors.grey.shade400
                                    : const Color(0xFF907CA1),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFFB91C1C),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    if (_loading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF907CA1),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Vérification en cours...',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      );
    }

    final bg = _available ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2);
    final fg = _available ? const Color(0xFF047857) : const Color(0xFFB91C1C);
    final icon = _available ? LucideIcons.checkCircle : LucideIcons.xCircle;
    final label = _available ? 'Service disponible' : 'Service indisponible';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
