import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/router/app_router.dart';

void main() {
  group('assistantPageContext', () {
    test('is null for general assistant chat', () {
      final context = assistantPageContext(Uri(path: '/agent'));

      expect(context, isNull);
    });

    test('keeps listing and normalized post ids', () {
      final context = assistantPageContext(
        Uri(
          path: '/agent',
          queryParameters: {'listingId': 'listing-7', 'prompt': 'summarize'},
        ),
      );

      expect(context, {
        'page': 'post_detail',
        'listingId': 'listing-7',
        'postId': 'listing-7',
      });
    });

    test('uses discussion post ids without inventing a listing id', () {
      final context = assistantPageContext(
        Uri(path: '/agent', queryParameters: {'postId': 'post-9'}),
      );

      expect(context, {'page': 'post_detail', 'postId': 'post-9'});
    });
  });
}
