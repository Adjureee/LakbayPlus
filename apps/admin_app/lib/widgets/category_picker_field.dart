import 'package:flutter/material.dart';

/// Category picker populated from `/destinations/facets` with an explicit
/// "Add new category..." mode and group membership hint.
class CategoryPickerField extends StatefulWidget {
  const CategoryPickerField({
    super.key,
    required this.controller,
    required this.categoryFacets,
    this.label = 'Category',
    this.hintText,
    this.onChanged,
  });

  final TextEditingController controller;
  final List<Map<String, dynamic>> categoryFacets;
  final String label;
  final String? hintText;
  final ValueChanged<String>? onChanged;

  @override
  State<CategoryPickerField> createState() => _CategoryPickerFieldState();
}

class _CategoryPickerFieldState extends State<CategoryPickerField> {
  static const _addNewSentinel = '__lakbay_add_new_category__';
  bool _customMode = false;

  @override
  void initState() {
    super.initState();
    _syncInitialMode();
  }

  @override
  void didUpdateWidget(covariant CategoryPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.categoryFacets != widget.categoryFacets) {
      _syncInitialMode();
    }
  }

  void _syncInitialMode() {
    final current = widget.controller.text.trim();
    if (current.isEmpty) {
      _customMode = false;
      return;
    }
    final matchesOption = _optionValues().any(
      (opt) => opt.toLowerCase() == current.toLowerCase(),
    );
    _customMode = !matchesOption;
  }

  List<String> _optionValues() {
    final seen = <String>{};
    final values = <String>[];
    for (final facet in widget.categoryFacets) {
      final raw = (facet['label'] ?? facet['key'] ?? '').toString().trim();
      if (raw.isNotEmpty && seen.add(raw.toLowerCase())) {
        values.add(raw);
      }
    }
    values.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  String? _matchingSelectedValue(List<String> options) {
    final current = widget.controller.text.trim();
    if (current.isEmpty) return '';
    for (final opt in options) {
      if (opt.toLowerCase() == current.toLowerCase()) return opt;
    }
    return null;
  }

  Map<String, dynamic>? _facetForValue(String value) {
    final needle = value.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final facet in widget.categoryFacets) {
      final key = (facet['key'] ?? '').toString().toLowerCase();
      final label = (facet['label'] ?? '').toString().toLowerCase();
      if (key == needle || label == needle) return facet;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final options = _optionValues();
    final matched = _matchingSelectedValue(options);
    final selectedDropdown =
        _customMode ? _addNewSentinel : (matched ?? _addNewSentinel);
    final activeFacet = _facetForValue(widget.controller.text);
    final isUngrouped =
        activeFacet != null && activeFacet['group']?.toString() == 'other';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (options.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('cat_dd_${options.length}_$selectedDropdown'),
            initialValue: selectedDropdown,
            isExpanded: true,
            decoration: InputDecoration(labelText: widget.label),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('None / unspecified'),
              ),
              ...options.map((opt) {
                final facet = _facetForValue(opt);
                final group = facet?['group']?.toString() ?? '';
                final suffix =
                    group == 'other' ? ' (Other)' : '';
                return DropdownMenuItem(
                  value: opt,
                  child: Text('$opt$suffix', overflow: TextOverflow.ellipsis),
                );
              }),
              const DropdownMenuItem(
                value: _addNewSentinel,
                child: Text('+ Add new category…'),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              if (value == _addNewSentinel) {
                setState(() => _customMode = true);
                return;
              }
              setState(() {
                _customMode = false;
                widget.controller.text = value;
              });
              widget.onChanged?.call(value);
            },
          ),
        ],
        if (options.isEmpty || _customMode) ...[
          if (options.isNotEmpty) const SizedBox(height: 8),
          TextFormField(
            controller: widget.controller,
            maxLength: 500,
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              labelText: options.isEmpty
                  ? widget.label
                  : 'New category name',
              hintText: widget.hintText ?? 'e.g. Waterfall, Beach Resort',
              counterText: '',
            ),
          ),
        ],
        if (isUngrouped) ...[
          const SizedBox(height: 4),
          Text(
            'Note: "${widget.controller.text.trim()}" is currently in Other until mapped in preference_groups.json or category_aliases.json.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        ],
      ],
    );
  }
}
