import 'dart:convert';
import 'dart:math' as math;
import 'lakbay_api_catalog_service.dart';

class AiGeneratedActivity {
  final String time;
  final String title;
  final String description;
  final double? lat;
  final double? lng;
  final double estimatedCostPhp;
  final String category;

  const AiGeneratedActivity({
    required this.time,
    required this.title,
    required this.description,
    this.lat,
    this.lng,
    this.estimatedCostPhp = 0,
    this.category = 'activity',
  });
}

class AiGeneratedDay {
  final int day;
  final String title;
  final String summary;
  final List<AiGeneratedActivity> activities;

  const AiGeneratedDay({
    required this.day,
    required this.title,
    required this.summary,
    required this.activities,
  });
}

class AiPlanResult {
  final String replyText;
  final String providerUsed;
  final String modelUsed;
  final String? title;
  final String? destination;
  final String? vibe;
  final int? daysCount;
  final double? centerLat;
  final double? centerLng;
  final List<AiGeneratedDay> days;
  final List<String> suggestedReplies;

  const AiPlanResult({
    required this.replyText,
    required this.providerUsed,
    required this.modelUsed,
    this.title,
    this.destination,
    this.vibe,
    this.daysCount,
    this.centerLat,
    this.centerLng,
    this.days = const [],
    this.suggestedReplies = const [],
  });

  bool get hasStructuredItinerary => days.isNotEmpty;
}

/// Lakbay AI trip drafts, served by the Lakbay backend (`POST /ai/trip-draft`).
///
/// The app never holds an AI provider key: the backend chooses the model,
/// applies rate limits (per user, or per device for guests), and grounds the
/// draft in Lakbay's destination catalog.
class LakbayAiService {
  LakbayAiService({this.backend, this.accessToken});

  final LakbayApiCatalogService? backend;

  /// The signed-in access token, or null for guest requests.
  final String? Function()? accessToken;

  bool get isConfigured => backend?.isConfigured ?? false;

  /// Answers a Davao Region travel query and, when the traveler is ready,
  /// drafts a structured multi-day itinerary.
  Future<AiPlanResult> chatOrPlan({
    required String userPrompt,
    List<String> availableDestinations = const [],
    int defaultDays = 3,
    List<Map<String, String>> history = const [],
    String? currentLocation,
    double? userLat,
    double? userLng,
    Set<String> preferredVibes = const {},
    bool strictBudget = false,
  }) async {
    final backend = this.backend;
    if (backend == null || !backend.isConfigured) {
      throw StateError('LAKBAY_API_BASE_URL is not configured.');
    }
    final recent = history
        .where((turn) => (turn['content'] ?? '').trim().isNotEmpty)
        .toList();
    final trimmedHistory = [
      for (final turn in recent.skip(math.max(0, recent.length - 12)))
        {
          'role': turn['role'] == 'assistant' ? 'assistant' : 'user',
          'content': _limit(turn['content']!.trim(), 2000),
        },
    ];
    final result = await backend.aiTripDraft(
      accessToken: accessToken?.call(),
      message: _limit(userPrompt, 2000),
      history: trimmedHistory,
      currentLocation: currentLocation,
      userLat: userLat,
      userLng: userLng,
      preferredVibes: preferredVibes.toList(),
      strictBudget: strictBudget,
      defaultDays: defaultDays,
    );
    if (result == null) {
      throw StateError('Lakbay AI is unavailable right now.');
    }
    return _parseStructuredResponse(
      rawJson: jsonEncode(result.draft),
      provider: result.provider,
      modelId: result.modelId,
    );
  }

  static String _limit(String text, int max) =>
      text.length > max ? text.substring(0, max) : text;

  AiPlanResult _parseStructuredResponse({
    required String rawJson,
    required String provider,
    required String modelId,
  }) {
    var cleaned = rawJson.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }

    final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
    final reply = (decoded['reply'] ?? '').toString().trim();
    final shouldCreate = decoded['should_create_itinerary'] == true;
    final rawDays = decoded['days'] as List<dynamic>? ?? const [];

    final parsedDays = <AiGeneratedDay>[];
    if (shouldCreate && rawDays.isNotEmpty) {
      for (var i = 0; i < rawDays.length; i++) {
        final d = rawDays[i] as Map<String, dynamic>;
        final rawActs = d['activities'] as List<dynamic>? ?? const [];
        // A stop with no name is dropped rather than shown as a made-up place,
        // and a missing time stays blank rather than becoming 9 AM.
        final acts = rawActs
            .whereType<Map<String, dynamic>>()
            .where((a) => (a['title'] ?? '').toString().trim().isNotEmpty)
            .map((a) => AiGeneratedActivity(
                  time: (a['time'] ?? '').toString(),
                  title: a['title'].toString().trim(),
                  description: (a['description'] ?? '').toString(),
                  lat: (a['lat'] as num?)?.toDouble(),
                  lng: (a['lng'] as num?)?.toDouble(),
                  estimatedCostPhp:
                      (a['estimated_cost_php'] as num?)?.toDouble() ?? 0,
                  category: (a['category'] ?? 'activity').toString(),
                ))
            .toList();

        parsedDays.add(
          AiGeneratedDay(
            day: (d['day'] as num?)?.toInt() ?? (i + 1),
            title: (d['title'] ?? 'Day ${i + 1}').toString(),
            summary: (d['summary'] ?? '').toString(),
            activities: acts,
          ),
        );
      }
    }

    final rawReplies = decoded['suggested_replies'] as List<dynamic>? ?? const [];
    final suggestedReplies = rawReplies
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .take(4)
        .toList();

    if (reply.isEmpty && parsedDays.isEmpty) {
      // Nothing to show: report it instead of putting words in the AI's mouth.
      throw StateError('Lakbay AI returned an empty answer.');
    }

    return AiPlanResult(
      replyText: reply,
      providerUsed: provider,
      modelUsed: modelId,
      title: decoded['title']?.toString(),
      destination: decoded['destination']?.toString(),
      vibe: decoded['vibe']?.toString(),
      daysCount: (decoded['days_count'] as num?)?.toInt(),
      centerLat: (decoded['center_lat'] as num?)?.toDouble(),
      centerLng: (decoded['center_lng'] as num?)?.toDouble(),
      days: parsedDays,
      suggestedReplies: suggestedReplies,
    );
  }
}
