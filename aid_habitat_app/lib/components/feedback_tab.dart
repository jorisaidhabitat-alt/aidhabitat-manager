import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/feedback_activity_service.dart';
import '../services/feedback_service.dart';
import 'brand_colors.dart';

class FeedbackTab extends StatefulWidget {
  const FeedbackTab({
    super.key,
    required this.currentUser,
    required this.contextSnapshot,
  });

  final LocalAppUser currentUser;
  final FeedbackContextSnapshot Function() contextSnapshot;

  @override
  State<FeedbackTab> createState() => _FeedbackTabState();
}

class _FeedbackTabState extends State<FeedbackTab> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocus = FocusNode();
  String _type = 'Bug';
  bool _open = false;
  bool _sending = false;
  String? _status;
  bool _statusIsError = false;

  static const List<String> _types = [
    'Bug',
    'Difficulté terrain',
    'Idée / amélioration',
  ];

  @override
  void dispose() {
    _messageController.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _messageController.text.trim();
    if (message.length < 3) {
      setState(() {
        _status = 'Ajoute quelques mots pour expliquer le retour.';
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _sending = true;
      _status = null;
      _statusIsError = false;
    });

    try {
      FeedbackActivityService.instance.track('Signalement envoyé : $_type');
      await FeedbackService.instance.sendFeedback(
        type: _type,
        message: message,
        context: widget.contextSnapshot(),
      );
      if (!mounted) return;
      setState(() {
        _messageController.clear();
        _sending = false;
        _status = 'Signalement envoyé.';
        _statusIsError = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      setState(() => _open = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _status = error.toString().replaceFirst('Exception: ', '');
        _statusIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 760;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: _open ? (isCompact ? 320 : 380) : 132,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_open ? 24 : 999),
        border: Border.all(color: const Color(0xFFE7DDEE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x220E1116),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_open ? 24 : 999),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: _open ? _buildPanel(context) : _buildCollapsed(),
        ),
      ),
    );
  }

  Widget _buildCollapsed() {
    return Material(
      key: const ValueKey('collapsed'),
      color: const Color(0xFFF4EDF8),
      child: InkWell(
        onTap: () {
          FeedbackActivityService.instance.track('Ouverture du signalement');
          setState(() => _open = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _messageFocus.requestFocus();
          });
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.feedback_outlined, size: 18, color: kBrandDarkPurple),
              SizedBox(width: 8),
              Text(
                'Signaler',
                style: TextStyle(
                  color: kBrandDarkPurple,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final snapshot = widget.contextSnapshot();
    return Material(
      key: const ValueKey('panel'),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.feedback_outlined,
                  size: 19,
                  color: kBrandPurple,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Signaler',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF17131D),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: _sending
                      ? null
                      : () => setState(() => _open = false),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in _types)
                  ChoiceChip(
                    label: Text(type),
                    selected: _type == type,
                    onSelected: _sending
                        ? null
                        : (_) {
                            setState(() => _type = type);
                          },
                    selectedColor: const Color(0xFFF0E4F4),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _type == type
                          ? kBrandDarkPurple
                          : const Color(0xFF64748B),
                    ),
                    side: BorderSide(
                      color: _type == type
                          ? const Color(0xFFD8C2E3)
                          : const Color(0xFFE5E7EB),
                    ),
                    showCheckmark: false,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _messageController,
              focusNode: _messageFocus,
              enabled: !_sending,
              minLines: 4,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Décris le bug, la difficulté ou l’idée…',
                filled: true,
                fillColor: const Color(0xFFFDFCFB),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFFE7DDEE)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFFE7DDEE)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: kBrandPurple, width: 1.3),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _ContextPreview(snapshot: snapshot),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(
                _status!,
                style: TextStyle(
                  color: _statusIsError
                      ? const Color(0xFFB91C1C)
                      : const Color(0xFF047857),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                backgroundColor: kBrandPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(LucideIcons.send, size: 16),
              label: Text(_sending ? 'Envoi…' : 'Envoyer à Aid’Habitat'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextPreview extends StatelessWidget {
  const _ContextPreview({required this.snapshot});

  final FeedbackContextSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final parts = [
      snapshot.page,
      if (snapshot.dossierName.trim().isNotEmpty) snapshot.dossierName,
      if (snapshot.section.trim().isNotEmpty) snapshot.section,
    ].where((part) => part.trim().isNotEmpty).join(' • ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6F3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        parts.isEmpty ? 'Contexte détecté automatiquement' : parts,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF64748B),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
