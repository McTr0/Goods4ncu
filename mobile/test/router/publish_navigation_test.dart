import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/router/publish_navigation.dart';

void main() {
  group('PublishNavigation.redirectLegacy', () {
    test('redirects /create/post to discussion', () {
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create/post')),
        PublishNavigation.discussion,
      );
    });

    test('redirects /create/listing with default offer', () {
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create/listing')),
        '/publish/listing?direction=offer',
      );
    });

    test('redirects /create/listing with wanted direction', () {
      expect(
        PublishNavigation.redirectLegacy(
          Uri.parse('/create/listing?direction=wanted'),
        ),
        '/publish/listing?direction=wanted',
      );
    });

    test('redirects /my-listings/new with default offer', () {
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/my-listings/new')),
        '/publish/listing?direction=offer',
      );
    });

    test('redirects /my-listings/new with wanted direction', () {
      expect(
        PublishNavigation.redirectLegacy(
          Uri.parse('/my-listings/new?direction=wanted'),
        ),
        '/publish/listing?direction=wanted',
      );
    });
  });
}
