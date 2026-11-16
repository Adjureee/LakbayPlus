import 'package:flutter/material.dart';

import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

/// Onboarding step: what the traveler enjoys and who they usually travel with.
///
/// The groups come from the live catalog (the same ones as Settings), so the
/// choices here are the real categories. Everything is optional; picks are
/// saved straight away and the AI planner uses them from its first message.
class OnboardingPreferencesStep extends StatefulWidget {
  final TravelRepository repo;
  final VoidCallback onContinue;

  const OnboardingPreferencesStep({
    super.key,
    required this.repo,
    required this.onContinue,
  });

  @override
  State<OnboardingPreferencesStep> createState() =>
      _OnboardingPreferencesStepState();
}

class _OnboardingPreferencesStepState extends State<OnboardingPreferencesStep> {
  static const _companions = ['Solo', 'Couple', 'Family', 'Friends'];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.repo.refreshPreferenceGroups();
    } catch (_) {
      // The step still works without the list; it says so below.
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final repo = widget.repo;
        final groups = repo.preferenceGroups;
        final picked = repo.selectedVibes;
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
          child: Column(
            children: [
              const Text(
                'What do you enjoy?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  color: LakbayColors.tealDeep,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pick any that fit. Lakbay AI starts from these, and you can change them later in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: LakbayColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loading && groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (groups.isEmpty)
                        const Text(
                          "Couldn't load the choices right now. You can skip this and set them later in Settings.",
                          style: TextStyle(
                            fontSize: 13.5,
                            color: LakbayColors.textSecondary,
                          ),
                        )
                      else ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final group in groups)
                              FilterChip(
                                label: Text(group.label),
                                tooltip: group.description,
                                selected: picked.contains(group.key),
                                selectedColor: LakbayColors.primaryLight,
                                onSelected: (_) => repo.toggleVibe(group.key),
                              ),
                          ],
                        ),
                        // Narrow a chosen group (for example Waterfalls within
                        // Nature attractions). None chosen means all of them.
                        for (final group in groups)
                          if (picked.contains(group.key) &&
                              group.subtypes.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              '${group.label}: narrow it down (optional)',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final sub in group.subtypes)
                                  FilterChip(
                                    label: Text(sub.label),
                                    visualDensity: VisualDensity.compact,
                                    selected: picked.contains(sub.key),
                                    selectedColor: LakbayColors.primaryLight,
                                    onSelected: (_) => repo.toggleVibe(sub.key),
                                  ),
                              ],
                            ),
                          ],
                      ],
                      const SizedBox(height: 22),
                      const Text(
                        'Who do you usually travel with?',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final companion in _companions)
                            ChoiceChip(
                              label: Text(companion),
                              selected: repo.travelCompanion == companion,
                              selectedColor: LakbayColors.primaryLight,
                              onSelected: (_) =>
                                  repo.setTravelCompanion(companion),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: widget.onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LakbayColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: Text(
                    picked.isEmpty ? 'Skip for now' : 'Continue',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
