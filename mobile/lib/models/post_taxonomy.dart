/// Post taxonomy — single source of truth for category pickers.
///
/// Mirrors migrations/0101_post_taxonomy_v2.sql (post_categories table).
/// The server also serves GET /api/posts/categories; this local registry is
/// the offline fallback and the structural contract (kind drives form
/// branches). Adding a category: INSERT a row server-side + add an entry
/// here.
library;

class PostCategory {
  const PostCategory({
    required this.key,
    required this.label,
    required this.kind,
  });

  final String key;
  final String label;

  /// 'goods' shows listing fields; 'discussion' is plain text.
  final String kind;

  bool get isGoods => kind == 'goods';
}

const List<PostCategory> kPostCategories = [
  PostCategory(key: 'offer', label: '商品出', kind: 'goods'),
  PostCategory(key: 'wanted', label: '商品收', kind: 'goods'),
  PostCategory(key: 'discussion', label: '话题讨论', kind: 'discussion'),
  PostCategory(key: 'event', label: '活动', kind: 'discussion'),
  PostCategory(key: 'announcement', label: '公告', kind: 'discussion'),
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
  const PostTag({required this.key, required this.label, required this.group});

  final String key;
  final String label;

  /// Grouped tags allow one pick per group and don't count against the
  /// free-tag budget; null group = free multi-select.
  final String? group;

  bool get exclusive => group != null;
}

const List<PostTag> kPostTags = [
  // Free multi-select.
  PostTag(key: 'question', label: '提问', group: null),
  PostTag(key: 'help', label: '求助·有偿', group: null),
  PostTag(key: 'share', label: '分享', group: null),
  PostTag(key: 'free', label: '免费送', group: null),
  PostTag(key: 'found', label: '招领', group: null),
  PostTag(key: 'lost', label: '寻物', group: null),
  PostTag(key: 'negotiable', label: '可议价', group: null),
  PostTag(key: 'freeShipping', label: '包邮', group: null),
  PostTag(key: 'pickupOnly', label: '仅自提', group: null),
  PostTag(key: 'brandNew', label: '全新', group: null),
  PostTag(key: 'likeNew', label: '九成新', group: null),
  PostTag(key: 'sellFast', label: '急出', group: null),
  PostTag(key: 'budgetFlexible', label: '预算可议', group: null),
  PostTag(key: 'topPrice', label: '高价收', group: null),
  PostTag(key: 'usedOk', label: '接受二手', group: null),
  // Exclusive groups (one pick max each).
  PostTag(key: 'urgent', label: '急', group: 'ttl'),
  PostTag(key: 'longterm', label: '长期有效', group: 'ttl'),
  PostTag(key: 'qianhuNorth', label: '前湖北院', group: 'location'),
  PostTag(key: 'qianhuSouth', label: '前湖南院', group: 'location'),
  PostTag(key: 'qingshanhu', label: '青山湖', group: 'location'),
  PostTag(key: 'donghu', label: '东湖', group: 'location'),
];
