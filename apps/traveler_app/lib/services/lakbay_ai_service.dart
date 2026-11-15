import 'dart:convert';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class AiModelCandidate {
  final String provider;
  final String baseUrl;
  final String apiKey;
  final String modelId;

  const AiModelCandidate({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
  });
}

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
  });

  bool get hasStructuredItinerary => days.isNotEmpty;
}

/// Ported from Lakbay's `app/integrations/groq` (`client.py`, `model_selector.py`, `prompts.py`).
/// Calls Groq's OpenAI-compatible `/chat/completions` endpoint first, then falls back
/// to `GROQ_MODEL_FALLBACK` and `FALLBACK_LLM_*` (e.g., Gemini OpenAI-compatible API).
class LakbayAiService {
  final http.Client _httpClient;

  LakbayAiService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  bool get isConfigured => EnvConfig.hasAnyAiKey;

  /// Builds the ordered fallback chain matching Lakbay's `select_primary_model` +
  /// `select_fallback_models`.
  List<AiModelCandidate> buildModelChain({String role = 'default'}) {
    final chain = <AiModelCandidate>[];
    final seen = <String>{};

    if (EnvConfig.hasGroqKey) {
      final primaryModel = switch (role) {
        'fast' => EnvConfig.groqModelFast,
        'quality' => EnvConfig.groqModelQuality,
        _ => EnvConfig.groqModelDefault,
      };
      if (primaryModel.isNotEmpty) {
        seen.add('groq:$primaryModel');
        chain.add(
          AiModelCandidate(
            provider: 'groq',
            baseUrl: EnvConfig.groqBaseUrl,
            apiKey: EnvConfig.groqApiKey,
            modelId: primaryModel,
          ),
        );
      }

      final groqFallback = EnvConfig.groqModelFallback;
      if (groqFallback.isNotEmpty && !seen.contains('groq:$groqFallback')) {
        seen.add('groq:$groqFallback');
        chain.add(
          AiModelCandidate(
            provider: 'groq',
            baseUrl: EnvConfig.groqBaseUrl,
            apiKey: EnvConfig.groqApiKey,
            modelId: groqFallback,
          ),
        );
      }
    }

    if (EnvConfig.hasFallbackLlmKey && EnvConfig.fallbackLlmModel.isNotEmpty) {
      for (final rawModel in EnvConfig.fallbackLlmModel.split(',')) {
        final modelId = rawModel.trim();
        if (modelId.isEmpty || seen.contains('fallback_llm:$modelId')) {
          continue;
        }
        seen.add('fallback_llm:$modelId');
        chain.add(
          AiModelCandidate(
            provider: 'fallback_llm',
            baseUrl: EnvConfig.fallbackLlmBaseUrl,
            apiKey: EnvConfig.fallbackLlmApiKey,
            modelId: modelId,
          ),
        );
      }
    }

    return chain;
  }

  /// Sends a Davao Region travel query or itinerary request using Lakbay's
  /// structured JSON prompt pattern.
  Future<AiPlanResult> chatOrPlan({
    required String userPrompt,
    required List<String> availableDestinations,
    int defaultDays = 3,
  }) async {
    final chain = buildModelChain(role: 'default');
    if (chain.isEmpty) {
      throw StateError(
        'No AI API key configured. Add GROQ_API_KEY or FALLBACK_LLM_API_KEY to .env.',
      );
    }

    final systemPrompt = '''
You are Lakbay+, a high-grade AI travel planner strictly scoped to the Davao Region (Region XI, Philippines): Davao City, Samal Island (IGaCoS) & Talikud, Davao Oriental (Mati Dahican, Pujada Bay, Aliwagwag Falls), Davao del Sur (Mt. Apo, Kapatagan, Sta. Cruz), Davao del Norte (Tagum, Talaingod), Davao de Oro (Maragusan, Kopiat Island), and Davao Occidental.

Return ONLY valid JSON (no markdown fences) matching this schema:
{
  "reply": "Friendly, practical 2-4 sentence response for the traveler in PHP currency.",
  "should_create_itinerary": true,
  "title": "Short trip title",
  "destination": "Primary Davao Region destination",
  "vibe": "2-4 word trip vibe",
  "days_count": $defaultDays,
  "center_lat": 7.0731,
  "center_lng": 125.6128,
  "days": [
    {
      "day": 1,
      "title": "Day title",
      "summary": "1 sentence day summary",
      "activities": [
        {
          "time": "08:30 AM",
          "title": "Stop or activity name",
          "description": "Concise logistics & local tip",
          "lat": 7.0742,
          "lng": 125.7089,
          "estimated_cost_php": 450,
          "category": "sightseeing"
        }
      ]
    }
  ]
}

Rules:
- Keep all coordinates strictly inside Davao Region (lat 5.20..8.15, lng 124.95..126.85).
- Use realistic PHP estimates. Do not invent places outside Region XI.
- If the user asks a general question (not asking for a trip plan), set "should_create_itinerary": false and "days": [].
''';

    final userMessage = jsonEncode({
      'query': userPrompt,
      'known_davao_destinations': availableDestinations.take(16).toList(),
    });

    Object? lastError;
    for (final candidate in chain) {
      try {
        final rawJson = await _callChatCompletions(
          candidate: candidate,
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMessage},
          ],
          jsonMode: true,
        );
        return _parseStructuredResponse(
          rawJson: rawJson,
          candidate: candidate,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw StateError('All AI providers failed. Last error: $lastError');
  }

  Future<String> _callChatCompletions({
    required AiModelCandidate candidate,
    required List<Map<String, String>> messages,
    bool jsonMode = false,
  }) async {
    final cleanBase = candidate.baseUrl.endsWith('/')
        ? candidate.baseUrl.substring(0, candidate.baseUrl.length - 1)
        : candidate.baseUrl;
    final uri = Uri.parse('$cleanBase/chat/completions');

    final body = <String, dynamic>{
      'model': candidate.modelId,
      'messages': messages,
      'temperature': EnvConfig.groqTemperature,
      'max_tokens': EnvConfig.groqMaxTokens,
      if (jsonMode) 'response_format': {'type': 'json_object'},
    };

    final response = await _httpClient
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer ${candidate.apiKey}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        '${candidate.provider} (${candidate.modelId}) HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) {
      throw StateError('${candidate.provider} returned empty choices.');
    }
    final first = choices.first as Map<String, dynamic>;
    final message = first['message'] as Map<String, dynamic>? ?? const {};
    final content = (message['content'] ?? '').toString().trim();
    if (content.isEmpty) {
      throw StateError('${candidate.provider} returned empty content.');
    }
    return content;
  }

  AiPlanResult _parseStructuredResponse({
    required String rawJson,
    required AiModelCandidate candidate,
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
        final acts = rawActs.map((item) {
          final a = item as Map<String, dynamic>;
          return AiGeneratedActivity(
            time: (a['time'] ?? '09:00 AM').toString(),
            title: (a['title'] ?? 'Davao Stop').toString(),
            description: (a['description'] ?? '').toString(),
            lat: (a['lat'] as num?)?.toDouble(),
            lng: (a['lng'] as num?)?.toDouble(),
            estimatedCostPhp:
                (a['estimated_cost_php'] as num?)?.toDouble() ?? 0,
            category: (a['category'] ?? 'activity').toString(),
          );
        }).toList();

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

    return AiPlanResult(
      replyText: reply.isNotEmpty
          ? reply
          : 'Here is your Davao Region travel update.',
      providerUsed: candidate.provider,
      modelUsed: candidate.modelId,
      title: decoded['title']?.toString(),
      destination: decoded['destination']?.toString(),
      vibe: decoded['vibe']?.toString(),
      daysCount: (decoded['days_count'] as num?)?.toInt(),
      centerLat: (decoded['center_lat'] as num?)?.toDouble(),
      centerLng: (decoded['center_lng'] as num?)?.toDouble(),
      days: parsedDays,
    );
  }
}
