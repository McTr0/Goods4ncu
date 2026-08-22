import 'dart:async';

import 'package:flutter/foundation.dart';

/// Meaningful things happening in the platform UI around the companion
/// (goal §51). Scroll noise and similar high-frequency chatter never becomes
/// an event — it is filtered at the source (§52) or folded into counters.
enum EnvironmentEventType {
  postOpened,
  postClosed,
  searchPerformed,
  postListUpdated,
  profileOpened,
  messageReceived,
  messageSent,
  draftShown,
  draftConfirmed,
  draftCancelled,
  pageChanged,
}

class EnvironmentEvent {
  const EnvironmentEvent(this.type, {this.payload = const {}});

  final EnvironmentEventType type;
  final Map<String, Object?> payload;

  @override
  String toString() => 'EnvEvent(${type.name}, $payload)';
}

/// What the companion knows about the user's surroundings (§50).
class EnvironmentState extends ChangeNotifier {
  String page = 'chat';
  String? selectedPostId;
  String? selectedListingId;
  String? selectedUserId;
  String searchQuery;

  /// Bounded ring of recent *meaningful* events (newest first).
  final List<EnvironmentEvent> recentEvents = [];
  final int maxEvents;

  // Folded counters for noisy interactions (never forwarded to the LLM).
  int scrollTicks = 0;

  EnvironmentState({this.maxEvents = 30}) : searchQuery = '';

  bool get hasFocusedPost =>
      selectedPostId != null || selectedListingId != null;

  /// Record an event; returns true when it was meaningful enough to forward
  /// to the companion runtime (character director / proactive engine).
  bool record(EnvironmentEvent event) {
    recentEvents.insert(0, event);
    if (recentEvents.length > maxEvents) recentEvents.removeLast();

    switch (event.type) {
      case EnvironmentEventType.postOpened:
        selectedPostId = event.payload['postId']?.toString();
        selectedListingId = event.payload['listingId']?.toString();
        return true;
      case EnvironmentEventType.postClosed:
        selectedPostId = null;
        selectedListingId = null;
        return false; // closing something is rarely worth reacting to
      case EnvironmentEventType.searchPerformed:
        searchQuery = event.payload['query']?.toString() ?? '';
        return true;
      case EnvironmentEventType.profileOpened:
        selectedUserId = event.payload['userId']?.toString();
        return true;
      case EnvironmentEventType.pageChanged:
        page = event.payload['page']?.toString() ?? page;
        return true;
      case EnvironmentEventType.messageReceived:
      case EnvironmentEventType.draftConfirmed:
        return true;
      case EnvironmentEventType.messageSent:
      case EnvironmentEventType.draftShown:
      case EnvironmentEventType.draftCancelled:
      case EnvironmentEventType.postListUpdated:
        return false;
    }
  }

  /// High-frequency local signal: counted, never emitted.
  void registerScrollTick() => scrollTicks++;

  Map<String, Object?> toPromptFragment() => {
    'page': page,
    if (selectedPostId != null) 'postId': selectedPostId,
    if (selectedListingId != null) 'listingId': selectedListingId,
    if (selectedUserId != null) 'selectedUserId': selectedUserId,
    if (searchQuery.isNotEmpty) 'searchQuery': searchQuery,
  };

  List<EnvironmentEvent> takeRecentForLLM(int limit) =>
      List.unmodifiable(recentEvents.take(limit));
}

/// Bridges UI callbacks into [EnvironmentState] and forwards only meaningful
/// changes to a listener (typically the companion runtime host).
class EnvironmentTracker {
  EnvironmentTracker({
    required this.state,
    void Function(EnvironmentEvent event)? onMeaningfulEvent,
  }) : _onMeaningfulEvent = onMeaningfulEvent;

  final EnvironmentState state;
  final void Function(EnvironmentEvent event)? _onMeaningfulEvent;
  final StreamController<EnvironmentEvent> _echo = StreamController.broadcast();

  Stream<EnvironmentEvent> get events => _echo.stream;

  void track(EnvironmentEvent event) {
    if (state.record(event)) {
      _onMeaningfulEvent?.call(event);
      notifyStateListeners();
    }
    if (!_echo.isClosed) _echo.add(event);
  }

  /// Convenience wrappers used by pages.
  void trackScroll() => state.registerScrollTick();

  void trackPostOpened({String? postId, String? listingId}) => track(
    EnvironmentEvent(
      EnvironmentEventType.postOpened,
      payload: {'postId': postId, 'listingId': listingId},
    ),
  );

  void trackSearch(String query) => track(
    EnvironmentEvent(
      EnvironmentEventType.searchPerformed,
      payload: {'query': query},
    ),
  );

  void trackPageChanged(String page) => track(
    EnvironmentEvent(EnvironmentEventType.pageChanged, payload: {'page': page}),
  );

  /// Public refresh hook (ChangeNotifier.notifyListeners is protected).
  void notifyStateListeners() {
    // EnvironmentState is a ChangeNotifier; pages listen for rebuilds.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    state.notifyListeners();
  }

  Future<void> dispose() async {
    await _echo.close();
    state.dispose();
  }
}
