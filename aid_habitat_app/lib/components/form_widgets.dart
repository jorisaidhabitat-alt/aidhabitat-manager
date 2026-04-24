import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Section header with optional icon
class FormSectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;

  const FormSectionHeader({super.key, required this.title, this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: const Color(0xFF907CA1)),
            const SizedBox(width: 8),
          ],
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF334155),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sub-section navigation chips (Profile / Finance / Santé / Admin)
class FormSubSectionChips extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const FormSubSectionChips({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(labels.length, (i) {
          final selected = i == selectedIndex;
          return GestureDetector(
            onTap: () => onChanged(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF907CA1) : Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  color: selected ? Colors.white : Colors.black87,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Text field with label
class FormTextField extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTapOutside;
  final bool autofocus;
  final bool readOnly;
  final TextInputType? keyboardType;
  final String? suffix;
  final int maxLines;

  /// Couleur du libellé au-dessus du champ (défaut : slate #64748B).
  /// Permet de surcharger ponctuellement — ex. les champs du bloc
  /// Bénéficiaire ont besoin d'un libellé violet même en mode édition.
  final Color? labelColor;

  const FormTextField({
    super.key,
    required this.label,
    this.value = '',
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside,
    this.autofocus = false,
    this.readOnly = false,
    this.keyboardType,
    this.suffix,
    this.maxLines = 1,
    this.labelColor,
  });

  @override
  State<FormTextField> createState() => _FormTextFieldState();
}

class _FormTextFieldState extends State<FormTextField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant FormTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ne jamais écraser le contenu du contrôleur si l'utilisateur a le focus
    // (il est en train de taper) — cela évite des pertes de caractères lors
    // d'un re-rendu déclenché par une sauvegarde asynchrone (ex: "jojo" qui
    // devient "joj").
    if (_focusNode.hasFocus) return;
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: widget.labelColor ?? const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _controller,
          focusNode: _focusNode,
          readOnly: widget.readOnly,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          maxLines: widget.maxLines,
          // fontSize 12 + vertical padding 10 → même hauteur (~34 px)
          // que le pill toggle "Vasque suspendue" (référence visuelle de
          // tous les champs du relevé de visite).
          style: const TextStyle(fontSize: 12),
          // iPadOS Scribble — permet d'écrire directement avec l'Apple
          // Pencil sans taper le champ d'abord. Défaut Flutter = true
          // sur iOS, on le force explicitement pour documenter l'intention.
          // Ne prend effet que sur app native (PWA web : pas supporté).
          stylusHandwritingEnabled: true,
          onFieldSubmitted: widget.onSubmitted,
          onTapOutside: widget.onTapOutside == null
              ? null
              : (_) {
                  _focusNode.unfocus();
                  widget.onTapOutside!();
                },
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF907CA1), width: 1.5),
            ),
            filled: true,
            fillColor: widget.readOnly ? const Color(0xFFF7F7FA) : Colors.white,
            suffixText: widget.suffix,
            suffixStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          ),
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

/// Number field with label and unit
class FormNumberField extends StatefulWidget {
  final String label;
  final double? value;
  final ValueChanged<double?>? onChanged;
  final ValueChanged<double?>? onSubmitted;
  final VoidCallback? onTapOutside;
  final bool autofocus;
  final String? unit;

  /// Couleur du libellé (défaut : slate #64748B). Voir `FormTextField`
  /// pour la motivation — le bloc Bénéficiaire garde un libellé violet
  /// même en mode édition.
  final Color? labelColor;

  const FormNumberField({
    super.key,
    required this.label,
    this.value,
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside,
    this.autofocus = false,
    this.unit,
    this.labelColor,
  });

  @override
  State<FormNumberField> createState() => _FormNumberFieldState();
}

class _FormNumberFieldState extends State<FormNumberField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value != null ? widget.value!.toStringAsFixed(widget.value! == widget.value!.roundToDouble() ? 0 : 1) : '');
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant FormNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final newText = widget.value != null ? widget.value!.toStringAsFixed(widget.value! == widget.value!.roundToDouble() ? 0 : 1) : '';
      if (_controller.text != newText) _controller.text = newText;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  double? _parse(String text) => double.tryParse(text.replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: widget.labelColor ?? const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
          // fontSize 12 → aligné sur la hauteur du pill "Vasque suspendue".
          style: const TextStyle(fontSize: 12),
          // Scribble (Apple Pencil) — voir FormTextField au-dessus.
          stylusHandwritingEnabled: true,
          onFieldSubmitted: widget.onSubmitted == null
              ? null
              : (text) => widget.onSubmitted!(_parse(text)),
          onTapOutside: widget.onTapOutside == null
              ? null
              : (_) {
                  _focusNode.unfocus();
                  widget.onTapOutside!();
                },
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF907CA1), width: 1.5),
            ),
            filled: true,
            fillColor: Colors.white,
            suffixText: widget.unit,
            suffixStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          ),
          onChanged: (text) {
            final parsed = double.tryParse(text.replaceAll(',', '.'));
            widget.onChanged?.call(parsed);
          },
        ),
      ],
    );
  }
}

/// Bouton-pilule à deux états (on/off) pour remplacer les cases à
/// cocher simples dans le relevé de visite. Style : gris clair quand
/// activé, blanc bordé quand désactivé. Même palette que les pills de
/// chauffage / annexes / équipements pour une cohérence visuelle.
class TogglePillButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool expand;

  const TogglePillButton({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    // Violet #907CA1 quand actif (cohérence avec les autres pills du
    // relevé de visite — FormToggleGroup, _Pill, _buildPill). Auparavant
    // le fond actif était gris clair #E2E8F0, ce qui rendait les pièces
    // sélectionnées à l'intérieur des niveaux Accessibilité peu visibles
    // (rapportées comme "cadres gris et blancs vides" par l'utilisateur).
    final pill = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF907CA1) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? const Color(0xFF907CA1)
                : Colors.grey.shade300,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? Colors.white : Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: pill) : pill;
  }
}

/// Ligne compacte "Label (valeur)" + crayon d'édition, utilisée
/// partout où un champ doit se replier visuellement une fois rempli
/// (situation familiale, caisse princ., num sécu, type de logement…).
class CollapsedValueRow extends StatelessWidget {
  final String label;
  final String displayValue;
  final VoidCallback onEdit;
  final TextStyle? labelStyle;

  const CollapsedValueRow({
    super.key,
    required this.label,
    required this.displayValue,
    required this.onEdit,
    this.labelStyle,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveLabelStyle = labelStyle ??
        const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: Color(0xFF64748B),
        );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text.rich(
                TextSpan(
                  style: effectiveLabelStyle,
                  children: [
                    TextSpan(text: label),
                    TextSpan(
                      text: ' ($displayValue)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.edit_outlined,
              size: 14,
              color: Color(0xFF907CA1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Toggle group (binary or multi-option)
class FormToggleGroup extends StatelessWidget {
  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String>? onChanged;

  /// When true, options are laid out in a Row and each one takes an equal
  /// share of the full width (using Expanded). Defaults to false to keep the
  /// original wrap behaviour where each option sizes to its content.
  final bool expand;

  /// Forces a fixed number of columns (equal-width cells, wrapping onto
  /// multiple rows). Takes precedence over [expand] when set. Ex: 2 pour
  /// "Situation familiale" (5 options sur 2 colonnes), 3 pour "Occupation".
  final int? columns;

  const FormToggleGroup({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    this.onChanged,
    this.expand = false,
    this.columns,
  });

  @override
  Widget build(BuildContext context) {
    Widget buildPill(String opt) {
      final isSelected = opt == selected;
      return GestureDetector(
        onTap: () => onChanged?.call(opt),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF907CA1) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF907CA1)
                  : Colors.grey.shade300,
            ),
          ),
          child: Text(
            opt,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black87,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (columns != null && columns! > 0)
          _buildGridRows(options, columns!, buildPill)
        else if (expand || options.length == 2)
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: buildPill(options[i])),
              ],
            ],
          )
        else
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.start,
              spacing: 8,
              runSpacing: 8,
              children: options.map(buildPill).toList(),
            ),
          ),
      ],
    );
  }

  /// Renders [options] into a fixed [columns]-wide grid of equal-width
  /// pills. The last row may have fewer items (remaining cells stay empty
  /// so the present pills keep the same width as the others).
  Widget _buildGridRows(
    List<String> options,
    int columns,
    Widget Function(String) buildPill,
  ) {
    final rows = <Widget>[];
    for (var r = 0; r < options.length; r += columns) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < columns; c++) {
        if (c > 0) rowChildren.add(const SizedBox(width: 8));
        final idx = r + c;
        rowChildren.add(
          Expanded(
            child: idx < options.length
                ? buildPill(options[idx])
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(Row(children: rowChildren));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// Checkbox with label
class FormCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const FormCheckbox({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged?.call(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: value ? const Color(0xFF907CA1) : Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: value
                      ? const Color(0xFF907CA1)
                      : Colors.grey.shade400,
                  width: 1.5,
                ),
              ),
              child: value ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF334155))),
            ),
          ],
        ),
      ),
    );
  }
}

/// Multi-select checkboxes
class FormMultiSelect extends StatelessWidget {
  final String label;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>>? onChanged;

  const FormMultiSelect({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF64748B))),
        const SizedBox(height: 8),
        ...options.map((opt) {
          final isSelected = selected.contains(opt);
          return FormCheckbox(
            label: opt,
            value: isSelected,
            onChanged: (checked) {
              final next = Set<String>.from(selected);
              if (checked) {
                next.add(opt);
              } else {
                next.remove(opt);
              }
              onChanged?.call(next);
            },
          );
        }),
      ],
    );
  }
}

// =============================================================================
// Validation helpers (parity with React: isValidFrenchPhone / isValidEmail)
// =============================================================================

final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

bool isValidEmail(String? value) {
  final normalized = (value ?? '').trim();
  if (normalized.isEmpty) return true;
  return _emailPattern.hasMatch(normalized);
}

bool isValidFrenchPhone(String? value) {
  final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return true;
  if (RegExp(r'^0[1-9]\d{8}$').hasMatch(digits)) return true;
  if (RegExp(r'^33[1-9]\d{8}$').hasMatch(digits)) return true;
  return false;
}

// =============================================================================
// Section (equivalent to React `<Section title>` with a title row + body)
// =============================================================================

class FormSection extends StatelessWidget {
  final Widget title;
  final Widget child;
  final EdgeInsets? padding;

  const FormSection({
    super.key,
    required this.title,
    required this.child,
    this.padding,
  });

  factory FormSection.text(String titleText, {required Widget child}) {
    return FormSection(
      title: Text(
        titleText,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFF334155),
          letterSpacing: 0.2,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Titre sur sa propre ligne (le titre peut contenir une Row complexe
          // avec pills d'occupants, boutons, etc. — on ne superpose rien).
          title,
          // Ligne de séparation pleine largeur sous le titre.
          const SizedBox(height: 8),
          Container(
            height: 1,
            color: const Color(0xFFE2E8F0),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// =============================================================================
// Text field with warning suffix (parity with React `showWarningIcon` prop).
// =============================================================================

class FormTextFieldWithWarning extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final bool showWarning;
  final String? warningText;
  final String? placeholder;

  const FormTextFieldWithWarning({
    super.key,
    required this.label,
    this.value = '',
    this.onChanged,
    this.keyboardType,
    this.showWarning = false,
    this.warningText,
    this.placeholder,
  });

  @override
  State<FormTextFieldWithWarning> createState() =>
      _FormTextFieldWithWarningState();
}

class _FormTextFieldWithWarningState extends State<FormTextFieldWithWarning> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant FormTextFieldWithWarning oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Idem FormTextField : ne pas écraser la frappe en cours.
    if (_focusNode.hasFocus) return;
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: widget.keyboardType,
          // fontSize 12 → aligné sur la hauteur du pill "Vasque suspendue".
          style: const TextStyle(fontSize: 12),
          // Scribble (Apple Pencil) — voir FormTextField au-dessus.
          stylusHandwritingEnabled: true,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: widget.showWarning
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFFCBD5E1),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: Color(0xFF907CA1),
                width: 1.5,
              ),
            ),
            hintText: widget.placeholder,
            hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            suffixIcon: widget.showWarning
                ? Tooltip(
                    message: widget.warningText ?? 'Valeur invalide',
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Color(0xFFF59E0B),
                      size: 18,
                    ),
                  )
                : null,
          ),
          onChanged: widget.onChanged,
        ),
        if (widget.showWarning && widget.warningText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              widget.warningText!,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFFF59E0B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Select dropdown (parity with React `<Select>`)
// =============================================================================

class FormSelectDropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<FormSelectOption<T>> options;
  final ValueChanged<T?>? onChanged;
  final String placeholder;

  const FormSelectDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.onChanged,
    this.placeholder = 'Sélectionner...',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
        ],
        // fontSize 12 + padding vertical 7 → ~34 px de haut, même hauteur
        // que le pill "Vasque suspendue" (référence visuelle du relevé).
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              isDense: true,
              hint: Text(
                placeholder,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              items: options
                  .map(
                    (o) => DropdownMenuItem<T>(
                      value: o.value,
                      child: Text(
                        o.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class FormSelectOption<T> {
  final T value;
  final String label;
  const FormSelectOption({required this.value, required this.label});
}

// =============================================================================
// Multi-select dropdown with checkboxes (parity with React MultiSelectDropdown)
// =============================================================================

class FormMultiSelectDropdown extends StatefulWidget {
  final String label;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>>? onChanged;
  final String placeholder;

  const FormMultiSelectDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    this.onChanged,
    this.placeholder = 'Sélectionner...',
  });

  @override
  State<FormMultiSelectDropdown> createState() =>
      _FormMultiSelectDropdownState();
}

class _FormMultiSelectDropdownState extends State<FormMultiSelectDropdown> {
  bool _open = false;

  String _summarize(List<String> picked) {
    if (picked.isEmpty) return widget.placeholder;
    if (picked.length <= 2) return picked.join(', ');
    return '${picked.take(2).join(', ')} +${picked.length - 2}';
  }

  @override
  Widget build(BuildContext context) {
    final picked = widget.options.where(widget.selected.contains).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        // Padding vertical 10 + fontSize 12 → ~34 px, aligné sur le pill
        // "Vasque suspendue" (référence visuelle du relevé de visite).
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _summarize(picked),
                    style: TextStyle(
                      fontSize: 12,
                      color: picked.isNotEmpty
                          ? const Color(0xFF334155)
                          : const Color(0xFF94A3B8),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                  color: const Color(0xFF94A3B8),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: widget.options.map((opt) {
                  final checked = widget.selected.contains(opt);
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      final next = Set<String>.from(widget.selected);
                      if (checked) {
                        next.remove(opt);
                      } else {
                        next.add(opt);
                      }
                      widget.onChanged?.call(next);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: checked
                                  ? const Color(0xFF907CA1)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: checked
                                ? const Icon(Icons.check,
                                    size: 13, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              opt,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Occupant switcher (tabs-like row shown inside Section titles when 2+ occupants)
// =============================================================================

class OccupantSwitcher extends StatelessWidget {
  final String title;
  final List<String> occupantLabels;
  final int activeIndex;
  final ValueChanged<int>? onChanged;

  const OccupantSwitcher({
    super.key,
    required this.title,
    required this.occupantLabels,
    required this.activeIndex,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF334155),
            letterSpacing: 0.2,
          ),
        ),
        if (occupantLabels.length > 1)
          Wrap(
            spacing: 6,
            children: List.generate(occupantLabels.length, (i) {
              final active = i == activeIndex;
              return GestureDetector(
                onTap: () => onChanged?.call(i),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 72),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? const Color(0xFFE9DFF0)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    occupantLabels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      color: active
                          ? const Color(0xFF554A63)
                          : const Color(0xFF475569),
                    ),
                  ),
                ),
              );
            }),
          ),
      ],
    );
  }
}

/// Save status indicator
class SaveStatusIndicator extends StatelessWidget {
  final bool saving;

  const SaveStatusIndicator({super.key, this.saving = false});

  @override
  Widget build(BuildContext context) {
    // L'enregistrement est automatique et rapide — pas de feedback visuel
    // pour éviter le flash disgracieux du badge "Enregistrement..." qui
    // apparaissait puis disparaissait instantanément.
    return const SizedBox.shrink();
  }
}
