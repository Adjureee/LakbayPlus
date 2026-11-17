import 'dart:ui';

import 'package:flutter/material.dart';

import '../lakbay_tokens.dart';
import '../lakbay_type.dart';

enum LkButtonVariant { primary, secondary, ghost }

enum LkButtonSize {
  /// 48dp tall: inline actions (Save trip, Adjust).
  medium(48, 14),

  /// 58dp tall: the one main action on a screen (Start planning, Directions).
  large(58, 20);

  const LkButtonSize(this.height, this.radius);
  final double height;
  final double radius;
}

/// Lakbay+ button. Primary is mango: use one per screen region.
class LkButton extends StatelessWidget {
  const LkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = LkButtonVariant.primary,
    this.size = LkButtonSize.medium,
    this.expand = false,
    this.loading = false,
    this.trailingArrow = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final LkButtonVariant variant;
  final LkButtonSize size;
  final bool expand;
  final bool loading;

  /// Welcome-style CTA: label left, dark square with an arrow on the right.
  final bool trailingArrow;
  final String? semanticLabel;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, BorderSide? side) = switch (variant) {
      LkButtonVariant.primary => (LkColors.mango, LkColors.mangoInk, null),
      LkButtonVariant.secondary => (
        LkColors.s2,
        LkColors.text,
        const BorderSide(color: LkColors.stroke),
      ),
      LkButtonVariant.ghost => (Colors.transparent, LkColors.text, null),
    };
    final radius = BorderRadius.circular(size.radius);
    final isPrimary = variant == LkButtonVariant.primary;

    final Widget content;
    if (loading) {
      content = SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
      );
    } else if (trailingArrow) {
      content = Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: LkType.button.copyWith(color: fg, fontSize: 17),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isPrimary ? LkColors.mangoInk : LkColors.s3,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              color: isPrimary ? LkColors.mango : LkColors.text,
            ),
          ),
        ],
      );
    } else {
      content = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: LkSpace.s),
          ],
          Flexible(
            child: Text(
              label,
              style: LkType.button.copyWith(
                color: fg,
                fontSize: size == LkButtonSize.large ? 16 : 14,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      );
    }

    final button = Semantics(
      button: true,
      enabled: _enabled,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: LkMotion.of(context).duration(LkMotion.fast),
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: side ?? BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _enabled ? onPressed : null,
            // Sized by its content (at least [size.height] tall), never by
            // spare room: a Container with alignment would fill any loose
            // height it is given, such as a Scaffold bottom bar's.
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: size.height),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  trailingArrow ? 22 : 18,
                  0,
                  trailingArrow ? 7 : 18,
                  0,
                ),
                child: Center(
                  heightFactor: 1,
                  widthFactor: expand ? null : 1,
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final shadowed = isPrimary && size == LkButtonSize.large && _enabled
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: LkShadow.mangoGlow,
            ),
            child: button,
          )
        : button;

    return expand
        ? SizedBox(width: double.infinity, child: shadowed)
        : shadowed;
  }
}

enum LkIconButtonStyle {
  /// Solid surface (s1), for app bars on plain backgrounds.
  solid,

  /// Frosted glass, for buttons sitting on photos and maps.
  glass,

  /// No background.
  plain,
}

/// 48x48 icon button. [tooltip] is required and is the screen reader label.
class LkIconButton extends StatelessWidget {
  const LkIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.style = LkIconButtonStyle.solid,
    this.showBadge = false,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final LkIconButtonStyle style;

  /// Small mango dot, e.g. unread notifications.
  final bool showBadge;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(LkRadius.sm);
    Widget body = SizedBox.square(
      dimension: kLkMinTarget,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon, color: color ?? LkColors.text, size: 22),
          if (showBadge)
            Positioned(
              top: 12,
              right: 13,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: LkColors.mango,
                  shape: BoxShape.circle,
                  border: Border.all(color: LkColors.s1, width: 2),
                ),
              ),
            ),
        ],
      ),
    );

    final decoration = switch (style) {
      LkIconButtonStyle.solid => BoxDecoration(
        color: LkColors.s1,
        borderRadius: radius,
        border: Border.all(color: LkColors.stroke),
      ),
      LkIconButtonStyle.glass => BoxDecoration(
        color: LkColors.glassDark,
        borderRadius: radius,
        border: Border.all(color: LkColors.glassDarkBorder),
      ),
      LkIconButtonStyle.plain => null,
    };

    body = Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Ink(decoration: decoration, child: body),
      ),
    );

    if (style == LkIconButtonStyle.glass) {
      body = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: body,
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: body,
      ),
    );
  }
}
