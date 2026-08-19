import 'package:flutter/material.dart';

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

  static const List<String> _types = ['Bug', 'Difficulté', 'Idée'];

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
        currentUser: widget.currentUser,
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
    final panelWidth = isCompact ? 330.0 : 390.0;
    final availableHeight = MediaQuery.sizeOf(context).height - 36;
    final panelHeight = availableHeight.clamp(300.0, isCompact ? 340.0 : 350.0);

    return SizedBox(
      width: panelWidth,
      height: panelHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomRight,
        children: [
          IgnorePointer(
            ignoring: !_open,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              offset: _open ? Offset.zero : const Offset(1.08, 0),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: _open ? 1 : 0,
                child: _buildPanel(context, panelWidth),
              ),
            ),
          ),
          IgnorePointer(
            ignoring: _open,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              offset: _open ? const Offset(1, 0) : Offset.zero,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _open ? 0 : 1,
                child: _buildCollapsed(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsed() {
    return SizedBox(
      width: 132,
      height: 40,
      child: Material(
        key: const ValueKey('collapsed'),
        color: const Color(0xFFF4EDF8),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(left: Radius.circular(999)),
          side: BorderSide(color: Color(0xFFE7DDEE)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            FeedbackActivityService.instance.track('Ouverture du signalement');
            setState(() => _open = true);
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.feedback_outlined,
                size: 17,
                color: kBrandDarkPurple,
              ),
              const SizedBox(width: 7),
              const Text(
                'Signaler',
                style: TextStyle(
                  color: kBrandDarkPurple,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, double width) {
    return Material(
      key: const ValueKey('panel'),
      color: Colors.white,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
      elevation: 0,
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(24),
          ),
          border: Border.all(color: const Color(0xFFE7DDEE)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x220E1116),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
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
                      fontSize: 14,
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
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _messageController,
                focusNode: _messageFocus,
                enabled: !_sending,
                keyboardType: TextInputType.multiline,
                expands: true,
                minLines: null,
                maxLines: null,
                textInputAction: TextInputAction.newline,
                stylusHandwritingEnabled: true,
                autocorrect: true,
                enableSuggestions: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: 'Décris le bug, la difficulté ou l’idée…',
                  filled: true,
                  fillColor: const Color(0xFFFDFCFB),
                  hintStyle: const TextStyle(fontSize: 14),
                  contentPadding: const EdgeInsets.all(14),
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
                    borderSide: const BorderSide(
                      color: kBrandPurple,
                      width: 1.3,
                    ),
                  ),
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
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
            FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                backgroundColor: kBrandPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Envoyer'),
            ),
          ],
        ),
      ),
    );
  }
}
