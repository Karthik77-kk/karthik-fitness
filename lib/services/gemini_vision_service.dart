import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One food/drink item detected in a meal photo, with a portion estimate and
/// the nutrition for THAT portion (not per-100 g). The on-device food resolver
/// (local DB / IFCT / OFF / USDA) can refine a name later; this is the raw
/// vision result the user confirms.
class ScannedFood {
  final String name;
  final double grams;
  final double kcal;
  final double protein;
  final double carbs;
  final double fat;
  final double confidence; // 0..1

  const ScannedFood({
    required this.name,
    required this.grams,
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.confidence,
  });

  ScannedFood copyWith({
    String? name,
    double? grams,
    double? kcal,
    double? protein,
    double? carbs,
    double? fat,
  }) =>
      ScannedFood(
        name: name ?? this.name,
        grams: grams ?? this.grams,
        kcal: kcal ?? this.kcal,
        protein: protein ?? this.protein,
        carbs: carbs ?? this.carbs,
        fat: fat ?? this.fat,
        confidence: confidence,
      );
}

/// Proportionally rescales a [ScannedFood]'s macros to [newGrams], from its
/// original portion. Used by the meal-scan review screen so editing the grams
/// field re-derives kcal/P/C/F at the new weight (doubling grams doubles macros).
///
/// Guards: when the original portion is unknown (`grams <= 0`) there's no
/// per-gram rate to scale from, so the macros are kept as-is (only the grams
/// label updates). A non-positive [newGrams] leaves the food unchanged.
ScannedFood rescaleScannedFood(ScannedFood f, double newGrams) {
  if (newGrams <= 0) return f;
  if (f.grams <= 0) return f.copyWith(grams: newGrams);
  final ratio = newGrams / f.grams;
  return ScannedFood(
    name: f.name,
    grams: newGrams,
    kcal: f.kcal * ratio,
    protein: f.protein * ratio,
    carbs: f.carbs * ratio,
    fat: f.fat * ratio,
    confidence: f.confidence,
  );
}

/// Thrown for user-facing failures (network, quota, config). [message] is safe
/// to show directly in a SnackBar/dialog.
class GeminiException implements Exception {
  final String message;
  const GeminiException(this.message);
  @override
  String toString() => message;
}

/// Sends a meal photo to Gemini (free-tier Flash, vision) and returns the
/// recognised foods with portion + macros. Key is injected at build time via
/// `--dart-define GEMINI_API_KEY_B64=...` (never committed) — mirrors HF_TOKEN.
class GeminiVisionService {
  // Base64-encoded at CI injection time so the raw key isn't a plaintext,
  // grep-able string inside the compiled APK. Same key, same behavior —
  // decoded once at first use.
  static const String _keyB64 = String.fromEnvironment('GEMINI_API_KEY_B64');
  static String get _key =>
      _keyB64.isEmpty ? '' : utf8.decode(base64.decode(_keyB64));
  static const String _model = 'gemini-2.5-flash';
  static const Duration _timeout = Duration(seconds: 30);

  /// True when a key is compiled in. When false the UI hides/disables the scan.
  static bool get isConfigured => _key.isNotEmpty;

  // Tight, structured prompt → accurate names, per-portion macros, and a
  // realistic gram estimate. Indian-food aware. JSON is enforced by
  // response_mime_type so parsing is reliable.
  static const String _prompt = '''
You are a meticulous nutrition vision expert analysing ONE photo of a meal (often Indian food). Estimate what a person would actually eat and log it accurately.

Identify EVERY distinct food or drink item that is actually eaten.

PORTION ESTIMATION (this is the hard part — do it carefully):
- Use real-world scale references you can see: the plate/thali diameter (~26 cm),
  bowl/katori size (~120-200 ml), spoon, roti (~15-18 cm), hand, glass/cup.
- Estimate VOLUME, not just top area. Judge the DEPTH of the food: a curry in a
  katori has height; rice is usually mounded, not flat; a heaped plate is 1.5-2x
  a level one. A bowl looking "full" from above still has a rounded/heaped top.
- Convert volume to grams using that food's typical cooked density
  (rice ~0.8 g/ml, dal/curry ~1.0, dry sabzi ~0.6, thick gravy ~1.1).
- Count discrete items exactly (3 chapatis, 2 idlis, 4 pakoras) — don't guess "some".
- "grams" = the EDIBLE cooked weight of that portion (exclude bone, peel, seeds, water left in a glass).

MACRO ESTIMATION:
- Give "kcal", "protein_g", "carb_g", "fat_g" for THAT estimated portion, NOT per 100 g.
- Account for cooking method and HIDDEN fats/sugars: deep-fried (+oil), tempering/tadka,
  ghee on rotis, paneer/cream/coconut in gravies, sugar in chai/sweets/lassi.
  A restaurant/oily version has more fat than a plain home version.
- Sanity-check every item: kcal should be within ~15% of protein*4 + carb_g*4 + fat_g*9.
  Adjust the macros until they are internally consistent for the portion.
- Prefer realistic Indian values (e.g. 1 medium chapati ~70-80 kcal, 1 katori dal ~120-150 kcal,
  1 cup rice ~200 kcal, 1 masala dosa ~380-430 kcal).

NAMING:
- "name": short, specific, common Indian name where it applies (e.g. "Dosa", "Sambar",
  "Chapati", "Paneer Butter Masala", "Curd Rice", "Chicken Biryani").
- Merge one dish into one entry (a plate of rice = one "Rice"); split clearly different dishes.
- Ignore plates, cutlery, napkins, and inedible garnish.

"confidence": 0.0-1.0 for how sure you are of the identification + portion.
If there is no food in the image, return an empty array.

Output ONLY a JSON array — no prose, no markdown fences.
Schema: [{"name":string,"grams":number,"kcal":number,"protein_g":number,"carb_g":number,"fat_g":number,"confidence":number}]
''';

  /// Analyses [jpegBytes] and returns detected foods (may be empty).
  /// Throws [GeminiException] with a user-safe message on failure.
  static Future<List<ScannedFood>> analyze(Uint8List jpegBytes) async {
    if (!isConfigured) {
      throw const GeminiException('AI photo analysis isn\'t set up in this build.');
    }
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_key',
    );
    final payload = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': _prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(jpegBytes),
              }
            },
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.2,
        'response_mime_type': 'application/json',
      },
    });

    final http.Response resp;
    try {
      resp = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: payload)
          .timeout(_timeout);
    } catch (_) {
      throw const GeminiException('No connection — check your internet and try again.');
    }

    if (resp.statusCode == 429) {
      throw const GeminiException('AI is busy right now. Please try again in a minute.');
    }
    if (resp.statusCode == 400 || resp.statusCode == 403) {
      throw const GeminiException('AI photo analysis is unavailable (key/quota issue).');
    }
    if (resp.statusCode != 200) {
      throw GeminiException('Analysis failed (${resp.statusCode}). Try again.');
    }

    final text = _extractText(jsonDecode(resp.body));
    if (text == null || text.trim().isEmpty) return const [];
    return _parseFoods(text);
  }

  /// Test hook — parse a raw model text response into foods.
  @visibleForTesting
  static List<ScannedFood> parseForTest(String modelText) =>
      _parseFoods(modelText);

  static String? _extractText(dynamic decoded) {
    try {
      final cands = (decoded as Map)['candidates'] as List?;
      if (cands == null || cands.isEmpty) return null;
      final parts = (cands.first['content']?['parts']) as List?;
      if (parts == null || parts.isEmpty) return null;
      return parts.first['text'] as String?;
    } catch (_) {
      return null;
    }
  }

  static List<ScannedFood> _parseFoods(String text) {
    var s = text.trim();
    final start = s.indexOf('[');
    final end = s.lastIndexOf(']');
    if (start == -1 || end == -1 || end < start) return const [];
    s = s.substring(start, end + 1);

    final List list;
    try {
      list = jsonDecode(s) as List;
    } catch (_) {
      return const [];
    }

    double num0(dynamic v) => (v is num) ? v.toDouble() : (double.tryParse('$v') ?? 0);
    final out = <ScannedFood>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      final kcal = num0(raw['kcal']);
      if (kcal <= 0 || kcal > 5000) continue; // reject junk
      out.add(ScannedFood(
        name: name,
        grams: num0(raw['grams']).clamp(0, 2000).toDouble(),
        kcal: kcal,
        protein: num0(raw['protein_g']).clamp(0, 300).toDouble(),
        carbs: num0(raw['carb_g']).clamp(0, 500).toDouble(),
        fat: num0(raw['fat_g']).clamp(0, 300).toDouble(),
        confidence: num0(raw['confidence']).clamp(0, 1).toDouble(),
      ));
    }
    return out;
  }
}
