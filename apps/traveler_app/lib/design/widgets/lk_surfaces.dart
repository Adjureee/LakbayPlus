import 'dart:ui';

import 'package:flutter/material.dart';

import '../lakbay_tokens.dart';
import '../lakbay_type.dart';

/// Frosted panel for content that sits on photos or maps.
class LkGlass extends StatelessWidget {
  const LkGlass({
    super.key,
    required this.child,
    this.dark = true,
    this.surface = false,
    this.borderRadius = LkRadius.chipAll,
    this.padding,
  });

  final Widget child;

  /// Dark glass (more legible) or light glass (subtler, for big photos).
  final bool dark;

  /// Glass that sits on the page, not on a photo (the tab bar): it follows
  /// the theme, so it is pale in light mode.
  final bool surface;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: surface
                ? (LkColors.isDark
                      ? LkColors.glassDark
                      : LkColors.s1.withValues(alpha: 0.92))
                : (dark ? LkColors.glassDark : LkColors.glassLight),
            borderRadius: borderRadius,
            border: Border.all(
              color: surface
                  ? (LkColors.isDark ? LkColors.glassDarkBorder : LkColors.stroke)
                  : (dark
                        ? LkColors.glassDarkBorder
                        : LkColors.glassLightBorder),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Small glass label on a photo: "Sat 22 Nov", "4 people", "₱2,100 each".
class LkGlassChip extends StatelessWidget {
  const LkGlassChip({
    super.key,
    required this.label,
    this.icon,
    this.dark = false,
  });

  final String label;
  final IconData? icon;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return LkGlass(
      dark: dark,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: LkColors.mango),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: LkType.label.copyWith(fontSize: 12.5, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// Solid tag on a photo ("Next trip", "In 5 days").
class LkTag extends StatelessWidget {
  const LkTag(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: LkColors.mango,
        borderRadius: LkRadius.chipAll,
      ),
      child: Text(
        label,
        style: LkType.label.copyWith(fontSize: 12, color: LkColors.mangoInk),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: LkColors.s2,
      child: Icon(Icons.landscape_outlined, color: LkColors.faint, size: 32),
    );
  }
}

/// Full-bleed photo card with a bottom scrim and white text.
class LkPhotoCard extends StatelessWidget {
  const LkPhotoCard({
    super.key,
    required this.image,
    this.fallbackImage,
    required this.title,
    this.subtitle,
    this.width,
    this.height = 132,
    this.borderRadius = LkRadius.mdAll,
    this.titleStyle,
    this.topLeft,
    this.topRight,
    this.footer,
    this.onTap,
  });

  final ImageProvider image;

  /// Shown when [image] fails to load (offline, missing remote photo).
  final ImageProvider? fallbackImage;
  final String title;
  final String? subtitle;
  final double? width;
  final double height;
  final BorderRadius borderRadius;
  final TextStyle? titleStyle;
  final Widget? topLeft;
  final Widget? topRight;

  /// Extra content under the title (route line, glass chips).
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: subtitle == null ? title : '$title, $subtitle',
      excludeSemantics: topRight == null,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Material(
            color: LkColors.s2,
            child: InkWell(
              onTap: onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(
                    image: image,
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => fallbackImage == null
                        ? const _PhotoPlaceholder()
                        : Image(
                            image: fallbackImage!,
                            fit: BoxFit.cover,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) =>
                                const _PhotoPlaceholder(),
                          ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(gradient: LkColors.photoScrim),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              titleStyle ??
                              LkType.itemTitle.copyWith(
                                fontSize: 13.5,
                                color: Colors.white,
                                height: 1.15,
                              ),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: LkType.micro.copyWith(
                                color: const Color(0xFFBFD6D3),
                              ),
                            ),
                          ),
                        ?footer,
                      ],
                    ),
                  ),
                  if (topLeft != null)
                    Positioned(top: 12, left: 12, child: topLeft!),
                  if (topRight != null)
                    Positioned(top: 10, right: 10, child: topRight!),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Explore Region XI ........ See all"
class LkSectionHeader extends StatelessWidget {
  const LkSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(
      LkSpace.gutter,
      LkSpace.xl,
      LkSpace.s,
      LkSpace.s,
    ),
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: LkType.section),
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// A plan problem with one fix: "Closes 5:00 PM, arrive 5:10 · Move earlier".
class LkWarningRow extends StatelessWidget {
  const LkWarningRow({
    super.key,
    required this.title,
    required this.message,
    this.leading,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final Widget? leading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Warning',
      child: Container(
        padding: const EdgeInsets.all(LkSpace.m),
        decoration: BoxDecoration(
          color: LkColors.mangoSoft,
          borderRadius: LkRadius.mdAll,
          border: Border.all(color: LkColors.mango.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            leading ??
                Icon(
                  Icons.schedule_rounded,
                  color: LkColors.mangoText,
                  size: 22,
                ),
            const SizedBox(width: LkSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: LkType.itemTitle),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    style: LkType.caption.copyWith(color: LkColors.mangoText),
                  ),
                ],
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: LkSpace.s),
              Semantics(
                button: true,
                child: Material(
                  color: LkColors.mango,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: onAction,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: kLkMinTarget,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            actionLabel!,
                            style: LkType.label.copyWith(
                              color: LkColors.mangoInk,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
