import 'environment.dart';

/// Session-scoped working memory (master goal §17).
///
/// Tracks what the user is doing *right now* — current topic, filters, the
/// posts they touched, and any draft being confirmed. Lifecycle = one app
/// session; nothing here persists.
class WorkingMemory {
  String? currentTopic;
  final Map<String, String> filters = {};

  /// Newest-first ids of posts the user opened this session.
  final List<String> recentPostIds = [];

  /// Draft currently awaiting confirmation, if any.
  String? pendingDraft;
  String? pendingDraftTarget;

  int get maxRecentPosts => 8;

  /// Feed a meaningful environment event; keeps memory coherent.
  void observe(EnvironmentEvent event) {
    switch (event.type) {
      case EnvironmentEventType.searchPerformed:
        currentTopic = event.payload['query']?.toString();
        break;
      case EnvironmentEventType.postOpened:
        final id =
            (event.payload['postId'] ?? event.payload['listingId'])?.toString();
        if (id != null) touchPost(id);
        break;
      case EnvironmentEventType.draftShown:
        pendingDraft = event.payload['draftText']?.toString();
        pendingDraftTarget = (event.payload['listingId'] ??
                event.payload['postId'])
            ?.toString();
        break;
      case EnvironmentEventType.draftConfirmed:
      case EnvironmentEventType.draftCancelled:
        pendingDraft = null;
        pendingDraftTarget = null;
        break;
      case EnvironmentEventType.postClosed:
      case EnvironmentEventType.messageReceived:
      case EnvironmentEventType.messageSent:
      case EnvironmentEventType.profileOpened:
      case EnvironmentEventType.pageChanged:
      case EnvironmentEventType.postListUpdated:
        break;
    }
  }

  void touchPost(String postId) {
    recentPostIds.remove(postId);
    recentPostIds.insert(0, postId);
    if (recentPostIds.length > maxRecentPosts) {
      recentPostIds.removeLast();
    }
  }

  /// Merged into the chat request's page_context so grounding stays honest.
  Map<String, Object?> toPromptFragment() => {
        if (currentTopic != null && currentTopic!.isNotEmpty)
          'currentTopic': currentTopic,
        if (filters.isNotEmpty) 'filters': filters,
        if (recentPostIds.isNotEmpty) 'recentPostIds': recentPostIds.take(4),
        if (pendingDraft != null) 'hasPendingDraft': true,
      };
}
