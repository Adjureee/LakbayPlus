import 'package:flutter/material.dart';

import '../lakbay_tokens.dart';
import '../lakbay_type.dart';
import 'lk_surfaces.dart';

class LkNavItem {
  const LkNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// The floating five-tab bar from v8. Each tab is a 48dp+ target announced
/// as "Trips, tab 1 of 5, selected".
///
/// Use it as `Scaffold.bottomNavigationBar` with `extendBody: true` so the
/// content scrolls behind it and snackbars sit above it.
class LkFloatingNavBar extends StatelessWidget {
  const LkFloatingNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onSelected,
  });

  final List<LkNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  /// Height of the bar itself. With `extendBody: true` the Scaffold adds the
  /// bar's full height to `MediaQuery.paddingOf(context).bottom` for the
  /// body, so scrolling screens pad by that value to clear the bar.
  static const double height = 68;
  static const double bottomMargin = 22;

  @override
  Widget build(BuildContext context) {
    final motion = LkMotion.of(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, bottomMargin),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: LkShadow.floating,
        ),
        child: LkGlass(
          surface: true,
          borderRadius: BorderRadius.circular(26),
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == currentIndex,
                      button: true,
                      label:
                          '${items[i].label}, tab ${i + 1} of ${items.length}',
                      excludeSemantics: true,
                      child: InkResponse(
                        onTap: () => onSelected(i),
                        radius: 36,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: motion.duration(LkMotion.base),
                              curve: LkMotion.standard,
                              width: i == currentIndex ? 54 : 40,
                              height: 30,
                              decoration: BoxDecoration(
                                color: i == currentIndex
                                    ? LkColors.mango
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(15),
                                boxShadow: i == currentIndex
                                    ? [
                                        BoxShadow(
                                          color: LkColors.mango.withValues(
                                            alpha: 0.35,
                                          ),
                                          blurRadius: 16,
                                          offset: const Offset(0, 6),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Icon(
                                i == currentIndex
                                    ? items[i].selectedIcon
                                    : items[i].icon,
                                size: 24,
                                color: i == currentIndex
                                    ? LkColors.mangoInk
                                    : LkColors.muted,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              items[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: LkType.micro.copyWith(
                                color: i == currentIndex
                                    ? LkColors.text
                                    : LkColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom action area (Directions, Add to trip) with a fade so list content
/// scrolls under it cleanly. Place it in a Stack aligned to the bottom.
class LkStickyActionBar extends StatelessWidget {
  const LkStickyActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x0004191C), LkColors.bg],
          stops: [0, 0.45],
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 40, 14, 22),
        child: child,
      ),
    );
  }
}
