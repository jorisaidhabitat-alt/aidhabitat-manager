import 'package:flutter/material.dart';

import '../models/types.dart';
import '../services/references_service.dart';
import 'form_widgets.dart';

/// Commune autocomplete widget — React parity with `CommuneFieldGroup`.
///
/// Layout: two side-by-side fields on the same row:
///  - City (editable, triggers the autocomplete)
///  - Zip code (editable too, but gets auto-populated after a selection)
///
/// While the user types in the City field, an overlay shows up to 12
/// matching communes sorted by relevance. Selecting one fills both fields
/// and calls [onSelected] with `(label, zipCode, id)`. Typing free text
/// without selecting still fires [onCityTextChanged] so the parent can
/// persist a custom city name.
class CommuneAutocomplete extends StatefulWidget {
  final String city;
  final String zipCode;
  final String cityId;
  final void Function(String city, String zipCode, String cityId) onSelected;
  final void Function(String city)? onCityTextChanged;
  final void Function(String zipCode)? onZipTextChanged;

  const CommuneAutocomplete({
    super.key,
    required this.city,
    required this.zipCode,
    required this.cityId,
    required this.onSelected,
    this.onCityTextChanged,
    this.onZipTextChanged,
  });

  @override
  State<CommuneAutocomplete> createState() => _CommuneAutocompleteState();
}

class _CommuneAutocompleteState extends State<CommuneAutocomplete> {
  final ReferencesService _references = ReferencesService();
  final LayerLink _cityLink = LayerLink();
  final FocusNode _cityFocus = FocusNode();
  OverlayEntry? _overlay;
  List<CommuneRef> _matches = const [];

  @override
  void initState() {
    super.initState();
    _references.ensureLoaded();
    _cityFocus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _cityFocus.removeListener(_handleFocusChange);
    _cityFocus.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_cityFocus.hasFocus) {
      // Give the tap on a dropdown item a chance to land before we close.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (!_cityFocus.hasFocus) _removeOverlay();
      });
    }
  }

  void _refreshMatches(String query) {
    final q = query.trim();
    if (q.isEmpty) {
      _matches = const [];
      _removeOverlay();
      return;
    }
    _matches = _references.searchCommunes(q);
    if (_matches.isEmpty) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    overlayState.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _selectCommune(CommuneRef commune) {
    widget.onSelected(commune.label, commune.zipCode, commune.id);
    _removeOverlay();
    _cityFocus.unfocus();
  }

  Widget _buildOverlay(BuildContext ctx) {
    return Positioned(
      width: _cityWidth(),
      child: CompositedTransformFollower(
        link: _cityLink,
        showWhenUnlinked: false,
        offset: const Offset(0, 50),
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _matches.length,
              itemBuilder: (_, i) {
                final c = _matches[i];
                return InkWell(
                  onTap: () => _selectCommune(c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.label,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF334155),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (c.zipCode.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE8F5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              c.zipCode,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF554A63),
                              ),
                            ),
                          ),
                        ],
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
  }

  double _cityWidth() {
    final rb = context.findRenderObject() as RenderBox?;
    if (rb == null) return 320;
    // The city field is the first half of our Row — use ~ 2/3 width
    // to mimic the React "ville + zip" split (Ville occupies more space).
    return rb.size.width * 0.62;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: CompositedTransformTarget(
            link: _cityLink,
            child: Focus(
              focusNode: _cityFocus,
              child: FormTextField(
                label: 'Ville',
                value: widget.city,
                onChanged: (v) {
                  widget.onCityTextChanged?.call(v);
                  _refreshMatches(v);
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 1,
          child: FormTextField(
            label: 'Code postal',
            value: widget.zipCode,
            keyboardType: TextInputType.number,
            onChanged: (v) => widget.onZipTextChanged?.call(v),
          ),
        ),
      ],
    );
  }
}
