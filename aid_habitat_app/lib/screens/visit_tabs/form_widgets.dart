import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _kPurple = Color(0xFF907CA1);
const _kDarkPurple = Color(0xFF554a63);
const _kTeal = Color(0xFF597E8D);
const _kLightGray = Color(0xFFD8D0DC);

class VSectionHeader extends StatelessWidget {
  final String title;
  const VSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: _kDarkPurple,
        ),
      ),
    );
  }
}

class VSubSectionBar extends StatelessWidget {
  final List<String> sections;
  final int selected;
  final ValueChanged<int> onChanged;

  const VSubSectionBar({
    super.key,
    required this.sections,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: List.generate(sections.length, (i) {
          final active = i == selected;
          return GestureDetector(
            onTap: () => onChanged(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: active ? _kPurple : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active ? _kPurple : _kLightGray,
                ),
              ),
              child: Text(
                sections[i],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : _kDarkPurple,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class VTextField extends StatefulWidget {
  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final String? suffix;

  const VTextField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.keyboardType,
    this.suffix,
  });

  @override
  State<VTextField> createState() => _VTextFieldState();
}

class _VTextFieldState extends State<VTextField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(VTextField old) {
    super.didUpdateWidget(old);
    if (old.initialValue != widget.initialValue &&
        widget.initialValue != _ctrl.text) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _ctrl,
        keyboardType: widget.keyboardType,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: const TextStyle(fontSize: 12, color: _kDarkPurple),
          suffixText: widget.suffix,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _kLightGray),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _kTeal),
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

class VNumberField extends StatefulWidget {
  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final String? suffix;

  const VNumberField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.suffix,
  });

  @override
  State<VNumberField> createState() => _VNumberFieldState();
}

class _VNumberFieldState extends State<VNumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(VNumberField old) {
    super.didUpdateWidget(old);
    if (old.initialValue != widget.initialValue &&
        widget.initialValue != _ctrl.text) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
        ],
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: const TextStyle(fontSize: 12, color: _kDarkPurple),
          suffixText: widget.suffix,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _kLightGray),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _kTeal),
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

class VToggleGroup extends StatelessWidget {
  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  const VToggleGroup({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: _kDarkPurple),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: options.map((option) {
              final active = option == selected;
              return GestureDetector(
                onTap: () => onChanged(option),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: active ? _kTeal : Colors.white,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: active ? _kTeal : _kLightGray,
                    ),
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: active ? Colors.white : _kDarkPurple,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class VCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const VCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  activeColor: _kTeal,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 13, color: _kDarkPurple),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VTextArea extends StatefulWidget {
  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final int maxLines;

  const VTextArea({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.maxLines = 4,
  });

  @override
  State<VTextArea> createState() => _VTextAreaState();
}

class _VTextAreaState extends State<VTextArea> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(VTextArea old) {
    super.didUpdateWidget(old);
    if (old.initialValue != widget.initialValue &&
        widget.initialValue != _ctrl.text) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _ctrl,
        maxLines: widget.maxLines,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: const TextStyle(fontSize: 12, color: _kDarkPurple),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _kLightGray),
            borderRadius: BorderRadius.circular(6),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _kTeal),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

class VDropdown extends StatelessWidget {
  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  const VDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: _kDarkPurple)),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: options.contains(selected) ? selected : null,
            isExpanded: true,
            isDense: true,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              enabledBorder: OutlineInputBorder(
                borderSide: const BorderSide(color: _kLightGray),
                borderRadius: BorderRadius.circular(6),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: const BorderSide(color: _kTeal),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
