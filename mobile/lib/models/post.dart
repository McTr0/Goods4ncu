import 'models.dart';

class PostAuthor {
  const PostAuthor({required this.id, required this.username, this.avatarUrl});

  final String id;
  final String username;
  final String? avatarUrl;

  factory PostAuthor.fromJson(dynamic value) {
    final json = value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
    return PostAuthor(
      id: json['id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      avatarUrl: json['avatar_url']?.toString(),
    );
  }
}

/// Unified campus post. [category] IS the kind: offer(出) / wanted(收) /
/// discussion(讨论). Listings are optional references via [listingId].
class CampusPost {
  const CampusPost({
    required this.id,
    required this.category,
    required this.title,
    required this.author,
    required this.replyCount,
    required this.status,
    required this.isLocked,
    this.errandMetadata = const {},
    this.resolutionStatus = 'open',
    this.canUpdateResolution = false,
    required this.createdAt,
    required this.updatedAt,
    required this.lastActivityAt,
    this.spaceId,
    this.body,
    this.bodyExcerpt,
    this.tags = const [],
    this.listingId,
    this.coverImageUrl,
    this.listing,
    this.rankReason,
    this.rankSource,
    this.rankingScore,
  });

  final String id;

  /// offer | wanted | discussion.
  final String category;
  final String? spaceId;
  final String title;
  final String? body;
  final String? bodyExcerpt;
  final List<String> tags;
  final String? listingId;
  final String? coverImageUrl;
  final PostAuthor author;
  final int replyCount;
  final String status;
  final bool isLocked;
  final Map<String, dynamic> errandMetadata;
  final String resolutionStatus;
  final bool canUpdateResolution;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastActivityAt;

  /// Present only for the rolling-upgrade listing fallback. Posts returned by
  /// `/api/posts` carry [listingId] and fetch the listing on demand.
  final Listing? listing;
  final String? rankReason;
  final String? rankSource;
  final double? rankingScore;

  bool get isOffer => category == 'offer';
  bool get isWanted => category == 'wanted';
  bool get isErrand => tags.contains('errand');

  String get displayBody {
    final text = (body ?? bodyExcerpt ?? '').trim();
    return text;
  }

  /// Returns a copy with only the supplied fields changed.
  ///
  /// Posts are also updated optimistically after a reply is submitted. Keeping
  /// that update in one place prevents newer feed metadata (for example a
  /// listing preview or ranking explanation) from being dropped while the
  /// reply count is refreshed.
  CampusPost copyWith({
    String? id,
    String? category,
    String? title,
    String? body,
    String? bodyExcerpt,
    List<String>? tags,
    String? listingId,
    String? spaceId,
    String? coverImageUrl,
    PostAuthor? author,
    int? replyCount,
    String? status,
    bool? isLocked,
    Map<String, dynamic>? errandMetadata,
    String? resolutionStatus,
    bool? canUpdateResolution,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastActivityAt,
    Listing? listing,
    String? rankReason,
    String? rankSource,
    double? rankingScore,
  }) {
    return CampusPost(
      id: id ?? this.id,
      category: category ?? this.category,
      title: title ?? this.title,
      body: body ?? this.body,
      bodyExcerpt: bodyExcerpt ?? this.bodyExcerpt,
      tags: tags ?? this.tags,
      listingId: listingId ?? this.listingId,
      spaceId: spaceId ?? this.spaceId,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      author: author ?? this.author,
      replyCount: replyCount ?? this.replyCount,
      status: status ?? this.status,
      isLocked: isLocked ?? this.isLocked,
      errandMetadata: errandMetadata ?? this.errandMetadata,
      resolutionStatus: resolutionStatus ?? this.resolutionStatus,
      canUpdateResolution: canUpdateResolution ?? this.canUpdateResolution,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      listing: listing ?? this.listing,
      rankReason: rankReason ?? this.rankReason,
      rankSource: rankSource ?? this.rankSource,
      rankingScore: rankingScore ?? this.rankingScore,
    );
  }

  factory CampusPost.fromJson(Map<String, dynamic> json) {
    final listingJson = json['listing'];
    final listing = listingJson is Map
        ? Listing.fromJson(Map<String, dynamic>.from(listingJson))
        : null;
    // Unified wire: category IS the kind; default keeps old test fixtures working.
    final category = (json['category']?.toString() ?? 'discussion').trim();
    final resolvedCategory =
        const {'offer', 'wanted', 'discussion'}.contains(category)
        ? category
        : 'discussion';
    return CampusPost(
      id: json['id']?.toString() ?? '',
      category: resolvedCategory,
      spaceId: _nullableString(json['space_id']),
      title: json['title']?.toString() ?? '',
      body: _nullableString(json['body']),
      bodyExcerpt: _nullableString(json['body_excerpt']),
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .where((value) => value.trim().isNotEmpty)
          .toList(growable: false),
      listingId: _nullableString(json['listing_id']),
      coverImageUrl:
          _nullableString(json['cover_image_url']) ?? listing?.imageUrl,
      author: PostAuthor.fromJson(json['author']),
      replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'active',
      isLocked: json['is_locked'] == true,
      errandMetadata: json['errand_metadata'] is Map
          ? Map<String, dynamic>.from(json['errand_metadata'] as Map)
          : const {},
      resolutionStatus: json['resolution_status']?.toString() ?? 'open',
      canUpdateResolution: json['can_update_resolution'] == true,
      createdAt: _dateTime(json['created_at']),
      updatedAt: _dateTime(json['updated_at']),
      lastActivityAt: _dateTime(json['last_activity_at']),
      listing: listing,
      rankReason: _nullableString(json['rank_reason']),
      rankSource: _nullableString(json['rank_source']),
      rankingScore: (json['ranking_score'] as num?)?.toDouble(),
    );
  }

  /// Keeps older servers useful while the unified posts endpoint rolls out.
  /// A listing fallback still behaves like a listing card and links directly
  /// to the established marketplace detail screen.
  factory CampusPost.fromListing(Listing listing) {
    final createdAt = _dateTime(listing.createdAt);
    return CampusPost(
      id: 'listing-${listing.id}',
      category: listing.direction == 'wanted' ? 'wanted' : 'offer',
      title: listing.title,
      bodyExcerpt: listing.description,
      tags: [
        if (listing.brand.trim().isNotEmpty) listing.brand.trim(),
        listing.direction,
      ],
      listingId: listing.id,
      coverImageUrl: listing.imageUrl,
      author: PostAuthor(
        id: listing.ownerId ?? '',
        username: listing.ownerUsername ?? '',
      ),
      replyCount: 0,
      status: listing.status,
      isLocked: listing.status != 'active' || listing.isRestricted,
      createdAt: createdAt,
      updatedAt: createdAt,
      lastActivityAt: createdAt,
      listing: listing,
      rankReason: listing.rankReason,
      rankSource: listing.source,
    );
  }
}

class PostReply {
  const PostReply({
    required this.id,
    required this.postId,
    required this.body,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
    this.replyToId,
  });

  final String id;
  final String postId;
  final String body;
  final String? replyToId;
  final PostAuthor author;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory PostReply.fromJson(Map<String, dynamic> json) {
    return PostReply(
      id: json['id']?.toString() ?? '',
      postId: json['post_id']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      replyToId: _nullableString(json['reply_to_id']),
      author: PostAuthor.fromJson(json['author']),
      createdAt: _dateTime(json['created_at']),
      updatedAt: _dateTime(json['updated_at']),
    );
  }
}

class PostsResponse {
  const PostsResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    this.rankingVersion,
  });

  final List<CampusPost> items;
  final int total;
  final int limit;
  final int offset;
  final String? rankingVersion;

  factory PostsResponse.fromJson(Map<String, dynamic> json) {
    return PostsResponse(
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((value) => CampusPost.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: false),
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 20,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      rankingVersion: _nullableString(json['ranking_version']),
    );
  }
}

class PostRepliesResponse {
  const PostRepliesResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<PostReply> items;
  final int total;
  final int limit;
  final int offset;

  factory PostRepliesResponse.fromJson(Map<String, dynamic> json) {
    return PostRepliesResponse(
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((value) => PostReply.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: false),
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 50,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

String? _nullableString(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

DateTime? _dateTime(dynamic value) {
  final text = value?.toString();
  return text == null ? null : DateTime.tryParse(text)?.toLocal();
}
