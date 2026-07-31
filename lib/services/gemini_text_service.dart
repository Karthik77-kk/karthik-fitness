import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'gemini_vision_service.dart' show GeminiException;

/// Cheap/fast cloud text generation via Gemini, reusing the same GEMINI_API_KEY
/// that powers meal-photo scanning. Backs the optional "cloud" AI-coach mode and
/// the once-a-day daily brief. Uses the LITE Flash tier deliberately to keep the
/// free-tier quota / cost low so it isn't exhausted.
class GeminiTextService {
  // Base64-encoded at CI injection time — see GeminiVisionService for why.
  static const String _keyB64 = String.fromEnvironment('GEMINI_API_KEY_B64');
  static String get _key =>
      _keyB64.isEmpty ? '' : utf8.decode(base64.decode(_keyB64));
  static const String _model = 'gemini-2.5-flash-lite';
  static const Duration _timeout = Duration(seconds: 30);

  /// True when a key is compiled in (same key as the meal scanner).
  static bool get isConfigured => _key.isNotEmpty;

  /// The model id used for cloud generation (exposed for UI copy).
  static const String modelLabel = 'Gemini Flash-Lite';

  /// One-shot generation: [system] is the system instruction, [user] the message.
  /// Returns plain text. Throws [GeminiException] with a user-safe message.
  static Future<String> generate(String system, String user,
      {double temperature = 0.4, int maxTokens = 800}) async {
    if (!isConfigured) {
      throw const GeminiException('The cloud coach isn\'t set up in this build.');
    }
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_key',
    );
    final payload = jsonEncode({
      'system_instruction': {
        'parts': [
          {'text': system}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': user}
          ]
        }
      ],
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxTokens,
      },
    });

    final http.Response resp;
    try {
      resp = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'}, body: payload)
          .timeout(_timeout);
    } catch (_) {
      throw const GeminiException(
          'No connection — check your internet and try again.');
    }

    if (resp.statusCode == 429) {
      throw const GeminiException(
          'The coach is busy (rate limit). Try again in a minute.');
    }
    if (resp.statusCode == 400 || resp.statusCode == 403) {
      throw const GeminiException(
          'The coach is unavailable (key/quota issue).');
    }
    if (resp.statusCode != 200) {
      throw GeminiException('The coach failed (${resp.statusCode}). Try again.');
    }

    final text = extractText(jsonDecode(resp.body));
    if (text == null || text.trim().isEmpty) {
      throw const GeminiException('The coach returned an empty response.');
    }
    return text.trim();
  }

  /// Parses the concatenated text out of a Gemini `generateContent` response
  /// body. Exposed for unit testing without a network call.
  @visibleForTesting
  static String? extractText(dynamic decoded) {
    try {
      final cands = (decoded as Map)['candidates'] as List?;
      if (cands == null || cands.isEmpty) return null;
      final parts = (cands.first['content']?['parts']) as List?;
      if (parts == null || parts.isEmpty) return null;
      return parts.map((p) => (p as Map)['text'] as String? ?? '').join();
    } catch (_) {
      return null;
    }
  }
}
