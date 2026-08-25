import 'package:flutter/widgets.dart';

/// Post taxonomy — single source of truth for category pickers.
///
/// Mirrors migrations/0109 (post_categories table).

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
  PostCategory(
    key: 'announcement',
    label: '公告',
    labelEn: 'Announcement',
    kind: 'discussion',
  ),
  PostCategory(key: 'offer', label: '出', labelEn: 'Offer', kind: 'goods'),
  PostCategory(key: 'wanted', label: '收', labelEn: 'Wanted', kind: 'goods'),
  PostCategory(key: 'share', label: '分享', labelEn: 'Share', kind: 'discussion'),
  PostCategory(
    key: 'question',
    label: '提问',
    labelEn: 'Question',
    kind: 'discussion',
  ),
  PostCategory(
    key: 'discussion',
    label: '讨论',
    labelEn: 'Discussion',
    kind: 'discussion',
  ),
  PostCategory(
    key: 'recruit',
    label: '召集',
    labelEn: 'Recruit',
    kind: 'discussion',
  ),
  PostCategory(
    key: 'team_up',
    label: '组队',
    labelEn: 'Team Up',
    kind: 'discussion',
  ),
];

bool categoryHasAttributes(String key) => false;

PostCategory? postCategoryByKey(String key) {
  for (final category in kPostCategories) {
    if (category.key == key) return category;
  }
  return null;
}

/// Locale-aware category label.
String postCategoryLabel(BuildContext context, String key) {
  final category = postCategoryByKey(key);
  if (category == null) return key;
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return isZh ? category.label : category.labelEn;
}

/// Curated tag catalog — only location + ttl groups remain.
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

  /// Grouped tags allow one pick per group.
  final String? group;

  bool get exclusive => group != null;
}

const List<PostTag> kPostTags = [
  // ttl group
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
  // location group
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
