import 'package:flutter/material.dart';

import 'design.dart';

/// Debug-only gallery of the v8 design system. Opened from the
/// `/design-preview` route in debug builds.
class DesignPreviewScreen extends StatefulWidget {
  const DesignPreviewScreen({super.key});

  @override
  State<DesignPreviewScreen> createState() => _DesignPreviewScreenState();
}

class _DesignPreviewScreenState extends State<DesignPreviewScreen> {
  int _tab = 0;
  String _lastAction = 'Nothing tapped yet';

  static const _tabs = [
    LkNavItem(
      icon: Icons.luggage_outlined,
      selectedIcon: Icons.luggage,
      label: 'Trips',
    ),
    LkNavItem(
      icon: Icons.explore_outlined,
      selectedIcon: Icons.explore,
      label: 'Discover',
    ),
    LkNavItem(
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: 'Chat',
    ),
    LkNavItem(
      icon: Icons.photo_library_outlined,
      selectedIcon: Icons.photo_library,
      label: 'Memories',
    ),
    LkNavItem(
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      label: 'Profile',
    ),
  ];

  void _note(String what) => setState(() => _lastAction = what);

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: LakbayDesignTheme.dark,
      child: Builder(
        builder: (context) => Scaffold(
          extendBody: true,
          bottomNavigationBar: LkFloatingNavBar(
            items: _tabs,
            currentIndex: _tab,
            onSelected: (i) => setState(() {
              _tab = i;
              _lastAction = 'Tab: ${_tabs[i].label}';
            }),
          ),
          // Builder: read MediaQuery below the Scaffold, where the padding
          // already includes the floating tab bar.
          body: Builder(
            builder: (context) => ListView(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + LkSpace.l,
                bottom: MediaQuery.paddingOf(context).bottom + LkSpace.l,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LkSpace.gutter,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text('Design system', style: LkType.h1)),
                      LkIconButton(
                        icon: Icons.notifications_outlined,
                        tooltip: 'Notifications',
                        showBadge: true,
                        onPressed: () => _note('Notifications'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LkSpace.gutter,
                    4,
                    LkSpace.gutter,
                    0,
                  ),
                  child: Text(_lastAction, style: LkType.caption),
                ),
                const LkSectionHeader(title: 'Color'),
                const _Swatches(),
                const LkSectionHeader(title: 'Type'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LkSpace.gutter,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('5', style: LkType.countdown),
                          const SizedBox(width: LkSpace.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Maayong buntag, Ana',
                                  style: LkType.caption,
                                ),
                                Text('days to\nSamal Island', style: LkType.h2),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: LkSpace.l),
                      Text('Tell it the vibe.', style: LkType.hero),
                      const SizedBox(height: LkSpace.s),
                      Text(
                        'Real places, ferries and fares across Region XI, planned day by day in one chat.',
                        style: LkType.bodyLarge.copyWith(color: LkColors.muted),
                      ),
                    ],
                  ),
                ),
                const LkSectionHeader(title: 'Buttons'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LkSpace.gutter,
                  ),
                  child: Column(
                    children: [
                      LkButton(
                        label: 'Start planning',
                        size: LkButtonSize.large,
                        trailingArrow: true,
                        expand: true,
                        onPressed: () => _note('Start planning'),
                      ),
                      const SizedBox(height: LkSpace.m),
                      Row(
                        children: [
                          Expanded(
                            child: LkButton(
                              label: 'Save trip',
                              icon: Icons.bookmark_add_outlined,
                              expand: true,
                              onPressed: () => _note('Save trip'),
                            ),
                          ),
                          const SizedBox(width: LkSpace.s),
                          Expanded(
                            child: LkButton(
                              label: 'Adjust',
                              icon: Icons.tune_rounded,
                              variant: LkButtonVariant.secondary,
                              expand: true,
                              onPressed: () => _note('Adjust'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: LkSpace.m),
                      Row(
                        children: [
                          Expanded(
                            child: LkButton(
                              label: 'Delete a trip',
                              variant: LkButtonVariant.secondary,
                              expand: true,
                              onPressed: () async {
                                final ok = await showLkConfirm(
                                  context,
                                  title: 'Delete Samal Island Weekend?',
                                  message: 'The plan and its stops are removed from your trips.',
                                  confirmLabel: 'Delete trip',
                                );
                                if (!context.mounted) return;
                                if (ok) {
                                  _note('Trip deleted');
                                  showLkUndoSnack(
                                    context,
                                    message: 'Trip deleted',
                                    onUndo: () => _note('Delete undone'),
                                  );
                                } else {
                                  _note('Delete cancelled');
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: LkSpace.s),
                          const Expanded(
                            child: LkButton(
                              label: 'Saving',
                              loading: true,
                              expand: true,
                              onPressed: null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const LkSectionHeader(title: 'Cards', actionLabel: 'See all'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LkSpace.l),
                  child: LkPhotoCard(
                    image: const AssetImage(
                      'assets/home_backdrops/01-samal-island.jpg',
                    ),
                    title: 'Samal Island Weekend',
                    height: 232,
                    borderRadius: LkRadius.lgAll,
                    titleStyle: LkType.h2.copyWith(color: Colors.white),
                    topLeft: const LkTag('Next trip'),
                    topRight: LkIconButton(
                      icon: Icons.arrow_outward_rounded,
                      tooltip: 'Open trip',
                      style: LkIconButtonStyle.glass,
                      onPressed: () => _note('Open trip'),
                    ),
                    footer: const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          LkGlassChip(label: 'Sat 22 Nov'),
                          LkGlassChip(label: '3 days'),
                          LkGlassChip(label: '4 people'),
                          LkGlassChip(label: '₱2,100 each'),
                        ],
                      ),
                    ),
                    onTap: () => _note('Trip card'),
                  ),
                ),
                const SizedBox(height: LkSpace.m),
                SizedBox(
                  height: 132,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: LkSpace.gutter,
                    ),
                    children: [
                      for (final (img, name, kind) in const [
                        ('03-mount-apo.jpg', 'Mt. Apo', 'Mountain'),
                        ('02-dahican-mati.jpg', 'Dahican', 'Beach, Mati'),
                        ('04-eden-toril.jpg', 'Eden Park', 'Toril'),
                        ('05-aliwagwag-falls.jpg', 'Aliwagwag', 'Falls'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: LkPhotoCard(
                            image: AssetImage('assets/home_backdrops/$img'),
                            title: name,
                            subtitle: kind,
                            width: 112,
                            onTap: () => _note(name),
                          ),
                        ),
                    ],
                  ),
                ),
                const LkSectionHeader(title: 'Warnings and states'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LkSpace.l),
                  child: LkWarningRow(
                    title: 'Monfort Bat Sanctuary',
                    message: 'Closes 5:00 PM, arrive 5:10',
                    actionLabel: 'Move earlier',
                    onAction: () => _note('Move earlier'),
                  ),
                ),
                const SizedBox(height: LkSpace.l),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: LkSpace.l),
                  child: Row(
                    children: [
                      LkSkeleton(
                        width: 64,
                        height: 64,
                        borderRadius: LkRadius.mdAll,
                      ),
                      SizedBox(width: LkSpace.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LkSkeleton(width: 160, height: 16),
                            SizedBox(height: LkSpace.s),
                            LkSkeleton(width: 110, height: 12),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                LkEmptyState(
                  icon: Icons.luggage_outlined,
                  title: 'No trips yet',
                  message: 'Tell Lakbay AI where you want to go and it will plan the days for you.',
                  actionLabel: 'Plan a trip',
                  onAction: () => _note('Plan a trip'),
                ),
                LkErrorState(
                  offline: true,
                  message: 'Your saved trips are still here. New plans need a connection.',
                  onRetry: () => _note('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  const _Swatches();

  static const _swatches = [
    ('bg', LkColors.bg),
    ('s1', LkColors.s1),
    ('s2', LkColors.s2),
    ('s3', LkColors.s3),
    ('mango', LkColors.mango),
    ('lagoon', LkColors.lagoon),
    ('text', LkColors.text),
    ('muted', LkColors.muted),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LkSpace.gutter),
      child: Wrap(
        spacing: LkSpace.s,
        runSpacing: LkSpace.s,
        children: [
          for (final (name, color) in _swatches)
            Column(
              children: [
                Container(
                  width: 72,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: LkRadius.smAll,
                    border: Border.all(color: LkColors.stroke),
                  ),
                ),
                const SizedBox(height: 4),
                Text(name, style: LkType.micro),
              ],
            ),
        ],
      ),
    );
  }
}
