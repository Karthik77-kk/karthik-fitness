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

/// Wraps a subtree so scrolling *feels* textured — a light tick every ~[_tickPx]
/// logical pixels while the finger is down (the dynamic, iOS-picker-like scroll
/// haptic), plus a single subtle tick when a boundary is reached. `ScrollNotification`s
/// bubble up the tree, so one of these near the app root covers *every*
/// descendant scrollable without touching each `ListView`.
///
/// Design choices that keep it feeling premium, not annoying:
/// - Ticks only during an active drag (`dragDetails != null`); momentum flings
///   stay silent, so the app doesn't buzz continuously after you let go.
/// - Distance-throttled ([_tickPx]) *and* time-throttled ([_minGapMs]) so a fast
///   flick produces a crisp cadence rather than a machine-gun rattle.
/// - The edge tick fires at most once per gesture ([_firedThisGesture]).
/// - Everything routes through [Haptics], so the Settings toggle silences it.
class HapticScroll extends StatefulWidget {
  final Widget child;
  const HapticScroll({super.key, required this.child});

  @override
  State<HapticScroll> createState() => _HapticScrollState();
}

class _HapticScrollState extends State<HapticScroll> {
  /// Logical pixels of drag between scroll ticks.
  static const double _tickPx = 42;

  /// Floor on the gap between ticks so a fast flick can't rattle.
  static const int _minGapMs = 18;

  bool _firedThisGesture = false;
  double _accum = 0; // px dragged since the last scroll tick
  int _lastTickMs = 0;

  bool _onNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      _firedThisGesture = false;
      _accum = 0;
    } else if (n is ScrollUpdateNotification) {
      // Only while the finger is actually dragging — not during fling inertia.
      if (n.dragDetails != null) {
        _accum += (n.scrollDelta ?? 0).abs();
        if (_accum >= _tickPx) {
          _accum = 0;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastTickMs >= _minGapMs) {
            _lastTickMs = now;
            Haptics.selection();
          }
        }
      }
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
