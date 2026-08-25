import 'package:flutter/widgets.dart';

/// Post taxonomy — single source of truth for category pickers.
///
/// Mirrors migrations/0101/0103/0108 (post_categories + post_tag_catalog).
/// The server also serves GET /api/posts/categories; this local registry is
/// the offline fallback and the structural contract (kind drives form
/// branches). Adding a category: INSERT a row server-side + add an entry
/// here.

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
    label: '讨论',
    labelEn: 'Discussion',
    kind: 'discussion',
  ),
  PostCategory(key: 'event', label: '活动', labelEn: 'Event', kind: 'discussion'),
  PostCategory(
    key: 'recruit',
    label: '召集',
    labelEn: 'Recruit',
    kind: 'discussion',
  ),
  PostCategory(key: 'help', label: '求助', labelEn: 'Help', kind: 'discussion'),
  PostCategory(key: 'lost', label: '寻物', labelEn: 'Lost', kind: 'discussion'),
  PostCategory(key: 'found', label: '招领', labelEn: 'Found', kind: 'discussion'),
  PostCategory(
    key: 'announcement',
    label: '公告',
    labelEn: 'Notice',
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

/// Locale-aware category label (zh default, en fallback to English name).
String postCategoryLabel(BuildContext context, String key) {
  final category = postCategoryByKey(key);
  if (category == null) return key;
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return isZh ? category.label : category.labelEn;
}

/// Curated tag catalog — mirrors migrations/0100+0106+0108.
class PostTag {
  const PostTag({
    required this.key,
    required this.label,
    required this.labelEn,
    this.emoji,
    this.group,
    this.categories = const [],
  });

  final String key;
  final String label;
  final String labelEn;
  final String? emoji;

  /// Grouped tags allow one pick per group.
  final String? group;

  /// Empty = unrestricted; non-empty = only these categories may use it.
  final List<String> categories;

  bool allowedIn(String categoryKey) =>
      categories.isEmpty || categories.contains(categoryKey);

  bool get exclusive => group != null;
}

const List<PostTag> kPostTags = [
  PostTag(
    key: 'question',
    label: '提问',
    labelEn: 'Question',
    emoji: '❓',
    categories: ['discussion', 'help'],
  ),
  PostTag(
    key: 'help',
    label: '求助·有偿',
    labelEn: 'Paid help',
    emoji: '💰',
    categories: ['help', 'wanted'],
  ),
  PostTag(key: 'share', label: '分享', labelEn: 'Share', emoji: '✨'),
  PostTag(
    key: 'negotiable',
    label: '可议价',
    labelEn: 'Negotiable',
    emoji: '🤝',
    categories: ['offer'],
  ),
  PostTag(
    key: 'pickupOnly',
    label: '仅自提',
    labelEn: 'Pickup only',
    emoji: '📍',
    categories: ['offer', 'wanted'],
  ),
  PostTag(
    key: 'sellFast',
    label: '急出',
    labelEn: 'Sell fast',
    emoji: '⚡',
    categories: ['offer'],
  ),
  PostTag(
    key: 'budgetFlexible',
    label: '预算可议',
    labelEn: 'Flexible budget',
    emoji: '💬',
    categories: ['wanted', 'help'],
  ),
  PostTag(
    key: 'topPrice',
    label: '高价收',
    labelEn: 'Top price',
    emoji: '💎',
    categories: ['wanted'],
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

/// Locale-aware tag label with its emoji prefix.
String postTagLabel(BuildContext context, String key) {
  final matches = kPostTags.where((tag) => tag.key == key).toList();
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
