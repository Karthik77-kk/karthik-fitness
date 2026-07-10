import 'package:flutter/material.dart';
import '../../services/haptics.dart';
import '../../theme/app_tokens.dart';

/// A ripple wrapper for the many small tap targets (chips, +/− buttons, presets)
/// that previously used a bare [GestureDetector] and so felt "dead". Gives a
/// Material ink ripple clipped to [borderRadius], with an optional selection
/// haptic.
///
/// Pass [decoration] (and optional [padding]) to replace a tappable
/// `Container(decoration: …)`: the decoration is painted via [Ink] so the ripple
/// renders *on top* of it (a plain InkWell behind an opaque Container shows no
/// splash). Use [AppCard] for full cards; this is for everything smaller.
///
/// When tappable, the widget sinks slightly under the finger (0.97 scale) for a
/// tactile "press-to-lift" feel. The animation is suppressed when the OS
/// reduce-motion setting is active.
class AppTappable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final bool haptic;
  final Decoration? decoration;
  final EdgeInsetsGeometry? padding;

  /// When set (e.g. `CircleBorder()`), clips the ripple to this shape instead of
  /// [borderRadius] — for circular/pill targets.
  final ShapeBorder? customBorder;

  const AppTappable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = AppRadii.rMd,
    this.haptic = true,
    this.decoration,
    this.padding,
    this.customBorder,
  });

  @override
  State<AppTappable> createState() => _AppTappableState();
}

class _AppTappableState extends State<AppTappable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tap = widget.onTap == null
        ? null
        : () {
            if (widget.haptic) Haptics.selection();
            widget.onTap!();
          };
    final content = widget.padding == null
        ? widget.child
        : Padding(padding: widget.padding!, child: widget.child);
    final inkWell = InkWell(
      borderRadius: widget.customBorder == null ? widget.borderRadius : null,
      customBorder: widget.customBorder,
      onTap: tap,
      onHighlightChanged: (v) => setState(() => _pressed = v),
      child: content,
    );

    final inner = Material(
      type: MaterialType.transparency,
      child: widget.decoration == null
          ? inkWell
          : Ink(decoration: widget.decoration, child: inkWell),
    );

    final scale = reduceMotion(context) ? 1.0 : (_pressed ? 0.97 : 1.0);
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: inner,
    );
  }
}
