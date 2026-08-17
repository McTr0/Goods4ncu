abstract final class PublishNavigation {
  static const hub = '/publish';
  static const discussion = '/publish/discussion';
  static const errand = '/publish/errand';
  static const listingPath = '/publish/listing';

  static String listing({required String direction}) {
    final normalizedDirection = direction == 'wanted' ? 'wanted' : 'offer';
    return Uri(
      path: listingPath,
      queryParameters: {'direction': normalizedDirection},
    ).toString();
  }

  /// Maps retired creation URLs to the unified publishing flow.
  static String redirectLegacy(Uri uri) {
    if (uri.path == '/create/post') return discussion;

    final requestedDirection =
        uri.queryParameters['direction'] ?? uri.queryParameters['kind'];
    if (uri.path == '/create/listing') {
      return listing(direction: requestedDirection ?? 'offer');
    }
    if (requestedDirection == 'offer' || requestedDirection == 'wanted') {
      return listing(direction: requestedDirection!);
    }
    return hub;
  }
}
