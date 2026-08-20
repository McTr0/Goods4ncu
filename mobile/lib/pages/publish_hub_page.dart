import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../router/publish_navigation.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// The single entry point for every kind of user-created feed content.
class PublishHubPage extends StatelessWidget {
  const PublishHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final choices = [
      _PublishChoice(
        choiceKey: const ValueKey('publish-choice-discussion'),
        title: l.postCreateTitle,
        icon: Icons.forum_outlined,
        color: Theme.of(context).colorScheme.primary,
        location: PublishNavigation.discussion,
      ),
      _PublishChoice(
        choiceKey: const ValueKey('publish-choice-offer'),
        title: l.createListingModeOffer,
        icon: Icons.sell_outlined,
        color: AppTheme.accent,
        location: PublishNavigation.listing(direction: 'offer'),
      ),
      _PublishChoice(
        choiceKey: const ValueKey('publish-choice-wanted'),
        title: l.createListingModeWanted,
        icon: Icons.search_rounded,
        color: AppTheme.info,
        location: PublishNavigation.listing(direction: 'wanted'),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(l.publishTab),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.sp20),
          child: ResponsiveContent(
            maxWidth: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.postDiscoverySubtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.sp24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 680) {
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        childAspectRatio: 2.6,
                        crossAxisSpacing: AppTheme.sp16,
                        mainAxisSpacing: AppTheme.sp16,
                        children: choices,
                      );
                    }
                    return Column(
                      children: [
                        for (
                          var index = 0;
                          index < choices.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(height: AppTheme.sp12),
                          choices[index],
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PublishChoice extends StatelessWidget {
  const _PublishChoice({
    required this.choiceKey,
    required this.title,
    required this.icon,
    required this.color,
    required this.location,
  });

  final Key choiceKey;
  final String title;
  final IconData icon;
  final Color color;
  final String location;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: choiceKey,
          onTap: () => context.push(location),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 132),
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.sp20),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const SizedBox(width: AppTheme.sp16),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
