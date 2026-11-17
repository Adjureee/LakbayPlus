import 'package:flutter/material.dart';

import '../theme/lakbay_theme.dart';

/// The one wording used wherever prices appear, so no total reads like a
/// quote or a guarantee (PRODUCT.md: no fee or pricing guarantees).
const String kFareEstimateNote = "Fares are estimates from Lakbay's local rates.";

class EstimateNote extends StatelessWidget {
  const EstimateNote({super.key, this.color = LakbayColors.textSecondary});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.info_outline_rounded, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            kFareEstimateNote,
            style: TextStyle(fontSize: 11.5, height: 1.3, color: color),
          ),
        ),
      ],
    );
  }
}
