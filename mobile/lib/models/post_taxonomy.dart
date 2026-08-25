import 'package:flutter/widgets.dart';

/// Post taxonomy — single source of truth for category pickers.

class PostCategory {
  const PostCategory({
    required this.key,
    required this.label,
    required this.labelEn,
    required this.kind,
  });

  final String key;
  final String label;
  final String labelEn;

  /// 'goods' shows listing fields; 'discussion' is plain text.
  final String kind;

  bool get isGoods => kind == 'goods';
}

const List<PostCategory> kPostCategories = [
  PostCategory(key: 'offer', label: '出', labelEn: 'Offer', kind: 'goods'),
  PostCategory(key: 'wanted', label: '收', labelEn: 'Wanted', kind: 'goods'),
  PostCategory(
    key: 'discussion',
    label: '话题讨论',
    labelEn: 'Discussion',
    kind: 'discussion',
  ),
  PostCategory(key: 'event', label: '活动', labelEn: 'Event', kind: 'discussion'),
  PostCategory(
    key: 'announcement',
    label: '公告',
    labelEn: 'Announcement',
    kind: 'discussion',
  ),
];

bool categoryHasAttributes(String key) => key == 'event';

PostCategory? postCategoryByKey(String key) {
  for (final category in kPostCategories) {
    if (category.key == key) return category;
  }
  return null;
}

/// Curated tag catalog — mirrors migrations/0100_post_taxonomy.sql.
class PostTag {
  const PostTag({
    required this.key,
    required this.label,
    required this.labelEn,
    this.emoji,
    required this.group,
  });

  final String key;
  final String label;
  final String labelEn;
  final String? emoji;

  /// Grouped tags allow one pick per group and don't count against the
  /// free-tag budget; null group = free multi-select.
  final String? group;

  bool get exclusive => group != null;
}

const List<PostTag> kPostTags = [
  // Free multi-select.
  PostTag(
    key: 'question',
    label: '提问',
    labelEn: 'Question',
    emoji: '❓',
    group: null,
  ),
  PostTag(
    key: 'help',
    label: '求助·有偿',
    labelEn: 'Paid help',
    emoji: '💰',
    group: null,
  ),
  PostTag(key: 'share', label: '分享', labelEn: 'Share', emoji: '✨', group: null),
  PostTag(key: 'free', label: '免费送', labelEn: 'Free', emoji: '🎁', group: null),
  PostTag(
    key: 'found',
    label: '招领',
    labelEn: 'Found',
    emoji: '📣',
    group: null,
  ),
  PostTag(key: 'lost', label: '寻物', labelEn: 'Lost', emoji: '🔍', group: null),
  PostTag(
    key: 'negotiable',
    label: '可议价',
    labelEn: 'Negotiable',
    emoji: '🤝',
    group: null,
  ),
  PostTag(
    key: 'pickupOnly',
    label: '仅自提',
    labelEn: 'Pickup only',
    emoji: '📍',
    group: null,
  ),
  PostTag(
    key: 'sellFast',
    label: '急出',
    labelEn: 'Sell fast',
    emoji: '⚡',
    group: null,
  ),
  PostTag(
    key: 'budgetFlexible',
    label: '预算可议',
    labelEn: 'Flexible budget',
    emoji: '💬',
    group: null,
  ),
  PostTag(
    key: 'topPrice',
    label: '高价收',
    labelEn: 'Top price',
    emoji: '💎',
    group: null,
  ),
  // Exclusive groups (one pick max each).
  PostTag(
    key: 'urgent',
    label: '急',
    labelEn: 'Urgent',
    emoji: '⏰',
    group: 'ttl',
  ),
  PostTag(
    key: 'longterm',
    label: '长期有效',
    labelEn: 'Long term',
    emoji: '♾️',
    group: 'ttl',
  ),
  PostTag(
    key: 'qianhuNorth',
    label: '前湖北院',
    labelEn: 'Qianhu North',
    emoji: '📍',
    group: 'location',
  ),
  PostTag(
    key: 'qianhuSouth',
    label: '前湖南院',
    labelEn: 'Qianhu South',
    emoji: '📍',
    group: 'location',
  ),
  PostTag(
    key: 'qingshanhu',
    label: '青山湖',
    labelEn: 'Qingshanhu',
    emoji: '📍',
    group: 'location',
  ),
  PostTag(
    key: 'donghu',
    label: '东湖',
    labelEn: 'Donghu',
    emoji: '📍',
    group: 'location',
  ),
];

/// Locale-aware category label (zh default, en fallback to English name).
String postCategoryLabel(BuildContext context, String key) {
  final category = postCategoryByKey(key);
  if (category == null) return key;
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return isZh ? category.label : category.labelEn;
}

/// Locale-aware tag label with its emoji prefix.
String postTagLabel(BuildContext context, String key) {
  final matches = kPostTags
      .where((tag) => tag.key == key)
      .toList(growable: false);
  if (matches.isEmpty) return '#$key';
  final tag = matches.first;
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  final text = isZh ? tag.label : tag.labelEn;
  return tag.emoji == null ? text : '${tag.emoji} $text';
}

String? postTagEmoji(String key) {
  for (final tag in kPostTags) {
    if (tag.key == key) return tag.emoji;
  }
  return null;
}
