import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kfit/providers/fitness_provider.dart';

// The launch-time "update available" popup was chronically hidden because a
// single time-based suppression (2 h after tapping Update, 3 days after Later)
// blanket-blocked it. Now suppression is scoped to the BUILD the user acted on,
// so a genuinely newer release always prompts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<FitnessProvider> load([Map<String, Object> seed = const {}]) async {
    SharedPreferences.setMockInitialValues(seed);
    final p = FitnessProvider();
    await p.loadData();
    return p;
  }

  test('a fresh install suppresses nothing', () async {
    final p = await load();
    expect(p.shouldSuppressUpdateFor(300), isFalse);
  });

  test('"Later" snoozes that build but a NEWER release still prompts', () async {
    final p = await load();
    await p.snoozeUpdate(300);
    expect(p.shouldSuppressUpdateFor(300), isTrue); // same build → snoozed
    expect(p.shouldSuppressUpdateFor(299), isTrue); // older too
    expect(p.shouldSuppressUpdateFor(305), isFalse); // newer overrides snooze
  });

  test('tapping "Update" guards only the same build (install gap)', () async {
    final p = await load();
    await p.markUpdateInitiated(300);
    expect(p.shouldSuppressUpdateFor(300), isTrue); // mid-install, same build
    expect(p.shouldSuppressUpdateFor(305), isFalse); // newer release prompts
  });

  test('snooze state persists across a reload but stays build-scoped', () async {
    final p = await load();
    await p.snoozeUpdate(300);
    final p2 = await load({
      'update_snoozed_until_ms':
          DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
      'update_snoozed_build': 300,
    });
    expect(p2.shouldSuppressUpdateFor(300), isTrue);
    expect(p2.shouldSuppressUpdateFor(305), isFalse);
  });

  test('an expired snooze (past timestamp) suppresses nothing', () async {
    final p = await load({
      'update_snoozed_until_ms':
          DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      'update_snoozed_build': 300,
    });
    expect(p.shouldSuppressUpdateFor(300), isFalse);
  });
}
