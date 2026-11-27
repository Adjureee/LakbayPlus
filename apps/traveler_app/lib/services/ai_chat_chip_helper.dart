class AiChatStructuredChip {
  final String label;
  final String field;
  final Object? value;
  final String messageLabel;

  const AiChatStructuredChip({
    required this.label,
    required this.field,
    required this.value,
    required this.messageLabel,
  });
}

class AiChatChipHelper {
  const AiChatChipHelper._();

  static const _shortMonths = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String formatIsoDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String formatReadableDate(DateTime date) {
    final month = _shortMonths[date.month - 1];
    return '$month ${date.day}, ${date.year}';
  }

  /// Resolves the Saturday of the current week (or [today] if already Sat/Sun),
  /// matching backend `short_answers._weekend_start`.
  static DateTime weekendStart(DateTime today) {
    final base = DateTime(today.year, today.month, today.day);
    if (base.weekday >= DateTime.saturday) return base;
    return base.add(Duration(days: DateTime.saturday - base.weekday));
  }

  static List<AiChatStructuredChip> buildStartDateChips({DateTime? now}) {
    final source = now ?? DateTime.now();
    final today = DateTime(source.year, source.month, source.day);
    final tomorrow = today.add(const Duration(days: 1));
    final weekend = weekendStart(today);
    return [
      AiChatStructuredChip(
        label: 'Today',
        field: 'travel_start_date',
        value: formatIsoDate(today),
        messageLabel: 'Today',
      ),
      AiChatStructuredChip(
        label: 'Tomorrow',
        field: 'travel_start_date',
        value: formatIsoDate(tomorrow),
        messageLabel: 'Tomorrow',
      ),
      AiChatStructuredChip(
        label: 'This weekend',
        field: 'travel_start_date',
        value: formatIsoDate(weekend),
        messageLabel: 'This weekend',
      ),
    ];
  }

  /// Mirrors `conversation_stage.missing_details` priority order.
  static String? inferMissingDetailFromState(
    Map<String, dynamic> state, {
    bool hasNatureInterest = false,
  }) {
    final interests = state['interests'];
    final destinationIds = state['destination_ids'];
    final hasInterests = interests is List && interests.isNotEmpty;
    final hasDestinations = destinationIds is List && destinationIds.isNotEmpty;
    if (!hasInterests && !hasDestinations) return 'interests';
    if (state['traveler_count'] == null) return 'traveler_count';
    if (state['day_count'] == null) return 'day_count';
    if (state['total_budget'] == null) return 'total_budget';
    if (hasNatureInterest) {
      if (state['activity_level'] == null) return 'activity_level';
      if (state['travel_start_date'] == null) return 'travel_start_date';
      if (state['prefers_quiet'] == null) return 'prefers_quiet';
    }
    return null;
  }

  static List<AiChatStructuredChip> buildFreeQuestionQuickChips(
    String? missingDetail,
    Map<String, dynamic> state,
  ) {
    switch (missingDetail) {
      case 'traveler_count':
        if (state['traveler_count'] != null) return const [];
        return const [
          AiChatStructuredChip(
            label: 'Just me',
            field: 'traveler_count',
            value: 1,
            messageLabel: 'Just me',
          ),
          AiChatStructuredChip(
            label: '2 travelers',
            field: 'traveler_count',
            value: 2,
            messageLabel: '2 travelers',
          ),
          AiChatStructuredChip(
            label: '4 travelers',
            field: 'traveler_count',
            value: 4,
            messageLabel: '4 travelers',
          ),
        ];
      case 'day_count':
        if (state['day_count'] != null) return const [];
        return const [
          AiChatStructuredChip(
            label: 'Day trip',
            field: 'day_count',
            value: 1,
            messageLabel: 'Day trip',
          ),
          AiChatStructuredChip(
            label: '2 days',
            field: 'day_count',
            value: 2,
            messageLabel: '2 days',
          ),
          AiChatStructuredChip(
            label: '3 days',
            field: 'day_count',
            value: 3,
            messageLabel: '3 days',
          ),
        ];
      case 'total_budget':
        if (state['total_budget'] != null) return const [];
        return const [
          AiChatStructuredChip(
            label: '₱1,500',
            field: 'total_budget',
            value: 1500,
            messageLabel: '₱1,500',
          ),
          AiChatStructuredChip(
            label: '₱3,000',
            field: 'total_budget',
            value: 3000,
            messageLabel: '₱3,000',
          ),
          AiChatStructuredChip(
            label: '₱5,000',
            field: 'total_budget',
            value: 5000,
            messageLabel: '₱5,000',
          ),
        ];
      default:
        return const [];
    }
  }

  static bool isSafeUpdateFallbackMessage(String text) {
    final normalized = text.toLowerCase().replaceAll('\u2019', "'");
    return normalized.contains("couldn't safely update your plan");
  }

  static final RegExp _partyCountPattern = RegExp(
    r'^(\d+)\s+(?:people|persons?|pax|travelers?)$',
  );
  static final RegExp _daysCountPattern = RegExp(
    r'^(\d+)\s+days?(?:\s*,\s*\d+\s+nights?)?$',
  );
  static final RegExp _budgetPattern = RegExp(
    r'^(?:₱|php\s*)?(\d[\d,]*)(?:\s*(k))?(?:\s*(?:pesos?|php))?$',
  );

  /// Maps a deterministic `suggestedReplies` tap to a structured
  /// `(field, value)` update when the corresponding field is missing, so client
  /// `planningState` stays synchronized with the backend.
  static AiChatStructuredChip? resolveSuggestedReplyDetail(
    String reply,
    String? missingDetail,
    Map<String, dynamic> state, {
    DateTime? now,
  }) {
    final trimmed = reply.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase().replaceAll('\u2019', "'");

    if (state['traveler_count'] == null &&
        (missingDetail == null || missingDetail == 'traveler_count')) {
      if (lower == 'just me' ||
          lower == 'solo' ||
          lower == '1 person' ||
          lower == '1 traveler') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'traveler_count',
          value: 1,
          messageLabel: trimmed,
        );
      }
      if (lower == 'couple' || lower == 'just us two') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'traveler_count',
          value: 2,
          messageLabel: trimmed,
        );
      }
      final partyMatch = _partyCountPattern.firstMatch(lower);
      if (partyMatch != null) {
        final count = int.tryParse(partyMatch.group(1)!);
        if (count != null && count >= 1 && count <= 30) {
          return AiChatStructuredChip(
            label: trimmed,
            field: 'traveler_count',
            value: count,
            messageLabel: trimmed,
          );
        }
      }
    }

    if (state['day_count'] == null &&
        (missingDetail == null || missingDetail == 'day_count')) {
      if (lower == 'just a day trip' ||
          lower == 'day trip' ||
          lower == 'a day trip' ||
          lower == '1 day') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'day_count',
          value: 1,
          messageLabel: trimmed,
        );
      }
      final dayMatch = _daysCountPattern.firstMatch(lower);
      if (dayMatch != null) {
        final days = int.tryParse(dayMatch.group(1)!);
        if (days != null && days >= 1 && days <= 14) {
          return AiChatStructuredChip(
            label: trimmed,
            field: 'day_count',
            value: days,
            messageLabel: trimmed,
          );
        }
      }
    }

    if (state['total_budget'] == null && missingDetail == 'total_budget') {
      final budgetMatch = _budgetPattern.firstMatch(lower);
      if (budgetMatch != null) {
        final rawDigits = budgetMatch.group(1)!.replaceAll(',', '');
        final parsed = int.tryParse(rawDigits);
        if (parsed != null) {
          final amount =
              budgetMatch.group(2) == 'k' ? parsed * 1000 : parsed;
          if (amount >= 100) {
            return AiChatStructuredChip(
              label: trimmed,
              field: 'total_budget',
              value: amount,
              messageLabel: trimmed,
            );
          }
        }
      }
    }

    if (state['activity_level'] == null &&
        missingDetail == 'activity_level') {
      if (lower == 'easy' || lower == 'easy pace') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'activity_level',
          value: 'easy',
          messageLabel: trimmed,
        );
      }
      if (lower == 'moderate') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'activity_level',
          value: 'moderate',
          messageLabel: trimmed,
        );
      }
      if (lower == 'challenging') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'activity_level',
          value: 'challenging',
          messageLabel: trimmed,
        );
      }
    }

    if (state['prefers_quiet'] == null && missingDetail == 'prefers_quiet') {
      if (lower == 'quiet places' || lower == 'quiet spots') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'prefers_quiet',
          value: true,
          messageLabel: trimmed,
        );
      }
      if (lower == 'popular is fine' || lower == 'popular icons') {
        return AiChatStructuredChip(
          label: trimmed,
          field: 'prefers_quiet',
          value: false,
          messageLabel: trimmed,
        );
      }
    }

    if (state['travel_start_date'] == null &&
        missingDetail == 'travel_start_date') {
      final chips = buildStartDateChips(now: now);
      for (final chip in chips) {
        if (chip.label.toLowerCase() == lower) {
          return AiChatStructuredChip(
            label: trimmed,
            field: chip.field,
            value: chip.value,
            messageLabel: trimmed,
          );
        }
      }
    }

    return null;
  }
}
