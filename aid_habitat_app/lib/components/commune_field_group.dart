import 'package:flutter/material.dart';

/// Reusable commune (city) autocomplete — mirrors the React CommuneFieldGroup.
///
/// Given a list of [CommuneOption]s, presents a city text field with a
/// dropdown that filters as the user types. Picking an option updates both
/// the city label and zip code simultaneously via [onChanged].
class CommuneOption {
  final String id;
  final String label;
  final String zipCode;
  final String? epciId;
  final String? epciLabel;

  const CommuneOption({
    required this.id,
    required this.label,
    required this.zipCode,
    this.epciId,
    this.epciLabel,
  });
}

class CommuneUpdate {
  final String? city;
  final String? zipCode;
  final String? cityId;

  const CommuneUpdate({this.city, this.zipCode, this.cityId});
}

class CommuneFieldGroup extends StatefulWidget {
  final String city;
  final String zipCode;
  final String? cityId;
  final List<CommuneOption> options;
  final ValueChanged<CommuneUpdate> onChanged;
  final VoidCallback? onBlur;
  final String zipLabel;
  final String cityLabel;
  final bool showZipField;

  /// Couleur des libellés "CP" / "Ville" — par défaut slate #64748B.
  /// Permet de surcharger par ex. en violet pour le bloc Bénéficiaire.
  final Color? labelColor;

  const CommuneFieldGroup({
    super.key,
    required this.city,
    required this.zipCode,
    required this.onChanged,
    this.options = const [],
    this.cityId,
    this.onBlur,
    this.zipLabel = 'CP',
    this.cityLabel = 'Ville',
    this.showZipField = true,
    this.labelColor,
  });

  @override
  State<CommuneFieldGroup> createState() => _CommuneFieldGroupState();
}

class _CommuneFieldGroupState extends State<CommuneFieldGroup> {
  late final TextEditingController _cityCtrl;
  late final FocusNode _focusNode;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlay;

  @override
  void initState() {
    super.initState();
    _cityCtrl = TextEditingController(text: widget.city);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(CommuneFieldGroup old) {
    super.didUpdateWidget(old);
    if (widget.city != _cityCtrl.text && !_focusNode.hasFocus) {
      _cityCtrl.text = widget.city;
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  // ----- Helpers -----

  static String _normalize(String value) {
    const accents = 'áàâäãåéèêëíìîïóòôöõúùûüýÿñç';
    const plain = 'aaaaaaeeeeiiiiooooouuuuyync';
    var result = value.toLowerCase();
    for (var i = 0; i < accents.length; i++) {
      result = result.replaceAll(accents[i], plain[i]);
    }
    return result
        .replaceAll(RegExp("[\u2019'`\\-]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<CommuneOption> get _filtered {
    final query = _normalize(_cityCtrl.text);
    if (query.isEmpty) return widget.options;
    return widget.options.where((o) {
      return _normalize(o.label).contains(query) ||
          o.zipCode.contains(_cityCtrl.text.trim());
    }).toList();
  }

  // ----- Focus / overlay -----

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _showOverlay();
    } else {
      // Short delay so tap on an item registers before dismiss
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (!_focusNode.hasFocus) _removeOverlay();
        widget.onBlur?.call();
      });
    }
  }

  void _showOverlay() {
    _removeOverlay();
    final options = _filtered;
    if (options.isEmpty) return;

    _overlay = OverlayEntry(
      builder: (ctx) {
        final renderBox = context.findRenderObject() as RenderBox?;
        final width = renderBox?.size.width ?? 240;
        return Positioned(
          width: width,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, (renderBox?.size.height ?? 60) + 4),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: _filtered.length,
                  itemBuilder: (ctx, i) {
                    final option = _filtered[i];
                    final selected = option.id == widget.cityId;
                    return InkWell(
                      onTap: () => _pick(option),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        color: selected
                            ? const Color(0xFFF6EDFB)
                            : Colors.transparent,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                option.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: selected
                                      ? const Color(0xFF554A63)
                                      : Colors.black87,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            Text(
                              '(${option.zipCode.isEmpty ? '—' : option.zipCode})',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_overlay!);
  }

  void _refreshOverlay() {
    if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _pick(CommuneOption option) {
    _cityCtrl.text = option.label;
    widget.onChanged(CommuneUpdate(
      cityId: option.id,
      city: option.label,
      zipCode: option.zipCode,
    ));
    _focusNode.unfocus();
  }

  // ----- Build -----

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: widget.showZipField
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Largeur fixe pour le code postal : suffisante pour afficher
                // le label "Code postal" sur une seule ligne et une valeur
                // 5 chiffres. Le champ Ville utilise l'espace restant via
                // Expanded et rétrécit en priorité quand la section est
                // étroite.
                SizedBox(width: 110, child: _buildZipField()),
                const SizedBox(width: 8),
                Expanded(child: _buildCityField()),
              ],
            )
          : _buildCityField(),
    );
  }

  Widget _buildZipField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.zipLabel,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: TextStyle(
            fontSize: 13,
            color: widget.labelColor ?? const Color(0xFF64748B),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          initialValue: widget.zipCode,
          readOnly: true,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCityField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.cityLabel,
          style: TextStyle(
            fontSize: 13,
            color: widget.labelColor ?? const Color(0xFF64748B),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        CompositedTransformTarget(
          link: _layerLink,
          child: TextField(
            controller: _cityCtrl,
            focusNode: _focusNode,
            onChanged: (typed) {
              if (typed.isEmpty) {
                widget.onChanged(
                    const CommuneUpdate(city: '', zipCode: '', cityId: ''));
              } else {
                widget.onChanged(
                    CommuneUpdate(city: typed, zipCode: '', cityId: ''));
                // Exact match auto-select
                final target = _normalize(typed);
                final exact = widget.options
                    .where((o) => _normalize(o.label) == target)
                    .toList();
                if (exact.length == 1 && typed == typed.trim()) {
                  final sel = exact.first;
                  _cityCtrl.text = sel.label;
                  widget.onChanged(CommuneUpdate(
                    cityId: sel.id,
                    city: sel.label,
                    zipCode: sel.zipCode,
                  ));
                }
              }
              _refreshOverlay();
            },
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              filled: true,
              fillColor: Colors.white,
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
                borderSide:
                    const BorderSide(color: Color(0xFF907CA1), width: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
