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
];

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
    required this.categories,
  });

  final String key;
  final String label;
  final List<String> categories;

  bool allowedIn(String categoryKey) =>
      categories.isEmpty || categories.contains(categoryKey);
}

const List<PostTag> kPostTags = [
  PostTag(key: 'question', label: '提问', categories: []),
  PostTag(key: 'share', label: '分享', categories: []),
  PostTag(key: 'help', label: '求助', categories: []),
  PostTag(key: 'urgent', label: '急', categories: []),
  PostTag(key: 'longterm', label: '长期有效', categories: []),
  PostTag(key: 'event', label: '活动', categories: []),
  PostTag(key: 'negotiable', label: '可议价', categories: ['offer']),
  PostTag(key: 'freeShipping', label: '包邮', categories: ['offer']),
  PostTag(key: 'pickupOnly', label: '仅自提', categories: ['offer']),
  PostTag(key: 'brandNew', label: '全新', categories: ['offer']),
  PostTag(key: 'likeNew', label: '九成新', categories: ['offer']),
  PostTag(key: 'sellFast', label: '急出', categories: ['offer']),
  PostTag(key: 'budgetFlexible', label: '预算可议', categories: ['wanted']),
  PostTag(key: 'topPrice', label: '高价收', categories: ['wanted']),
  PostTag(key: 'usedOk', label: '接受二手', categories: ['wanted']),
];
