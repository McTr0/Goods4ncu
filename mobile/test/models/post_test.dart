import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/models/post.dart';

void main() {
  test('parses a discussion post and author projection', () {
    final post = CampusPost.fromJson({
      'id': 'post-1',
      'category': 'campus-life',
      'title': 'Where can I print tonight?',
      'body_excerpt': 'The library is closed.',
      'cover_image_url': 'https://cdn.test/printing.jpg',
      'tags': ['printing', 'late-night'],
      'author': {'id': 'user-1', 'username': 'mira'},
      'reply_count': 4,
      'status': 'active',
      'is_locked': false,
      'created_at': '2026-08-15T10:00:00Z',
      'updated_at': '2026-08-15T10:03:00Z',
      'last_activity_at': '2026-08-15T10:04:00Z',
    });

    expect(post.isOffer, isFalse);
    expect(post.displayBody, 'The library is closed.');
    expect(post.coverImageUrl, 'https://cdn.test/printing.jpg');
    expect(post.author.username, 'mira');
    expect(post.replyCount, 4);
    expect(post.createdAt, isNotNull);
  });

  test('projects legacy listing into the listing post subtype', () {
    final post = CampusPost.fromListing(
      Listing(
        id: 'listing-1',
        title: 'Calculus textbook',
        category: 'books',
        brand: 'Pearson',
        conditionScore: 8,
        suggestedPriceCny: 20,
        status: 'active',
        ownerId: 'user-2',
        ownerUsername: 'sam',
      ),
    );

    expect(post.isOffer, isTrue);
    expect(post.listingId, 'listing-1');
    expect(post.listing?.suggestedPriceCny, 20);
    expect(post.author.id, 'user-2');
  });

  test('parses threaded reply references', () {
    final reply = PostReply.fromJson({
      'id': 'reply-2',
      'post_id': 'post-1',
      'body': 'The east gate has a printer.',
      'reply_to_id': 'reply-1',
      'author': {'id': 'user-3', 'username': 'lee'},
      'created_at': '2026-08-15T10:10:00Z',
    });

    expect(reply.replyToId, 'reply-1');
    expect(reply.author.username, 'lee');
  });

  test('parses a server listing preview and ranking explanation', () {
    final post = CampusPost.fromJson({
      'id': 'post-listing-1',
      'title': 'Calculus textbook',
      'body_excerpt': 'Used for one semester',
      'listing_id': 'listing-1',
      'rank_reason': 'latest',
      'rank_source': 'recency',
      'ranking_score': 0.92,
      'author': {'id': 'user-1', 'username': 'mira'},
      'reply_count': 0,
      'status': 'active',
      'is_locked': false,
      'listing': {
        'id': 'listing-1',
        'title': 'Calculus textbook',
        'category': 'books',
        'brand': 'Pearson',
        'direction': 'offer',
        'condition_score': 8,
        'suggested_price_cny': 25,
        'status': 'active',
        'image_url': 'https://cdn.test/book.jpg',
      },
    });

    expect(post.listing?.suggestedPriceCny, 25);
    expect(post.coverImageUrl, 'https://cdn.test/book.jpg');
    expect(post.rankReason, 'latest');
    expect(post.rankSource, 'recency');
    expect(post.rankingScore, 0.92);
  });
}
