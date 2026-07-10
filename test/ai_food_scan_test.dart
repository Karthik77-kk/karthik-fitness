import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kfit/services/scan_quota.dart';
import 'package:kfit/services/gemini_vision_service.dart';

void main() {
  group('ScanQuota — per-user daily rate limit', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('every user is capped at dailyLimit scans/day — no exemptions', () async {
      final p = await SharedPreferences.getInstance();
      for (var i = 0; i < ScanQuota.dailyLimit; i++) {
        expect(ScanQuota.canScan(p), isTrue,
            reason: 'scan ${i + 1} should be allowed');
        await ScanQuota.record(p);
      }
      expect(ScanQuota.canScan(p), isFalse); // 11th blocked
      expect(ScanQuota.remaining(p), 0);
      expect(ScanQuota.usedToday(p), ScanQuota.dailyLimit);
    });

    test('remaining counts down with each recorded scan', () async {
      final p = await SharedPreferences.getInstance();
      await ScanQuota.record(p);
      await ScanQuota.record(p);
      expect(ScanQuota.remaining(p), ScanQuota.dailyLimit - 2);
    });
  });

  group('GeminiVisionService — response parsing', () {
    test('parses a clean JSON array', () {
      final foods = GeminiVisionService.parseForTest(
          '[{"name":"Dosa","grams":120,"kcal":168,"protein_g":4,"carb_g":30,"fat_g":3,"confidence":0.8}]');
      expect(foods, hasLength(1));
      expect(foods.first.name, 'Dosa');
      expect(foods.first.kcal, 168);
      expect(foods.first.grams, 120);
      expect(foods.first.confidence, 0.8);
    });

    test('strips markdown fences around the JSON', () {
      final foods = GeminiVisionService.parseForTest(
          '```json\n[{"name":"Rice","kcal":200,"grams":150,"protein_g":4,"carb_g":44,"fat_g":1,"confidence":0.9}]\n```');
      expect(foods.single.name, 'Rice');
    });

    test('drops unnamed and zero/over-limit-kcal items', () {
      final foods = GeminiVisionService.parseForTest(
          '[{"name":"","kcal":100},{"name":"X","kcal":0},{"name":"Big","kcal":99999},{"name":"Ok","kcal":50}]');
      expect(foods.single.name, 'Ok');
    });

    test('returns empty for no-food / non-JSON', () {
      expect(GeminiVisionService.parseForTest('[]'), isEmpty);
      expect(GeminiVisionService.parseForTest('sorry, no food here'), isEmpty);
    });

    test('clamps out-of-range macros', () {
      final foods = GeminiVisionService.parseForTest(
          '[{"name":"Junk","kcal":300,"grams":99999,"protein_g":-5,"carb_g":9999,"fat_g":50,"confidence":5}]');
      final f = foods.single;
      expect(f.grams, lessThanOrEqualTo(2000));
      expect(f.protein, greaterThanOrEqualTo(0));
      expect(f.confidence, lessThanOrEqualTo(1));
    });
  });
}
