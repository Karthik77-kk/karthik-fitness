import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// App-wide haptic-feedback helper.
///
/// Before this, `HapticFeedback.*` was called raw in ~10 places with no way to
/// turn it off. Everything now routes through here so a single [enabled] flag —
/// mirrored from the user's Settings toggle by `FitnessProvider` — governs the
/// whole app. Call sites use the semantic methods ([selection], [tap],
/// [success], …) instead of raw impacts so intensity stays consistent.
///
/// [enabled] is a plain static so the deepest widget can fire a haptic without
/// threading the provider through its constructor. The provider keeps it in sync
/// on load and whenever the toggle changes.
abstract final class Haptics {
  /// When false every method below is a no-op. Kept in sync with the persisted
  /// `'haptics_enabled'` setting; defaults to on.
  static bool enabled = true;

  /// Discrete selection change — tab switch, chip pick, segment toggle, stepper
  /// tick, picker scroll.
  static void selection() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
  }

  /// A light tap — buttons, list-row taps, adding a single item, +/− steppers.
  static void tap() {
    if (!enabled) return;
    HapticFeedback.lightImpact();
  }

  /// A medium tap — primary actions (log a workout, "Add all", save a goal).
  static void impact() {
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  /// Success cue for a completed action (food/workout logged, goal reached).
  static void success() {
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  /// A stronger cue — destructive confirms, notable milestones, tamper block.
  static void heavy() {
    if (!enabled) return;
    HapticFeedback.heavyImpact();
  }

  /// Warning/error pulse — invalid input, a blocked or exhausted action.
  static void warning() {
    if (!enabled) return;
    HapticFeedback.heavyImpact();
  }

  /// A subtle boundary tick — reaching the top/bottom of a scroll view.
  static void edge() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
  }
}

/// Wraps a subtree so that reaching a scroll boundary produces a single, subtle
/// haptic tick — the "edge" feel most polished apps have. `ScrollNotification`s
/// bubble up the tree, so one of these near the app root covers *every*
/// descendant scrollable without touching each `ListView`. The tick fires at
/// most once per drag gesture (guarded by [_firedThisGesture]) so a long
/// overscroll doesn't buzz continuously.
class HapticScroll extends StatefulWidget {
  final Widget child;
  const HapticScroll({super.key, required this.child});

  @override
  State<HapticScroll> createState() => _HapticScrollState();
}

class _HapticScrollState extends State<HapticScroll> {
  bool _firedThisGesture = false;

  bool _onNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      _firedThisGesture = false;
    } else if (n is OverscrollNotification && !_firedThisGesture) {
      _firedThisGesture = true;
      Haptics.edge();
    }
    return false; // keep letting the notification bubble
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}
