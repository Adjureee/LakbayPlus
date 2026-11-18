import 'package:flutter/material.dart';

import '../services/api_service.dart';

const priceItems = <String, String>{
  'entrance': 'Entrance',
  'overnight': 'Overnight',
  'parking': 'Parking',
  'cottage': 'Cottage',
  'other': 'Other fee',
};
const priceAudiences = <String, String>{
  'adult': 'Adult',
  'child': 'Child',
  'senior': 'Senior',
  'pwd': 'PWD',
  'student': 'Student',
  'resident': 'Resident',
  'non_resident': 'Non-resident',
  'everyone': 'Everyone',
};
const priceUnits = <String, String>{
  'per_person': 'per person',
  'per_group': 'per group',
  'per_vehicle': 'per vehicle',
  'per_night': 'per night',
};

class PriceRow {
  PriceRow({
    this.item = 'entrance',
    this.audience = 'adult',
    this.unit = 'per_person',
    String amount = '',
    String ageMin = '',
    String ageMax = '',
    String note = '',
  }) : amount = TextEditingController(text: amount),
       ageMin = TextEditingController(text: ageMin),
       ageMax = TextEditingController(text: ageMax),
       note = TextEditingController(text: note);

  String item;
  String audience;
  String unit;
  final TextEditingController amount;
  final TextEditingController ageMin;
  final TextEditingController ageMax;
  final TextEditingController note;

  void dispose() {
    amount.dispose();
    ageMin.dispose();
    ageMax.dispose();
    note.dispose();
  }

  /// The API row, or null when the amount is not a number (so it is not sent).
  Map<String, dynamic>? toJson() {
    final value = num.tryParse(amount.text.trim().replaceAll(',', ''));
    if (value == null) return null;
    final min = int.tryParse(ageMin.text.trim());
    final max = int.tryParse(ageMax.text.trim());
    return {
      'item': item,
      'audience': audience,
      'amount': amount.text.trim().replaceAll(',', ''),
      'unit': unit,
      if (min != null) 'age_min': min,
      if (max != null) 'age_max': max,
      if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
    };
  }
}

/// Entrance fees and other prices by audience. Saved on its own (one request
/// replaces everything). A price you do not list stays unknown to travelers;
/// type 0 only when the source says it is free.
class PricesSection extends StatefulWidget {
  const PricesSection({super.key, required this.api, required this.destinationId});

  final ApiService api;
  final String destinationId;

  @override
  State<PricesSection> createState() => _PricesSectionState();
}

class _PricesSectionState extends State<PricesSection> {
  final _rows = <PriceRow>[];
  final _source = TextEditingController();
  DateTime? _verifiedAt;
  String? _summary;
  String? _quality;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.getDestinationPrices(widget.destinationId);
      if (!mounted) return;
      setState(() {
        _apply(data);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load prices. $error';
      });
    }
  }

  void _apply(Map<String, dynamic> data) {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(
        (data['prices'] as List? ?? const []).map((raw) {
          final map = Map<String, dynamic>.from(raw as Map);
          return PriceRow(
            item: map['item']?.toString() ?? 'entrance',
            audience: map['audience']?.toString() ?? 'adult',
            unit: map['unit']?.toString() ?? 'per_person',
            amount: _amountText(map['amount']),
            ageMin: map['age_min']?.toString() ?? '',
            ageMax: map['age_max']?.toString() ?? '',
            note: map['note']?.toString() ?? '',
          );
        }),
      );
    _source.text = data['fees_source_url']?.toString() ?? '';
    _verifiedAt = DateTime.tryParse(data['fees_verified_at']?.toString() ?? '');
    _summary = data['summary']?.toString();
    _quality = data['data_quality']?.toString();
  }

  /// "100.00" shows as 100 so the field matches how an admin typed it.
  String _amountText(Object? value) {
    final parsed = num.tryParse(value?.toString() ?? '');
    if (parsed == null) return value?.toString() ?? '';
    return parsed == parsed.roundToDouble()
        ? parsed.toInt().toString()
        : parsed.toString();
  }

  Future<void> _save() async {
    final rows = <Map<String, dynamic>>[];
    for (final row in _rows) {
      final json = row.toJson();
      if (json == null) {
        setState(
          () => _error =
              'Every price needs an amount (a number). Remove the row or fill it in.',
        );
        return;
      }
      rows.add(json);
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final saved = await widget.api.saveDestinationPrices(widget.destinationId, {
        'fees_source_url': _source.text.trim().isEmpty ? null : _source.text.trim(),
        'fees_verified_at': _verifiedAt?.toUtc().toIso8601String(),
        'prices': rows,
      });
      if (!mounted) return;
      setState(() {
        _apply(saved);
        _saving = false;
        _notice = 'Prices saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save prices. $error';
      });
    }
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('prices-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Prices', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Entrance and other fees by audience, saved separately from the rest of '
          'the form. A price you leave out stays unknown to travelers; enter 0 only '
          'when the source says it is free.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        if (_loading)
          const LinearProgressIndicator()
        else ...[
          if (_rows.isEmpty)
            Text('No prices entered yet.', style: theme.textTheme.bodyMedium),
          for (var i = 0; i < _rows.length; i++) _row(i),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('prices-add'),
              onPressed: () => setState(() => _rows.add(PriceRow())),
              icon: const Icon(Icons.add),
              label: const Text('Add a price'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('prices-source'),
            controller: _source,
            decoration: const InputDecoration(
              labelText: 'Where these prices came from (web address)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _verifiedAt == null
                    ? 'Never verified'
                    : 'Verified ${_date(_verifiedAt!.toLocal())}',
              ),
              OutlinedButton(
                key: const ValueKey('prices-verified-today'),
                onPressed: () => setState(() => _verifiedAt = DateTime.now()),
                child: const Text('Verified today'),
              ),
            ],
          ),
          if (_summary != null) ...[
            const SizedBox(height: 12),
            Text(
              'Travelers see: $_summary'
              '${_quality == null ? '' : ' (${_quality!})'}',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_notice != null) ...[const SizedBox(height: 12), Text(_notice!)],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('prices-save'),
          onPressed: _loading || _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving...' : 'Save prices'),
        ),
      ],
    );
  }

  Widget _row(int index) {
    final row = _rows[index];
    return Card(
      key: ValueKey('price-row-$index'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _dropdown(
              'Item',
              row.item,
              priceItems,
              (v) => setState(() => row.item = v),
              ValueKey('price-item-$index'),
            ),
            _dropdown(
              'Who pays',
              row.audience,
              priceAudiences,
              (v) => setState(() => row.audience = v),
              ValueKey('price-audience-$index'),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: ValueKey('price-amount-$index'),
                controller: row.amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount (PHP)'),
              ),
            ),
            _dropdown(
              'Per',
              row.unit,
              priceUnits,
              (v) => setState(() => row.unit = v),
              ValueKey('price-unit-$index'),
            ),
            SizedBox(
              width: 90,
              child: TextField(
                controller: row.ageMin,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Age from'),
              ),
            ),
            SizedBox(
              width: 90,
              child: TextField(
                controller: row.ageMax,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Age to'),
              ),
            ),
            SizedBox(
              width: 220,
              child: TextField(
                controller: row.note,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  counterText: '',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove this price',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _rows.removeAt(index).dispose();
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> onChanged,
    Key key,
  ) {
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<String>(
        key: key,
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
