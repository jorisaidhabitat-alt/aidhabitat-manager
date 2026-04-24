import 'package:flutter/material.dart';

import '../models/types.dart';
import 'form_widgets.dart';

/// Multi-occupant editor — React parity with the occupant switcher in
/// `DossierView` / `VisitReportView`.
///
/// Behaviour:
///  - A toggle at the top picks the household size (1 to 5).
///  - When size > 1, circular numbered buttons switch between occupants.
///  - The fields for the *active* occupant are rendered; editing any field
///    emits a new `List<Occupant>` upstream via [onChanged].
///
/// The parent is responsible for persisting `numberPeople` and
/// `occupants_json` via [DossierRepository.updatePatientFields].
class OccupantsEditor extends StatefulWidget {
  final int numberPeople;
  final List<Occupant> occupants;
  final void Function(int numberPeople, List<Occupant> occupants) onChanged;

  const OccupantsEditor({
    super.key,
    required this.numberPeople,
    required this.occupants,
    required this.onChanged,
  });

  @override
  State<OccupantsEditor> createState() => _OccupantsEditorState();
}

class _OccupantsEditorState extends State<OccupantsEditor> {
  static const int _kMaxOccupants = 5;

  int _activeIndex = 0;

  int get _effectiveSize {
    final n = widget.numberPeople;
    if (n <= 0) return 1;
    if (n > _kMaxOccupants) return _kMaxOccupants;
    return n;
  }

  List<Occupant> _ensureSize(int n) {
    final list = List<Occupant>.from(widget.occupants);
    while (list.length < n) {
      list.add(const Occupant());
    }
    if (list.length > n) {
      return list.sublist(0, n);
    }
    return list;
  }

  void _setSize(int n) {
    if (n < 1) n = 1;
    if (n > _kMaxOccupants) n = _kMaxOccupants;
    final next = _ensureSize(n);
    setState(() {
      if (_activeIndex >= n) _activeIndex = n - 1;
    });
    widget.onChanged(n, next);
  }

  void _updateActive(Occupant Function(Occupant current) transform) {
    final list = _ensureSize(_effectiveSize);
    final idx = _activeIndex.clamp(0, list.length - 1);
    list[idx] = transform(list[idx]);
    widget.onChanged(_effectiveSize, list);
  }

  @override
  Widget build(BuildContext context) {
    final size = _effectiveSize;
    final list = _ensureSize(size);
    final active = list[_activeIndex.clamp(0, size - 1)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormToggleGroup(
          label: "Nombre d'occupants",
          options: const ['1', '2', '3', '4', '5'],
          selected: size.toString(),
          onChanged: (v) {
            final parsed = int.tryParse(v);
            if (parsed != null) _setSize(parsed);
          },
        ),
        if (size > 1) ...[
          const SizedBox(height: 16),
          _OccupantSwitcher(
            count: size,
            activeIndex: _activeIndex.clamp(0, size - 1),
            onSelect: (i) => setState(() => _activeIndex = i),
          ),
        ],
        const SizedBox(height: 16),
        _buildFieldsFor(active),
      ],
    );
  }

  Widget _buildFieldsFor(Occupant o) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: FormTextField(
                label: 'Prénom',
                value: o.firstName,
                onChanged: (v) => _updateActive((c) => c.copyWith(firstName: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FormTextField(
                label: 'Nom',
                value: o.lastName,
                onChanged: (v) => _updateActive((c) => c.copyWith(lastName: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Date de naissance',
          value: o.birthDate,
          onChanged: (v) => _updateActive((c) => c.copyWith(birthDate: v)),
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Bénéficiaire APA',
          options: const ['Oui', 'Non'],
          selected: o.apa ? 'Oui' : 'Non',
          onChanged: (v) =>
              _updateActive((c) => c.copyWith(apa: v == 'Oui')),
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Reconnaissance invalidité',
          options: const ['Oui', 'Non'],
          selected: o.invalidity ? 'Oui' : 'Non',
          onChanged: (v) =>
              _updateActive((c) => c.copyWith(invalidity: v == 'Oui')),
        ),
        if (o.invalidity) ...[
          const SizedBox(height: 8),
          FormTextField(
            label: 'Précisions invalidité',
            value: o.invalidityTxt,
            onChanged: (v) => _updateActive((c) => c.copyWith(invalidityTxt: v)),
          ),
        ],
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Aide à domicile',
          options: const ['Oui', 'Non'],
          selected: o.homeHelp ? 'Oui' : 'Non',
          onChanged: (v) =>
              _updateActive((c) => c.copyWith(homeHelp: v == 'Oui')),
        ),
        if (o.homeHelp) ...[
          const SizedBox(height: 8),
          FormTextField(
            label: 'Précisions aide à domicile',
            value: o.homeHelpTxt,
            onChanged: (v) => _updateActive((c) => c.copyWith(homeHelpTxt: v)),
          ),
        ],
        const SizedBox(height: 12),
        FormTextField(
          label: 'Dépendance particulière',
          value: o.dependenceTxt,
          onChanged: (v) => _updateActive((c) => c.copyWith(dependenceTxt: v)),
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'N° Sécurité sociale',
          value: o.numeroSecuriteSociale,
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              _updateActive((c) => c.copyWith(numeroSecuriteSociale: v)),
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Caisse retraite principale',
          value: o.caisseRetraitePrincipale,
          onChanged: (v) =>
              _updateActive((c) => c.copyWith(caisseRetraitePrincipale: v)),
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Caisses complémentaires',
          value: o.caissesRetraiteComplementaires,
          onChanged: (v) => _updateActive(
            (c) => c.copyWith(caissesRetraiteComplementaires: v),
          ),
        ),
      ],
    );
  }
}

class _OccupantSwitcher extends StatelessWidget {
  final int count;
  final int activeIndex;
  final void Function(int) onSelect;

  const _OccupantSwitcher({
    required this.count,
    required this.activeIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(count, (i) {
        final selected = i == activeIndex;
        return InkWell(
          onTap: () => onSelect(i),
          customBorder: const CircleBorder(),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? const Color(0xFF7C6DAA) : Colors.white,
              border: Border.all(
                color: selected
                    ? const Color(0xFF7C6DAA)
                    : const Color(0xFFCBD5E1),
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '${i + 1}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: selected ? Colors.white : const Color(0xFF334155),
              ),
            ),
          ),
        );
      }),
    );
  }
}
