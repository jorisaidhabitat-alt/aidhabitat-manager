import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';

class RetirementFundsScreen extends StatefulWidget {
  const RetirementFundsScreen({super.key});

  @override
  State<RetirementFundsScreen> createState() => _RetirementFundsScreenState();
}

class _RetirementFundsScreenState extends State<RetirementFundsScreen> {
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
      final funds = await _dataService.fetchRetirementFunds();
      if (!mounted) return;
      setState(() {
        _funds = funds;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Chargement impossible';
      });
    }
  }

  Future<void> _openFund(RetirementFund fund) async {
    final updated = await showDialog<RetirementFund>(
      context: context,
      builder: (context) => _RetirementFundDialog(fund: fund),
    );
    if (updated == null) return;

    try {
      final saved = await _dataService.updateRetirementFund(updated);
      if (!mounted) return;
      setState(() {
        _funds = _funds
            .map((entry) => entry.id == saved.id ? saved : entry)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Fiche enregistrée')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enregistrement impossible')),
      );
    }
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
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Caisses de retraite complémentaires',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ouvre une fiche, ajuste les consignes, puis enregistre.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Klésia, AG2R, Pro BTP...',
                      prefixIcon: const Icon(LucideIcons.search),
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
                  maxCrossAxisExtent: 360,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
                  childAspectRatio: 1.08,
                ),
                itemCount: _filteredFunds.length,
                itemBuilder: (context, index) {
                  final fund = _filteredFunds[index];
                  return InkWell(
                    onTap: () => _openFund(fund),
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 54,
                                height: 54,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEEE7F2),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _initials(fund.name),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF6B567E),
                                  ),
                                ),
                              ),
                              const Spacer(),
                              const Icon(
                                LucideIcons.externalLink,
                                size: 18,
                                color: Color(0xFF64748B),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            fund.name,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            fund.audience,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              height: 1.35,
                            ),
                          ),
                          if (fund.therapistNote.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              fund.therapistNote,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ],
                          const Spacer(),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (fund.phone.isNotEmpty)
                                _Badge(
                                  icon: LucideIcons.phone,
                                  label: fund.phone,
                                ),
                              _Badge(
                                icon: LucideIcons.clock3,
                                label: _formatLastEditedAt(fund.lastEditedAt),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _initials(String value) {
    final parts = value
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'CR';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _formatLastEditedAt(String? value) {
    if (value == null || value.isEmpty) return 'Jamais modifié';
    final date = DateTime.tryParse(value);
    if (date == null) return 'Jamais modifié';
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$day/$month ${date.year} $hour:$minute';
  }
}

class _RetirementFundDialog extends StatefulWidget {
  const _RetirementFundDialog({required this.fund});

  final RetirementFund fund;

  @override
  State<_RetirementFundDialog> createState() => _RetirementFundDialogState();
}

class _RetirementFundDialogState extends State<_RetirementFundDialog> {
  late final TextEditingController _audienceController;
  late final TextEditingController _requestDelayController;
  late final TextEditingController _aidAmountController;
  late final TextEditingController _requestMethodController;
  late final TextEditingController _therapistNoteController;
  late final TextEditingController _websiteController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _audienceController = TextEditingController(text: widget.fund.audience);
    _requestDelayController = TextEditingController(
      text: widget.fund.requestDelay,
    );
    _aidAmountController = TextEditingController(text: widget.fund.aidAmount);
    _requestMethodController = TextEditingController(
      text: widget.fund.requestMethod,
    );
    _therapistNoteController = TextEditingController(
      text: widget.fund.therapistNote,
    );
    _websiteController = TextEditingController(text: widget.fund.website);
    _phoneController = TextEditingController(text: widget.fund.phone);
  }

  @override
  void dispose() {
    _audienceController.dispose();
    _requestDelayController.dispose();
    _aidAmountController.dispose();
    _requestMethodController.dispose();
    _therapistNoteController.dispose();
    _websiteController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.fund.name,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.45,
                  children: [
                    _FieldCard(
                      label: 'Profils éligibles',
                      child: _MultilineField(controller: _audienceController),
                    ),
                    _FieldCard(
                      label: 'Délai',
                      child: _MultilineField(
                        controller: _requestDelayController,
                      ),
                    ),
                    _FieldCard(
                      label: 'Montant possible',
                      child: _MultilineField(controller: _aidAmountController),
                    ),
                    _FieldCard(
                      label: 'Format de demande',
                      child: _MultilineField(
                        controller: _requestMethodController,
                      ),
                    ),
                    _FieldCard(
                      label: 'Site officiel',
                      child: _LineField(
                        controller: _websiteController,
                        trailing: IconButton(
                          onPressed: () => _copy(_websiteController.text),
                          icon: const Icon(LucideIcons.copy, size: 18),
                        ),
                      ),
                    ),
                    _FieldCard(
                      label: 'Téléphone',
                      child: _LineField(
                        controller: _phoneController,
                        trailing: IconButton(
                          onPressed: () => _copy(_phoneController.text),
                          icon: const Icon(LucideIcons.copy, size: 18),
                        ),
                      ),
                    ),
                    _FieldCard(
                      label: 'Note ergothérapeute',
                      fullWidth: true,
                      child: _MultilineField(
                        controller: _therapistNoteController,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Fermer'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        widget.fund.copyWith(
                          audience: _audienceController.text.trim(),
                          requestDelay: _requestDelayController.text.trim(),
                          aidAmount: _aidAmountController.text.trim(),
                          requestMethod: _requestMethodController.text.trim(),
                          therapistNote: _therapistNoteController.text.trim(),
                          website: _websiteController.text.trim(),
                          phone: _phoneController.text.trim(),
                        ),
                      );
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF907CA1),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Enregistrer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copié')));
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.label,
    required this.child,
    this.fullWidth = false,
  });

  final String label;
  final Widget child;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: fullWidth ? const Color(0xFFFFF7D6) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: fullWidth ? const Color(0xFFF2D58B) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _MultilineField extends StatelessWidget {
  const _MultilineField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: null,
      expands: true,
      decoration: const InputDecoration(
        border: InputBorder.none,
        isCollapsed: true,
      ),
    );
  }
}

class _LineField extends StatelessWidget {
  const _LineField({required this.controller, this.trailing});

  final TextEditingController controller;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF475569)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF475569),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
