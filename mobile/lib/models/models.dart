import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class Listing {
  static const String actionDelete = 'delete';
  static const String actionRelist = 'relist';
  static const String actionFulfill = 'fulfill';
  static const String actionContact = 'contact';
  static const String actionBuy = 'buy';
  static const String actionPriceDiscovery = 'start_price_discovery';
  static const String actionRecommendOffer = 'recommend_offer';
  static const String adminActionTakedown = 'takedown';
  static const String adminActionRestore = 'restore';

  final String id;

  /// Database-owned optimistic-concurrency version. Older servers may omit
  /// it during rollout, in which case writes keep their legacy behavior.
  final int? contentRevision;
  final String title;
  final String category;
  final String brand;
  final String direction;
  final int conditionScore;
  final double suggestedPriceCny;
  final String? description;
  final String status;
  final String? thumbnailHint;
  final String? imageUrl;
  final List<String>? defects;
  final String? ownerId;
  final String? ownerUsername;
  final String? createdAt;

  /// Enforcement is deliberately separate from the listing lifecycle. A sold
  /// or owner-deleted listing is not the same thing as content restricted by
  /// an administrator.
  final String? restrictionState;
  final ListingRestriction? restriction;

  /// Viewer-specific, server-authoritative actions. Missing fields mean a
  /// legacy server; present-but-malformed fields fail closed to an empty set.
  final Set<String>? availableActions;
  final Set<String>? availableAdminActions;

  /// Why the feed ranked this item here (server-provided, personalized feeds).
  final String? rankReason;
  final List<String> matchSummary;
  final String? source;
  final String? rankingVersion;

  Listing({
    required this.id,
    this.contentRevision,
    required this.title,
    required this.category,
    required this.brand,
    this.direction = 'offer',
    required this.conditionScore,
    required this.suggestedPriceCny,
    this.description,
    required this.status,
    this.thumbnailHint,
    this.imageUrl,
    this.defects,
    this.ownerId,
    this.ownerUsername,
    this.createdAt,
    this.restrictionState,
    this.restriction,
    this.availableActions,
    this.availableAdminActions,
    this.rankReason,
    this.matchSummary = const [],
    this.source,
    this.rankingVersion,
  });

  factory Listing.fromJson(Map<String, dynamic> json) {
    final hasRestrictionState =
        json.containsKey('restriction_state') || json.containsKey('restricted');
    final rawRestrictionState = json.containsKey('restriction_state')
        ? _nullableJsonString(json['restriction_state'])?.toLowerCase()
        : switch (json['restricted']) {
            true => 'restricted',
            false => 'clear',
            _ => null,
          };
    var normalizedRestrictionState = !hasRestrictionState
        ? null
        : switch (rawRestrictionState) {
            'clear' || 'none' || 'unrestricted' => 'clear',
            'restricted' || 'takedown' || 'taken_down' => 'restricted',
            _ => 'unknown',
          };
    if (json.containsKey('restriction_state') &&
        json.containsKey('restricted')) {
      final restrictedFlag = json['restricted'];
      if (restrictedFlag is! bool ||
          (restrictedFlag && normalizedRestrictionState != 'restricted') ||
          (!restrictedFlag && normalizedRestrictionState != 'clear')) {
        normalizedRestrictionState = 'unknown';
      }
    }
    final restriction = json.containsKey('restriction')
        ? ListingRestriction.fromJson(json['restriction'])
        : normalizedRestrictionState == 'restricted'
        ? ListingRestriction(
            reason: _nullableJsonString(json['restriction_reason']),
            moderationCaseId: _firstNullableJsonString([
              json['restriction_case_id'],
              json['moderation_case_id'],
            ]),
            canAppeal: json['can_appeal'] == true,
          )
        : null;
    return Listing(
      id: json['id'] ?? '',
      contentRevision: (json['content_revision'] as num?)?.toInt(),
      title: json['title'] ?? '',
      category: json['category'] ?? '',
      brand: json['brand'] ?? '',
      direction: json['direction'] ?? 'offer',
      conditionScore: json['condition_score'] ?? 0,
      suggestedPriceCny: (json['suggested_price_cny'] ?? 0).toDouble(),
      description: json['description'],
      status: json['status'] ?? 'active',
      thumbnailHint: json['thumbnail_hint'],
      imageUrl: json['image_url'],
      defects: json['defect_hint'] != null
          ? [json['defect_hint'] as String]
          : (json['defects'] != null
                ? List<String>.from(json['defects'])
                : null),
      ownerId: json['owner_id'],
      ownerUsername: json['owner_username'],
      createdAt: json['created_at'],
      restrictionState: normalizedRestrictionState,
      restriction: restriction,
      availableActions: json.containsKey('available_actions')
          ? _jsonStringSet(json['available_actions']) ?? const <String>{}
          : null,
      availableAdminActions: json.containsKey('available_admin_actions')
          ? _jsonStringSet(json['available_admin_actions']) ?? const <String>{}
          : null,
      rankReason: json['rank_reason']?.toString(),
      matchSummary: (json['match_summary'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      source: json['source']?.toString(),
      rankingVersion: json['ranking_version']?.toString(),
    );
  }

  String get conditionLabel => AppTheme.conditionLabel(conditionScore);

  Color get conditionColor => AppTheme.conditionColor(conditionScore);

  bool get isWanted => direction == 'wanted';

  bool get isOffer => !isWanted;

  /// Unknown or contradictory enforcement metadata is treated as restricted.
  bool get isRestricted {
    if (restriction != null) return true;
    final state = restrictionState;
    return state != null && state != 'clear';
  }

  bool allowsAction(String action) {
    final normalized = action.trim().toLowerCase();
    final actions = availableActions;
    if (restrictionState == 'unknown') return false;
    if (isRestricted) {
      // Enforcement blocks marketplace interaction, but an owner may still
      // delete their own content when the server explicitly authorizes it.
      if (actions == null) return false;
      return normalized == actionDelete && actions.contains(actionDelete);
    }
    if (actions != null) {
      if (normalized == actionBuy) {
        return actions.contains(actionBuy) || actions.contains('create_order');
      }
      return actions.contains(normalized);
    }

    // Rolling-upgrade compatibility for responses from servers that predate
    // action metadata. Restrictive metadata never takes this path.
    return switch (normalized) {
      actionDelete => status == 'active',
      actionRelist =>
        status == 'sold' ||
            status == 'deleted' ||
            (isWanted && status == 'fulfilled'),
      actionFulfill => isWanted && status == 'active',
      actionContact => status == 'active',
      actionBuy || actionPriceDiscovery => isOffer && status == 'active',
      actionRecommendOffer => isWanted && status == 'active',
      _ => false,
    };
  }

  bool allowsAdminAction(String action) {
    final actions = availableAdminActions;
    if (actions == null) return false;
    return actions.contains(action.trim().toLowerCase());
  }

  String get directionLabelZh => isWanted ? '收' : '出';

  String get priceSemanticLabelZh => isWanted ? '预算上限' : '价格';

  String get conditionSemanticLabelZh => isWanted ? '最低成色' : '成色';
}

class ListingRestriction {
  final String? reason;
  final String? moderationCaseId;
  final String? restrictedAt;
  final bool canAppeal;

  const ListingRestriction({
    this.reason,
    this.moderationCaseId,
    this.restrictedAt,
    this.canAppeal = false,
  });

  static ListingRestriction? fromJson(dynamic value) {
    if (value == null) return null;
    if (value is! Map) {
      // Presence of malformed restriction metadata must still fail closed.
      return const ListingRestriction();
    }
    final json = _jsonObject(value);
    return ListingRestriction(
      reason: _firstNullableJsonString([json['public_reason'], json['reason']]),
      moderationCaseId: _firstNullableJsonString([
        json['moderation_case_id'],
        json['case_id'],
      ]),
      restrictedAt: _nullableJsonString(json['restricted_at']),
      canAppeal: json['can_appeal'] == true,
    );
  }
}

class ListingsResponse {
  final List<Listing> items;
  final int total;
  final int limit;
  final int offset;
  final String? rankingVersion;

  ListingsResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    this.rankingVersion,
  });

  factory ListingsResponse.fromJson(Map<String, dynamic> json) {
    final rankingVersion = json['ranking_version']?.toString();
    return ListingsResponse(
      items: (json['items'] as List<dynamic>).map((e) {
        final item = Map<String, dynamic>.from(e as Map<String, dynamic>);
        if (rankingVersion != null && !item.containsKey('ranking_version')) {
          item['ranking_version'] = rankingVersion;
        }
        return Listing.fromJson(item);
      }).toList(),
      total: json['total'] ?? 0,
      limit: json['limit'] ?? 20,
      offset: json['offset'] ?? 0,
      rankingVersion: rankingVersion,
    );
  }
}

enum WantedResponseRole { requester, responder }

extension WantedResponseRoleWireValue on WantedResponseRole {
  String get wireValue => switch (this) {
    WantedResponseRole.requester => 'requester',
    WantedResponseRole.responder => 'responder',
  };
}

/// One explicit recommendation of an offer for a wanted listing.
///
/// This is deliberately separate from an algorithmic wanted match: it records
/// that another person chose to recommend their own offer, along with the
/// requester's eventual decision.
class WantedResponse {
  final String id;
  final String wantedListingId;
  final String wantedTitle;
  final String wantedStatus;
  final String offerListingId;
  final String offerTitle;
  final String offerStatus;
  final String responderId;
  final String requesterId;
  final String? message;
  final String status;
  final DateTime? createdAt;
  final DateTime? respondedAt;
  final int? lifecycleEpoch;
  final int? currentLifecycleEpoch;
  final String? roundState;

  /// Server-authoritative actions for this response.
  ///
  /// `null` means the server predates lifecycle action metadata, so callers
  /// should preserve the legacy status-based behavior. An empty set is an
  /// explicit instruction that the response is read-only.
  final Set<String>? availableActions;

  const WantedResponse({
    required this.id,
    required this.wantedListingId,
    required this.wantedTitle,
    required this.wantedStatus,
    required this.offerListingId,
    required this.offerTitle,
    required this.offerStatus,
    required this.responderId,
    required this.requesterId,
    this.message,
    required this.status,
    this.createdAt,
    this.respondedAt,
    this.lifecycleEpoch,
    this.currentLifecycleEpoch,
    this.roundState,
    this.availableActions,
  });

  factory WantedResponse.fromJson(Map<String, dynamic> json) {
    final wanted = _jsonObject(json['wanted_listing']);
    final offer = _jsonObject(json['offer_listing']);
    return WantedResponse(
      id: _jsonString(json['id']),
      wantedListingId: _firstJsonString([
        json['wanted_listing_id'],
        wanted['id'],
      ]),
      wantedTitle: _firstJsonString([json['wanted_title'], wanted['title']]),
      wantedStatus: _firstJsonString([
        json['wanted_status'],
        json['wanted_listing_status'],
        wanted['status'],
      ], fallback: 'unknown'),
      offerListingId: _firstJsonString([json['offer_listing_id'], offer['id']]),
      offerTitle: _firstJsonString([json['offer_title'], offer['title']]),
      offerStatus: _firstJsonString([
        json['offer_status'],
        json['offer_listing_status'],
        offer['status'],
      ], fallback: 'unknown'),
      responderId: _jsonString(json['responder_id']),
      requesterId: _jsonString(json['requester_id']),
      message: _nullableJsonString(json['message']),
      status: _jsonString(json['status'], fallback: 'pending'),
      createdAt: _jsonDateTime(json['created_at']),
      respondedAt: _jsonDateTime(json['responded_at']),
      lifecycleEpoch: _nullableJsonInt(json['lifecycle_epoch']),
      currentLifecycleEpoch: _nullableJsonInt(json['current_lifecycle_epoch']),
      roundState: _nullableJsonString(json['round_state'])?.toLowerCase(),
      availableActions: json.containsKey('available_actions')
          ? _jsonStringSet(json['available_actions']) ?? const <String>{}
          : null,
    );
  }

  bool get isPending => status == 'pending';

  bool get isAccepted => status == 'accepted';

  bool get isDismissed => status == 'dismissed';

  bool get isWithdrawn => status == 'withdrawn';

  /// Whether this response belongs to a completed lifecycle of the wanted
  /// listing. An epoch mismatch or known inactive parent always fails closed;
  /// otherwise explicit server state wins, supporting partial-rollout servers.
  bool get isClosedRound {
    final responseEpoch = lifecycleEpoch;
    final currentEpoch = currentLifecycleEpoch;
    if (responseEpoch != null &&
        currentEpoch != null &&
        responseEpoch != currentEpoch) {
      // Contradictory metadata must fail closed: a stale epoch can never
      // become actionable merely because a replica mislabeled its state.
      return true;
    }
    if (wantedStatus != 'active' && wantedStatus != 'unknown') {
      return true;
    }
    switch (roundState?.trim().toLowerCase()) {
      case 'closed':
      case 'previous':
      case 'stale':
        return true;
      case 'current':
      case 'open':
        return false;
    }
    return false;
  }

  bool allowsAction(String action) {
    if (!isPending || isClosedRound) return false;
    final normalized = action.trim().toLowerCase();
    final actions = availableActions;
    if (actions != null) return actions.contains(normalized);

    // Compatibility with older servers: page ownership and listing state still
    // gate the callbacks, while a pending response retains its previous UI.
    return true;
  }

  bool get canAccept => allowsAction('accept');

  bool get canDismiss => allowsAction('dismiss');

  bool get canWithdraw => allowsAction('withdraw');

  WantedResponse copyWith({
    String? status,
    DateTime? respondedAt,
    int? lifecycleEpoch,
    int? currentLifecycleEpoch,
    String? roundState,
    Set<String>? availableActions,
  }) {
    return WantedResponse(
      id: id,
      wantedListingId: wantedListingId,
      wantedTitle: wantedTitle,
      wantedStatus: wantedStatus,
      offerListingId: offerListingId,
      offerTitle: offerTitle,
      offerStatus: offerStatus,
      responderId: responderId,
      requesterId: requesterId,
      message: message,
      status: status ?? this.status,
      createdAt: createdAt,
      respondedAt: respondedAt ?? this.respondedAt,
      lifecycleEpoch: lifecycleEpoch ?? this.lifecycleEpoch,
      currentLifecycleEpoch:
          currentLifecycleEpoch ?? this.currentLifecycleEpoch,
      roundState: roundState ?? this.roundState,
      availableActions: availableActions ?? this.availableActions,
    );
  }
}

class WantedResponsesResponse {
  final List<WantedResponse> items;
  final int total;
  final int limit;
  final int offset;

  const WantedResponsesResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory WantedResponsesResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (item) => WantedResponse.fromJson(
                  item.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .toList(growable: false)
        : const <WantedResponse>[];
    return WantedResponsesResponse(
      items: items,
      total: _jsonInt(json['total'], fallback: items.length),
      limit: _jsonInt(json['limit'], fallback: 20),
      offset: _jsonInt(json['offset']),
    );
  }
}

class WantedResponseActionResult {
  final String id;
  final String status;

  const WantedResponseActionResult({required this.id, required this.status});

  factory WantedResponseActionResult.fromJson(Map<String, dynamic> json) {
    return WantedResponseActionResult(
      id: _jsonString(json['id']),
      status: _jsonString(json['status']),
    );
  }
}

Map<String, dynamic> _jsonObject(dynamic value) {
  if (value is! Map) return const <String, dynamic>{};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _jsonString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  final normalized = value.toString().trim();
  return normalized.isEmpty ? fallback : normalized;
}

String _firstJsonString(Iterable<dynamic> values, {String fallback = ''}) {
  for (final value in values) {
    final normalized = _jsonString(value);
    if (normalized.isNotEmpty) return normalized;
  }
  return fallback;
}

String? _nullableJsonString(dynamic value) {
  final normalized = _jsonString(value);
  return normalized.isEmpty ? null : normalized;
}

String? _firstNullableJsonString(Iterable<dynamic> values) {
  for (final value in values) {
    final normalized = _nullableJsonString(value);
    if (normalized != null) return normalized;
  }
  return null;
}

int _jsonInt(dynamic value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int? _nullableJsonInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

Set<String>? _jsonStringSet(dynamic value) {
  if (value is! List) return null;
  return Set<String>.unmodifiable(
    value
        .map((item) => _jsonString(item).toLowerCase())
        .where((item) => item.isNotEmpty),
  );
}

DateTime? _jsonDateTime(dynamic value) {
  final normalized = _jsonString(value);
  return normalized.isEmpty ? null : DateTime.tryParse(normalized);
}

class WatchlistItem {
  final String listingId;
  final String title;
  final String category;
  final String brand;
  final int conditionScore;
  final double suggestedPriceCny;
  final String status;
  final String ownerId;
  final String createdAt;

  const WatchlistItem({
    required this.listingId,
    required this.title,
    required this.category,
    required this.brand,
    required this.conditionScore,
    required this.suggestedPriceCny,
    required this.status,
    required this.ownerId,
    required this.createdAt,
  });

  factory WatchlistItem.fromJson(Map<String, dynamic> json) {
    return WatchlistItem(
      listingId: json['listing_id']?.toString() ?? '',
      title: json['title'] ?? '',
      category: json['category'] ?? '',
      brand: json['brand'] ?? '',
      conditionScore: json['condition_score'] ?? 0,
      suggestedPriceCny: (json['suggested_price_cny'] ?? 0).toDouble(),
      status: json['status'] ?? 'active',
      ownerId: json['owner_id']?.toString() ?? '',
      createdAt: json['created_at'] ?? '',
    );
  }
}

class WatchlistResponse {
  final List<WatchlistItem> items;
  final int total;
  final int limit;
  final int offset;

  const WatchlistResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory WatchlistResponse.fromJson(Map<String, dynamic> json) {
    return WatchlistResponse(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => WatchlistItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] ?? 0,
      limit: json['limit'] ?? 20,
      offset: json['offset'] ?? 0,
    );
  }
}

class AppNotification {
  final String id;
  final String eventType;
  final String title;
  final String body;
  final String? relatedOrderId;
  final String? relatedListingId;

  /// Someone answered you. Carried so tapping the notification opens the
  /// conversation rather than doing nothing — the notice that says a person
  /// engaged with you is the last one that should be a dead end.
  final String? relatedConversationId;

  /// A space formed around something you asked for.
  final String? relatedSpaceId;
  final bool isRead;
  final String createdAt;

  const AppNotification({
    required this.id,
    required this.eventType,
    required this.title,
    required this.body,
    this.relatedOrderId,
    this.relatedListingId,
    this.relatedConversationId,
    this.relatedSpaceId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id']?.toString() ?? '',
      eventType: json['event_type'] ?? '',
      title: json['title'] ?? '',
      body: json['body'] ?? '',
      relatedOrderId: json['related_order_id']?.toString(),
      relatedListingId: json['related_listing_id']?.toString(),
      relatedConversationId: json['related_conversation_id']?.toString(),
      relatedSpaceId: json['related_space_id']?.toString(),
      isRead: json['is_read'] ?? false,
      createdAt: json['created_at'] ?? '',
    );
  }

  AppNotification copyWith({
    String? id,
    String? eventType,
    String? title,
    String? body,
    String? relatedOrderId,
    String? relatedListingId,
    String? relatedConversationId,
    String? relatedSpaceId,
    bool? isRead,
    String? createdAt,
  }) {
    return AppNotification(
      id: id ?? this.id,
      eventType: eventType ?? this.eventType,
      title: title ?? this.title,
      body: body ?? this.body,
      relatedOrderId: relatedOrderId ?? this.relatedOrderId,
      relatedListingId: relatedListingId ?? this.relatedListingId,
      relatedConversationId:
          relatedConversationId ?? this.relatedConversationId,
      relatedSpaceId: relatedSpaceId ?? this.relatedSpaceId,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class NotificationsResponse {
  final List<AppNotification> items;
  final int total;
  final int unreadCount;
  final int limit;
  final int offset;

  const NotificationsResponse({
    required this.items,
    required this.total,
    required this.unreadCount,
    required this.limit,
    required this.offset,
  });

  factory NotificationsResponse.fromJson(Map<String, dynamic> json) {
    return NotificationsResponse(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] ?? 0,
      unreadCount: json['unread_count'] ?? 0,
      limit: json['limit'] ?? 20,
      offset: json['offset'] ?? 0,
    );
  }
}

class ChatMessage {
  final String sender;
  final String content;
  final String? imageBase64;
  final String? audioBase64;
  final String? imageUrl;
  final String? audioUrl;
  final DateTime timestamp;

  /// True while the SSE stream is still delivering tokens (typing indicator).
  final bool isPartial;

  ChatMessage({
    required this.sender,
    required this.content,
    this.imageBase64,
    this.audioBase64,
    this.imageUrl,
    this.audioUrl,
    required this.timestamp,
    this.isPartial = false,
  });

  ChatMessage copyWith({
    String? sender,
    String? content,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
    DateTime? timestamp,
    bool? isPartial,
  }) {
    return ChatMessage(
      sender: sender ?? this.sender,
      content: content ?? this.content,
      imageBase64: imageBase64 ?? this.imageBase64,
      audioBase64: audioBase64 ?? this.audioBase64,
      imageUrl: imageUrl ?? this.imageUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      timestamp: timestamp ?? this.timestamp,
      isPartial: isPartial ?? this.isPartial,
    );
  }

  Map<String, dynamic> toJson() => {
    'message': content,
    'image': imageBase64,
    'audio': audioBase64,
    'image_url': imageUrl,
    'audio_url': audioUrl,
  };

  factory ChatMessage.fromAssistantJson(Map<String, dynamic> json) {
    return ChatMessage(
      sender: json['role'] == 'assistant' ? 'bot' : 'user',
      content: json['content']?.toString() ?? '',
      imageUrl: json['image_url']?.toString(),
      audioUrl: json['audio_url']?.toString(),
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class AssistantConversationHistory {
  const AssistantConversationHistory({
    required this.messages,
    required this.total,
  });

  final List<ChatMessage> messages;
  final int total;

  ChatMessage? get latest => messages.isEmpty ? null : messages.last;

  factory AssistantConversationHistory.fromJson(Map<String, dynamic> json) {
    return AssistantConversationHistory(
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                ChatMessage.fromAssistantJson(item as Map<String, dynamic>),
          )
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
    );
  }
}

enum ConversationMode {
  realtime,
  mail;

  String get wireValue => name;

  static ConversationMode parse(Object? value) =>
      value == 'mail' ? ConversationMode.mail : ConversationMode.realtime;
}

/// A sender-declared handling horizon for an asynchronous mail. It is not a
/// delivery receipt, notification priority, online state, or read signal.
enum MailExpectation {
  ordinary,
  today;

  String get wireValue => name;

  static MailExpectation parse(Object? value) =>
      value == 'today' ? MailExpectation.today : MailExpectation.ordinary;
}

enum ConversationState {
  synSent('syn_sent'),
  synAck('syn_ack'),
  active('active'),
  declined('declined'),
  cancelled('cancelled'),
  expired('expired'),
  closed('closed'),
  open('open');

  const ConversationState(this.wireValue);
  final String wireValue;

  bool get isLiveRealtime =>
      this == synSent || this == synAck || this == active;

  bool get isTerminal =>
      this == declined ||
      this == cancelled ||
      this == expired ||
      this == closed;

  static ConversationState parse(Object? value) {
    final wire = value?.toString();
    return ConversationState.values.firstWhere(
      (state) => state.wireValue == wire,
      orElse: () {
        switch (wire) {
          case 'connected':
          case 'established':
            return ConversationState.active;
          case 'pending':
            return ConversationState.synSent;
          case 'rejected':
            return ConversationState.declined;
          default:
            return ConversationState.synSent;
        }
      },
    );
  }
}

class ConversationCapabilities {
  const ConversationCapabilities({
    this.canRespond = false,
    this.canAck = false,
    this.canSend = false,
    this.canClose = false,
    this.canArchive = true,
    this.canRestart = false,
  });

  final bool canRespond;
  final bool canAck;
  final bool canSend;
  final bool canClose;
  final bool canArchive;
  final bool canRestart;

  factory ConversationCapabilities.fromJson(Map<String, dynamic>? json) {
    return ConversationCapabilities(
      canRespond: json?['can_respond'] == true,
      canAck: json?['can_ack'] == true,
      canSend: json?['can_send'] == true,
      canClose: json?['can_close'] == true,
      canArchive: json?['can_archive'] != false,
      canRestart: json?['can_restart'] == true,
    );
  }
}

/// A conversation's transport state. `connected` describes this conversation
/// only; it is never a claim about a person's global online presence.
enum ConnectionStatusType { connected, offline, pending }

/// Per-user policy for realtime connection requests.  `busyUntil` is a
/// temporary interruption preference, not an online/last-seen signal.
class ConnectionPreferences {
  const ConnectionPreferences({required this.allowStrangers, this.busyUntil});

  final bool allowStrangers;
  final DateTime? busyUntil;

  factory ConnectionPreferences.fromJson(Map<String, dynamic> json) {
    return ConnectionPreferences(
      allowStrangers: json['allow_strangers'] == true,
      busyUntil: _jsonDateTime(json['busy_until']),
    );
  }
}

/// A deliberate relationship-specific permission.  A muted contact may still
/// have a persisted conversation; only the interrupting notification is
/// suppressed while the mute is active.
class ContactPermission {
  const ContactPermission({
    required this.peerUserId,
    required this.allowConnection,
    this.mutedUntil,
  });

  final String peerUserId;
  final bool allowConnection;
  final DateTime? mutedUntil;

  factory ContactPermission.fromJson(Map<String, dynamic> json) {
    return ContactPermission(
      peerUserId: json['peer_user_id']?.toString() ?? '',
      allowConnection: json['allow_connection'] != false,
      mutedUntil: _jsonDateTime(json['muted_until']),
    );
  }
}

class Conversation {
  Conversation({
    required this.id,
    String? initiatorId,
    String? requesterId,
    this.recipientId = '',
    required this.otherUserId,
    required this.otherUsername,
    ConversationMode? mode,
    this.mailExpectation = MailExpectation.ordinary,
    ConversationState? state,
    String? status,
    this.listingId,
    this.listingTitle,
    this.subject,
    this.lastMessage,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.archived = false,
    this.expiresAt,
    this.establishedAt,
    this.closedAt,
    this.closeReason,
    this.createdAt,
    this.updatedAt,
    this.version = 1,
    bool? isInitiator,
    bool? isReceiver,
    this.isBlocked = false,
    ConversationCapabilities? capabilities,
  }) : initiatorId = initiatorId ?? requesterId ?? '',
       mode = mode ?? ConversationMode.realtime,
       state = state ?? ConversationState.parse(status),
       isInitiator = isInitiator ?? !(isReceiver ?? false),
       capabilities =
           capabilities ??
           ConversationCapabilities(
             canRespond:
                 (state ?? ConversationState.parse(status)) ==
                     ConversationState.synSent &&
                 (isReceiver ?? false),
             canSend:
                 (state ?? ConversationState.parse(status)) ==
                 ConversationState.active,
             canClose:
                 (state ?? ConversationState.parse(status)).isLiveRealtime,
             canRestart: false,
           );

  final String id;
  final ConversationMode mode;
  final MailExpectation mailExpectation;
  final ConversationState state;
  final String initiatorId;
  final String recipientId;
  final String otherUserId;
  final String otherUsername;
  final String? listingId;
  final String? listingTitle;
  final String? subject;
  final String? lastMessage;
  final DateTime? lastMessageAt;

  /// Device-local new-message marker (0 or 1), never supplied by the server.
  final int unreadCount;
  final bool archived;
  final DateTime? expiresAt;
  final DateTime? establishedAt;
  final DateTime? closedAt;
  final String? closeReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int version;
  final bool isInitiator;
  final bool isBlocked;
  final ConversationCapabilities capabilities;

  String get requesterId => initiatorId;
  String get status => state.wireValue;
  bool get isReceiver => !isInitiator;
  bool get canRespond => capabilities.canRespond;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) =>
        json[key] == null ? null : DateTime.tryParse(json[key].toString());
    return Conversation(
      id: json['id']?.toString() ?? '',
      mode: ConversationMode.parse(json['mode']),
      mailExpectation: MailExpectation.parse(json['mail_expectation']),
      state: ConversationState.parse(json['state'] ?? json['status']),
      initiatorId:
          json['initiator_id']?.toString() ??
          json['requester_id']?.toString() ??
          '',
      recipientId: json['recipient_id']?.toString() ?? '',
      otherUserId: json['other_user_id']?.toString() ?? '',
      otherUsername: json['other_username']?.toString() ?? '',
      listingId: json['listing_id']?.toString(),
      listingTitle: json['listing_title']?.toString(),
      subject: json['subject']?.toString(),
      lastMessage: json['last_message']?.toString(),
      lastMessageAt: date('last_message_at'),
      unreadCount: 0,
      archived: json['archived'] == true,
      expiresAt: date('expires_at'),
      establishedAt: date('established_at'),
      closedAt: date('closed_at'),
      closeReason: json['close_reason']?.toString(),
      createdAt: date('created_at'),
      updatedAt: date('updated_at'),
      version: (json['version'] as num?)?.toInt() ?? 1,
      isInitiator: json.containsKey('is_initiator')
          ? json['is_initiator'] == true
          : json['is_receiver'] != true,
      isReceiver: json['is_receiver'] == true,
      isBlocked: json['is_blocked'] == true,
      capabilities: json['capabilities'] is Map<String, dynamic>
          ? ConversationCapabilities.fromJson(
              json['capabilities'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  ConnectionStatusType get connectionStatus {
    if (state == ConversationState.synSent ||
        state == ConversationState.synAck) {
      return ConnectionStatusType.pending;
    }
    return state == ConversationState.active
        ? ConnectionStatusType.connected
        : ConnectionStatusType.offline;
  }
}

class ChatThread {
  const ChatThread({
    required this.peerUserId,
    required this.peerUsername,
    required this.latestActivityAt,
    this.peerAvatarUrl,
    this.relationshipKey,
    this.latestPreview,
    this.unreadCount = 0,
    this.conversationCount = 0,
    this.mailCount = 0,
    this.realtimeCount = 0,
    this.pendingCount = 0,
    this.hasActiveRealtime = false,
    this.latestListingTitle,
    this.peerPersona,
  });

  final String peerUserId;
  final String peerUsername;
  final String? peerAvatarUrl;
  final DateTime latestActivityAt;

  /// Server-provided campus-scoped relationship key. Legacy servers may omit
  /// it; absence is kept as null rather than inventing a relationship fact on
  /// the device.
  final String? relationshipKey;
  final String? latestPreview;
  final int unreadCount;
  final int conversationCount;
  final int mailCount;
  final int realtimeCount;
  final int pendingCount;
  final bool hasActiveRealtime;
  final String? latestListingTitle;
  final SocialPersona? peerPersona;

  ChatThread copyWith({int? unreadCount}) => ChatThread(
    peerUserId: peerUserId,
    peerUsername: peerUsername,
    peerAvatarUrl: peerAvatarUrl,
    latestActivityAt: latestActivityAt,
    relationshipKey: relationshipKey,
    latestPreview: latestPreview,
    unreadCount: unreadCount ?? this.unreadCount,
    conversationCount: conversationCount,
    mailCount: mailCount,
    realtimeCount: realtimeCount,
    pendingCount: pendingCount,
    hasActiveRealtime: hasActiveRealtime,
    latestListingTitle: latestListingTitle,
    peerPersona: peerPersona,
  );

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    return ChatThread(
      peerUserId: json['peer_user_id']?.toString() ?? '',
      peerUsername: json['peer_username']?.toString() ?? '',
      peerAvatarUrl: json['peer_avatar_url']?.toString(),
      latestActivityAt:
          DateTime.tryParse(json['latest_activity_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      relationshipKey: json['relationship_key']?.toString(),
      latestPreview: json['latest_preview']?.toString(),
      // The server no longer stores a read position.  Inbox badges are
      // derived from the device-local marker in ConversationListPage.
      unreadCount: 0,
      conversationCount: (json['conversation_count'] as num?)?.toInt() ?? 0,
      mailCount: (json['mail_count'] as num?)?.toInt() ?? 0,
      realtimeCount: (json['realtime_count'] as num?)?.toInt() ?? 0,
      pendingCount: (json['pending_count'] as num?)?.toInt() ?? 0,
      hasActiveRealtime: json['has_active_realtime'] == true,
      latestListingTitle: json['latest_listing_title']?.toString(),
      peerPersona: json['persona'] is Map
          ? SocialPersona.fromJson(
              (json['persona'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }
}

class ChatThreadDetail {
  const ChatThreadDetail({required this.thread, required this.conversations});

  final ChatThread thread;
  final List<Conversation> conversations;

  factory ChatThreadDetail.fromJson(Map<String, dynamic> json) {
    return ChatThreadDetail(
      thread: ChatThread.fromJson(json['thread'] as Map<String, dynamic>),
      conversations: (json['conversations'] as List<dynamic>? ?? const [])
          .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class RelationshipSpaceEvent {
  const RelationshipSpaceEvent({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    required this.eventType,
    required this.conversationId,
    required this.actorId,
    required this.occurredAt,
  });

  final String id;
  final String sourceType;
  final String sourceId;
  final String eventType;
  final String conversationId;
  final String? actorId;
  final DateTime occurredAt;

  factory RelationshipSpaceEvent.fromJson(Map<String, dynamic> json) {
    return RelationshipSpaceEvent(
      id: json['id']?.toString() ?? '',
      sourceType: json['source_type']?.toString() ?? '',
      sourceId: json['source_id']?.toString() ?? '',
      eventType: json['event_type']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      actorId: json['actor_id']?.toString(),
      occurredAt:
          DateTime.tryParse(json['occurred_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class RelationshipSpacePin {
  const RelationshipSpacePin({
    required this.id,
    required this.messageId,
    required this.conversationId,
    required this.actorId,
    required this.createdAt,
  });

  final String id;
  final int messageId;
  final String conversationId;
  final String actorId;
  final DateTime createdAt;

  factory RelationshipSpacePin.fromJson(Map<String, dynamic> json) {
    return RelationshipSpacePin(
      id: json['id']?.toString() ?? '',
      messageId: (json['message_id'] as num?)?.toInt() ?? 0,
      conversationId: json['conversation_id']?.toString() ?? '',
      actorId: json['actor_id']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class RelationshipSpaceSharedObject {
  const RelationshipSpaceSharedObject({
    required this.key,
    required this.kind,
    required this.refId,
    required this.snapshot,
    required this.sourceMessageId,
    required this.conversationId,
    required this.actorId,
    required this.createdAt,
  });

  final String key;
  final String kind;
  final String refId;
  final Map<String, dynamic> snapshot;
  final int sourceMessageId;
  final String conversationId;
  final String actorId;
  final DateTime createdAt;

  factory RelationshipSpaceSharedObject.fromJson(Map<String, dynamic> json) {
    return RelationshipSpaceSharedObject(
      key: json['key']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      refId: json['ref_id']?.toString() ?? '',
      snapshot:
          (json['snapshot'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      sourceMessageId: (json['source_message_id'] as num?)?.toInt() ?? 0,
      conversationId: json['conversation_id']?.toString() ?? '',
      actorId: json['actor_id']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class RelationshipSpaceConnection {
  const RelationshipSpaceConnection({
    required this.conversationId,
    required this.startedAt,
    required this.endedAt,
  });

  final String conversationId;
  final DateTime startedAt;
  final DateTime? endedAt;

  factory RelationshipSpaceConnection.fromJson(Map<String, dynamic> json) {
    return RelationshipSpaceConnection(
      conversationId: json['conversation_id']?.toString() ?? '',
      startedAt:
          DateTime.tryParse(json['started_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      endedAt: DateTime.tryParse(json['ended_at']?.toString() ?? ''),
    );
  }
}

class RelationshipSpace {
  const RelationshipSpace({
    required this.relationshipKey,
    required this.events,
    this.pins = const [],
    this.sharedObjects = const [],
    this.recentConnection,
    this.nextCursor,
  });

  final String relationshipKey;
  final List<RelationshipSpaceEvent> events;
  final List<RelationshipSpacePin> pins;
  final List<RelationshipSpaceSharedObject> sharedObjects;
  final RelationshipSpaceConnection? recentConnection;
  final String? nextCursor;

  factory RelationshipSpace.fromJson(Map<String, dynamic> json) {
    return RelationshipSpace(
      relationshipKey: json['relationship_key']?.toString() ?? '',
      events: (json['events'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RelationshipSpaceEvent.fromJson)
          .toList(),
      pins: (json['pins'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RelationshipSpacePin.fromJson)
          .toList(),
      sharedObjects: (json['shared_objects'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RelationshipSpaceSharedObject.fromJson)
          .toList(),
      recentConnection: json['recent_connection'] is Map
          ? RelationshipSpaceConnection.fromJson(
              (json['recent_connection'] as Map).cast<String, dynamic>(),
            )
          : null,
      nextCursor: json['next_cursor']?.toString(),
    );
  }
}

/// A server-owned file/link reference.  The message quote is only a pointer
/// to this object; a revoked object must not be opened or rendered as active.
class ChatSharedObject {
  const ChatSharedObject({
    required this.id,
    required this.campusId,
    required this.conversationId,
    required this.createdBy,
    required this.kind,
    required this.title,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.moderationStatus,
    required this.storageVerifiedAt,
    required this.uploadedSizeBytes,
    required this.uploadedMimeType,
    required this.uploadKey,
    required this.canonicalUrl,
    required this.createdAt,
    required this.updatedAt,
    this.downloadPath,
  });

  final String id;
  final String campusId;
  final String conversationId;
  final String createdBy;
  final String kind;
  final String title;
  final String? mimeType;
  final int? sizeBytes;
  final String status;
  final String moderationStatus;
  final DateTime? storageVerifiedAt;
  final int? uploadedSizeBytes;
  final String? uploadedMimeType;
  final String? uploadKey;
  final String? canonicalUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? downloadPath;

  bool get isActive => status == 'active';

  factory ChatSharedObject.fromJson(Map<String, dynamic> json) {
    return ChatSharedObject(
      id: json['id']?.toString() ?? '',
      campusId: json['campus_id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      createdBy: json['created_by']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      mimeType: json['mime_type']?.toString(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      status: json['status']?.toString() ?? 'active',
      moderationStatus: json['moderation_status']?.toString() ?? 'not_required',
      storageVerifiedAt: DateTime.tryParse(
        json['storage_verified_at']?.toString() ?? '',
      ),
      uploadedSizeBytes: (json['uploaded_size_bytes'] as num?)?.toInt(),
      uploadedMimeType: json['uploaded_mime_type']?.toString(),
      uploadKey: json['upload_key']?.toString(),
      canonicalUrl: json['canonical_url']?.toString(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      downloadPath: json['download_path']?.toString(),
    );
  }
}

class ChatSharedObjectMedia {
  const ChatSharedObjectMedia({
    required this.objectId,
    required this.url,
    this.expiresInSeconds,
  });

  final String objectId;
  final String url;
  final int? expiresInSeconds;

  factory ChatSharedObjectMedia.fromJson(Map<String, dynamic> json) {
    return ChatSharedObjectMedia(
      objectId: json['object_id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      expiresInSeconds: (json['expires_in_seconds'] as num?)?.toInt(),
    );
  }
}

/// User-controlled role presentation. This is intentionally a presentation
/// layer: it contains only selected tokens and explicit labels, never inferred
/// presence, typing, read, or personality state.
class SocialPersonaAppearance {
  const SocialPersonaAppearance({
    required this.palette,
    required this.silhouette,
    required this.accessory,
    required this.outfit,
  });

  final String palette;
  final String silhouette;
  final String accessory;
  final String outfit;

  factory SocialPersonaAppearance.fromJson(Map<String, dynamic>? json) {
    return SocialPersonaAppearance(
      palette: json?['palette']?.toString() ?? 'teal',
      silhouette: json?['silhouette']?.toString() ?? 'soft',
      accessory: json?['accessory']?.toString() ?? 'none',
      outfit: json?['outfit']?.toString() ?? 'campus',
    );
  }

  Map<String, String> toJson() => {
    'palette': palette,
    'silhouette': silhouette,
    'accessory': accessory,
    'outfit': outfit,
  };
}

/// Server-owned role/skin choices. The editor may only submit values present
/// here; there is intentionally no image, URL, or free-form import field.
class SocialPersonaCatalog {
  const SocialPersonaCatalog({
    required this.styleVersion,
    required this.representationModes,
    required this.appearance,
    required this.selfDescriptions,
    required this.contactPostures,
  });

  final String styleVersion;
  final List<String> representationModes;
  final Map<String, List<String>> appearance;
  final List<String> selfDescriptions;
  final List<String> contactPostures;

  factory SocialPersonaCatalog.fromJson(Map<String, dynamic> json) {
    final rawAppearance = json['appearance'];
    final appearance = <String, List<String>>{};
    if (rawAppearance is Map) {
      for (final entry in rawAppearance.entries) {
        final values = entry.value;
        if (values is List) {
          appearance[entry.key.toString()] = values
              .map((value) => value.toString())
              .toList(growable: false);
        }
      }
    }
    List<String> list(String key) => (json[key] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false);
    return SocialPersonaCatalog(
      styleVersion: json['style_version']?.toString() ?? 'v1',
      representationModes: list('representation_modes'),
      appearance: appearance,
      selfDescriptions: list('self_descriptions'),
      contactPostures: list('contact_postures'),
    );
  }
}

class SocialPersonaAsset {
  const SocialPersonaAsset({
    required this.id,
    this.personaId,
    required this.assetType,
    this.declaredMimeType,
    this.declaredSizeBytes,
    this.uploadedSizeBytes,
    this.uploadedMimeType,
    this.storageVerifiedAt,
    required this.moderationStatus,
    required this.status,
    this.rejectReason,
    this.uploadKey,
    this.url,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? personaId;
  final String assetType;
  final String? declaredMimeType;
  final int? declaredSizeBytes;
  final int? uploadedSizeBytes;
  final String? uploadedMimeType;
  final DateTime? storageVerifiedAt;
  final String moderationStatus;
  final String status;
  final String? rejectReason;
  final String? uploadKey;
  final String? url;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isReady =>
      status == 'active' &&
      (moderationStatus == 'approved' || moderationStatus == 'not_required') &&
      (storageVerifiedAt != null || (url?.trim().isNotEmpty ?? false));

  factory SocialPersonaAsset.fromJson(Map<String, dynamic> json) {
    return SocialPersonaAsset(
      id: json['id']?.toString() ?? '',
      personaId: json['persona_id']?.toString(),
      assetType: json['asset_type']?.toString() ?? 'illustration',
      declaredMimeType: json['declared_mime_type']?.toString(),
      declaredSizeBytes: (json['declared_size_bytes'] as num?)?.toInt(),
      uploadedSizeBytes: (json['uploaded_size_bytes'] as num?)?.toInt(),
      uploadedMimeType: json['uploaded_mime_type']?.toString(),
      storageVerifiedAt: DateTime.tryParse(
        json['storage_verified_at']?.toString() ?? '',
      ),
      moderationStatus: json['moderation_status']?.toString() ?? 'approved',
      // Public projections only contain assets that the server has already
      // filtered to active/approved; private upload responses include the
      // explicit lifecycle fields.
      status: json['status']?.toString() ?? 'active',
      rejectReason: json['reject_reason']?.toString(),
      uploadKey: json['upload_key']?.toString(),
      url: json['url']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

/// Owner-scoped upload target for one persona asset. A private deployment
/// returns a single-object presigned PUT URL; a public/development deployment
/// may leave it null so the legacy STS uploader can be used.
class SocialPersonaAssetUploadTarget {
  const SocialPersonaAssetUploadTarget({
    required this.assetId,
    required this.uploadKey,
    this.uploadUrl,
    this.expiresInSeconds,
  });

  final String assetId;
  final String uploadKey;
  final String? uploadUrl;
  final int? expiresInSeconds;

  factory SocialPersonaAssetUploadTarget.fromJson(Map<String, dynamic> json) {
    return SocialPersonaAssetUploadTarget(
      assetId: json['asset_id']?.toString() ?? '',
      uploadKey: json['upload_key']?.toString() ?? '',
      uploadUrl: json['upload_url']?.toString(),
      expiresInSeconds: (json['expires_in_seconds'] as num?)?.toInt(),
    );
  }
}

class SocialPersona {
  const SocialPersona({
    this.id,
    this.userId,
    this.campusId,
    required this.representationMode,
    required this.styleVersion,
    required this.appearance,
    required this.selfDescriptions,
    required this.contactPosture,
    required this.status,
    this.selectedAssetId,
    this.asset,
    this.publishedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String? id;
  final String? userId;
  final String? campusId;
  final String representationMode;
  final String styleVersion;
  final SocialPersonaAppearance appearance;
  final List<String> selfDescriptions;
  final String contactPosture;
  final String status;
  final String? selectedAssetId;
  final SocialPersonaAsset? asset;
  final String? publishedAt;
  final String? createdAt;
  final String? updatedAt;

  bool get isPublished => status == 'published';
  bool get isDraft => status == 'draft';
  bool get isArchived => status == 'archived';

  factory SocialPersona.fromJson(Map<String, dynamic> json) {
    return SocialPersona(
      id: json['id']?.toString(),
      userId: json['user_id']?.toString(),
      campusId: json['campus_id']?.toString(),
      representationMode:
          json['representation_mode']?.toString() ?? 'trait_mapped',
      styleVersion: json['style_version']?.toString() ?? 'v1',
      appearance: SocialPersonaAppearance.fromJson(
        (json['appearance_config'] as Map?)?.cast<String, dynamic>(),
      ),
      selfDescriptions:
          (json['self_descriptions'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
      contactPosture: json['contact_posture']?.toString() ?? 'leave_message',
      // Public persona responses intentionally omit private lifecycle fields,
      // but a published_at timestamp is still an explicit server fact. Infer
      // only the public published state; missing timestamps remain private
      // draft-safe defaults.
      status:
          json['status']?.toString() ??
          (json['published_at'] == null ? 'draft' : 'published'),
      selectedAssetId: json['selected_asset_id']?.toString(),
      asset: (json['asset'] as Map?) == null
          ? null
          : SocialPersonaAsset.fromJson(
              (json['asset'] as Map).cast<String, dynamic>(),
            ),
      publishedAt: json['published_at']?.toString(),
      createdAt: json['created_at']?.toString(),
      updatedAt: json['updated_at']?.toString(),
    );
  }
}

class ReplySuggestion {
  const ReplySuggestion({required this.tone, required this.text});
  final String tone;
  final String text;

  factory ReplySuggestion.fromJson(Map<String, dynamic> json) =>
      ReplySuggestion(
        tone: json['tone']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
      );
}

class MessageReplyPreview {
  final String id;
  final String senderId;
  final String content;
  final String kind;

  const MessageReplyPreview({
    required this.id,
    required this.senderId,
    required this.content,
    required this.kind,
  });

  factory MessageReplyPreview.fromJson(Map<String, dynamic> json) {
    return MessageReplyPreview(
      id: json['id']?.toString() ?? '',
      senderId: json['sender']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'message',
    );
  }
}

class MessageReactionSummary {
  final String emoji;
  final int count;
  final bool reactedByMe;

  const MessageReactionSummary({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  factory MessageReactionSummary.fromJson(Map<String, dynamic> json) {
    return MessageReactionSummary(
      emoji: json['emoji']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      reactedByMe: json['reacted_by_me'] == true,
    );
  }
}

class MessageStructuredQuote {
  final String kind;
  final String refId;
  final Map<String, dynamic> snapshot;

  const MessageStructuredQuote({
    required this.kind,
    required this.refId,
    required this.snapshot,
  });

  factory MessageStructuredQuote.fromJson(Map<String, dynamic> json) {
    return MessageStructuredQuote(
      kind: json['kind']?.toString() ?? '',
      refId: json['ref_id']?.toString() ?? '',
      snapshot: (json['snapshot'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  String get title {
    return snapshot['title']?.toString() ??
        snapshot['listing_title']?.toString() ??
        refId;
  }

  String? get status => snapshot['status']?.toString();

  num? get primaryPrice {
    final value =
        snapshot['final_price_cny'] ??
        snapshot['counter_price_cny'] ??
        snapshot['proposed_price_cny'] ??
        snapshot['price_cny'];
    return value is num ? value : num.tryParse(value?.toString() ?? '');
  }
}

enum MessageAcknowledgementKind {
  received('received'),
  willReview('will_review'),
  completed('completed');

  const MessageAcknowledgementKind(this.wireValue);

  final String wireValue;

  static MessageAcknowledgementKind fromWire(Object? value) {
    switch (value?.toString()) {
      case 'will_review':
        return MessageAcknowledgementKind.willReview;
      case 'completed':
        return MessageAcknowledgementKind.completed;
      case 'received':
      default:
        return MessageAcknowledgementKind.received;
    }
  }
}

class MessageAcknowledgement {
  final String userId;
  final MessageAcknowledgementKind kind;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MessageAcknowledgement({
    required this.userId,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MessageAcknowledgement.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(json['updated_at']?.toString() ?? '');
    final now = DateTime.now();
    return MessageAcknowledgement(
      userId: json['user_id']?.toString() ?? '',
      kind: MessageAcknowledgementKind.fromWire(json['kind']),
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? createdAt ?? now,
    );
  }
}

/// 私聊消息
class ConversationMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final String? imageBase64;
  final String? audioBase64;
  final String? imageUrl;
  final String? audioUrl;
  final DateTime sentAt;
  final String? replyToMessageId;
  final MessageReplyPreview? replyPreview;
  final MessageStructuredQuote? quote;
  final List<MessageReactionSummary> reactions;
  final List<MessageAcknowledgement> acknowledgements;
  final bool hiddenForMe;
  final bool canHide;
  final bool canReact;
  final bool canReport;

  /// 消息状态: sending | sent | failed. Legacy delivered/read values are
  /// normalized to sent at the transport boundary.
  final String status;

  /// 已编辑时间
  final DateTime? editedAt;
  final String? clientMessageId;
  final String kind;

  ConversationMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    this.imageBase64,
    this.audioBase64,
    this.imageUrl,
    this.audioUrl,
    required this.sentAt,
    this.replyToMessageId,
    this.replyPreview,
    this.quote,
    this.reactions = const [],
    this.acknowledgements = const [],
    this.hiddenForMe = false,
    this.canHide = true,
    this.canReact = true,
    this.canReport = true,
    this.status = 'sent',
    this.editedAt,
    this.clientMessageId,
    this.kind = 'message',
  });

  factory ConversationMessage.fromJson(Map<String, dynamic> json) {
    return ConversationMessage(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      senderId: json['sender']?.toString() ?? '',
      content: json['content'] ?? '',
      imageBase64: json['image_base64'] ?? json['image_data'],
      audioBase64: json['audio_base64'] ?? json['audio_data'],
      imageUrl: json['image_url'],
      audioUrl: json['audio_url'],
      sentAt: json['sent_at'] != null
          ? DateTime.parse(json['sent_at'].toString())
          : json['timestamp'] != null
          ? DateTime.parse(json['timestamp'].toString())
          : DateTime.now(),
      replyToMessageId: json['reply_to_message_id']?.toString(),
      replyPreview: json['reply_preview'] is Map<String, dynamic>
          ? MessageReplyPreview.fromJson(
              json['reply_preview'] as Map<String, dynamic>,
            )
          : null,
      quote: json['quote'] is Map<String, dynamic>
          ? MessageStructuredQuote.fromJson(
              json['quote'] as Map<String, dynamic>,
            )
          : null,
      reactions: (json['reactions'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MessageReactionSummary.fromJson)
          .toList(),
      acknowledgements: (json['acknowledgements'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MessageAcknowledgement.fromJson)
          .toList(),
      hiddenForMe: json['hidden_for_me'] == true,
      canHide: json['can_hide'] != false,
      canReact: json['can_react'] != false,
      canReport: json['can_report'] != false,
      status: switch (json['status']?.toString()) {
        'delivered' || 'read' => 'sent',
        'sending' || 'sent' || 'failed' => json['status']!.toString(),
        _ => 'sent',
      },
      editedAt: json['edited_at'] != null
          ? DateTime.tryParse(json['edited_at'].toString())
          : null,
      clientMessageId: json['client_message_id']?.toString(),
      kind: json['kind']?.toString() ?? 'message',
    );
  }

  MessageAcknowledgement? acknowledgementFor(String userId) {
    for (final acknowledgement in acknowledgements) {
      if (acknowledgement.userId == userId) return acknowledgement;
    }
    return null;
  }

  /// 消息是否由指定用户发送
  bool isFrom(String userId) => senderId == userId;

  /// 是否可编辑（发送后15分钟内）
  bool get canEdit {
    if (editedAt != null) return false;
    final diff = DateTime.now().difference(sentAt);
    return diff.inMinutes < 15;
  }

  ConversationMessage copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? content,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
    DateTime? sentAt,
    String? replyToMessageId,
    MessageReplyPreview? replyPreview,
    MessageStructuredQuote? quote,
    List<MessageReactionSummary>? reactions,
    List<MessageAcknowledgement>? acknowledgements,
    bool? hiddenForMe,
    bool? canHide,
    bool? canReact,
    bool? canReport,
    String? status,
    DateTime? editedAt,
    String? clientMessageId,
    String? kind,
  }) {
    return ConversationMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      imageBase64: imageBase64 ?? this.imageBase64,
      audioBase64: audioBase64 ?? this.audioBase64,
      imageUrl: imageUrl ?? this.imageUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      sentAt: sentAt ?? this.sentAt,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyPreview: replyPreview ?? this.replyPreview,
      quote: quote ?? this.quote,
      reactions: reactions ?? this.reactions,
      acknowledgements: acknowledgements ?? this.acknowledgements,
      hiddenForMe: hiddenForMe ?? this.hiddenForMe,
      canHide: canHide ?? this.canHide,
      canReact: canReact ?? this.canReact,
      canReport: canReport ?? this.canReport,
      status: status ?? this.status,
      editedAt: editedAt ?? this.editedAt,
      clientMessageId: clientMessageId ?? this.clientMessageId,
      kind: kind ?? this.kind,
    );
  }
}

/// A pending agent action awaiting user confirmation (ActionPlan protocol).
/// The agent proposes writes; nothing executes until the user confirms via the
/// authenticated plans API.
class AgentPlan {
  final String id;
  final String action;
  final String riskLevel;
  final String summary;
  final String status;
  final String confirmationToken;
  final DateTime? expiresAt;
  final String? resultCode;

  AgentPlan({
    required this.id,
    required this.action,
    required this.riskLevel,
    required this.summary,
    this.status = 'pending',
    required this.confirmationToken,
    this.expiresAt,
    this.resultCode,
  });

  factory AgentPlan.fromJson(Map<String, dynamic> json) => AgentPlan(
    id: json['id']?.toString() ?? '',
    action: json['action']?.toString() ?? '',
    riskLevel: json['risk_level']?.toString() ?? 'L2',
    summary: json['summary']?.toString() ?? '',
    status: json['status']?.toString() ?? 'pending',
    confirmationToken: json['confirmation_token']?.toString() ?? '',
    expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    resultCode: json['result_code']?.toString(),
  );

  bool get isHighRisk => riskLevel == 'L3';
  bool get isArmed => status == 'confirmed_once';
}

/// Outcome of confirming an agent plan.
class AgentPlanConfirmResult {
  final String status;
  final String result;
  final String? confirmationToken;
  final String? outcomeCode;

  AgentPlanConfirmResult({
    required this.status,
    required this.result,
    this.confirmationToken,
    this.outcomeCode,
  });

  factory AgentPlanConfirmResult.fromJson(Map<String, dynamic> json) =>
      AgentPlanConfirmResult(
        status: json['status']?.toString() ?? '',
        result: json['result']?.toString() ?? '',
        confirmationToken: json['confirmation_token']?.toString(),
        outcomeCode: json['outcome_code']?.toString(),
      );

  bool get needsSecondConfirmation => status == 'needs_second_confirmation';
  bool get executed => status == 'executed';
}

/// A safe operational envelope for one marketplace Agent request.  This is
/// metadata only: prompts, transcripts, tool arguments and provider errors are
/// intentionally absent from the wire model.
class AgentRun {
  final String id;
  final String traceId;
  final String conversationId;
  final String route;
  final double? routeConfidence;
  final String? provider;
  final String? model;
  final String promptTemplateVersion;
  final String toolSchemaVersion;
  final String status;
  final String? outcomeCode;
  final int? retrievalCount;
  final int? retrievalFilteredCount;
  final int toolCallCount;
  final List<String> finalResourceIds;
  final int? ttftMs;
  final int? durationMs;
  final DateTime? createdAt;
  final DateTime? completedAt;

  AgentRun({
    required this.id,
    required this.traceId,
    required this.conversationId,
    required this.route,
    this.routeConfidence,
    this.provider,
    this.model,
    this.promptTemplateVersion = '',
    this.toolSchemaVersion = '',
    this.status = 'started',
    this.outcomeCode,
    this.retrievalCount,
    this.retrievalFilteredCount,
    this.toolCallCount = 0,
    this.finalResourceIds = const [],
    this.ttftMs,
    this.durationMs,
    this.createdAt,
    this.completedAt,
  });

  factory AgentRun.fromJson(Map<String, dynamic> json) => AgentRun(
    id: json['id']?.toString() ?? '',
    traceId: json['trace_id']?.toString() ?? '',
    conversationId: json['conversation_id']?.toString() ?? '',
    route: json['route']?.toString() ?? 'chat',
    routeConfidence: (json['route_confidence'] as num?)?.toDouble(),
    provider: json['provider']?.toString(),
    model: json['model']?.toString(),
    promptTemplateVersion: json['prompt_template_version']?.toString() ?? '',
    toolSchemaVersion: json['tool_schema_version']?.toString() ?? '',
    status: json['status']?.toString() ?? 'started',
    outcomeCode: json['outcome_code']?.toString(),
    retrievalCount: (json['retrieval_count'] as num?)?.toInt(),
    retrievalFilteredCount: (json['retrieval_filtered_count'] as num?)?.toInt(),
    toolCallCount: (json['tool_call_count'] as num?)?.toInt() ?? 0,
    finalResourceIds: (json['final_resource_ids'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false),
    ttftMs: (json['ttft_ms'] as num?)?.toInt(),
    durationMs: (json['duration_ms'] as num?)?.toInt(),
    createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    completedAt: DateTime.tryParse(json['completed_at']?.toString() ?? ''),
  );

  bool get completed => status == 'completed';
}

/// An action the assistant already carried out that can still be reverted.
///
/// The counterpart to [AgentPlan]: plans are writes waiting on the user, these
/// are writes that happened. Low-risk actions no longer queue behind a
/// confirmation dialog — they run at once and stay recoverable for a few
/// minutes, so the common case costs nothing and the rare wrong one is still
/// fixable.
class UndoableAction {
  final String id;
  final String actionKind;
  final String summary;
  final DateTime? undoDeadline;

  UndoableAction({
    required this.id,
    required this.actionKind,
    required this.summary,
    this.undoDeadline,
  });

  factory UndoableAction.fromJson(Map<String, dynamic> json) => UndoableAction(
    id: json['id']?.toString() ?? '',
    actionKind: json['action_kind']?.toString() ?? '',
    summary: json['summary']?.toString() ?? '',
    undoDeadline: DateTime.tryParse(json['undo_deadline']?.toString() ?? ''),
  );

  /// Time left in the window, or null when the deadline is unknown.
  Duration? remaining() {
    final deadline = undoDeadline;
    if (deadline == null) return null;
    final left = deadline.difference(DateTime.now().toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  bool get expired => remaining() == Duration.zero;
}

/// Outcome of an undo attempt.
///
/// [conflict] is deliberately distinct from a plain failure: it means the
/// action was not reverted *because the world moved on* — the item sold, or
/// someone edited it — and reverting would have overwritten that. The user
/// needs to be told what happened, not shown a generic error.
class UndoResult {
  final bool undone;
  final bool conflict;
  final String message;

  UndoResult({
    required this.undone,
    required this.conflict,
    required this.message,
  });
}

class HitlRequest {
  final String id;
  final String listingId;
  final String buyerId;
  final String sellerId;
  final double proposedPrice;
  final String reason;
  final String status; // pending | countered | approved | rejected | expired
  final double? counterPrice;
  final String createdAt;
  final String? expiresAt;

  HitlRequest({
    required this.id,
    required this.listingId,
    required this.buyerId,
    required this.sellerId,
    required this.proposedPrice,
    required this.reason,
    required this.status,
    this.counterPrice,
    required this.createdAt,
    this.expiresAt,
  });

  factory HitlRequest.fromJson(Map<String, dynamic> json) {
    return HitlRequest(
      id: json['id'] ?? '',
      listingId: json['listing_id'] ?? '',
      buyerId: json['buyer_id'] ?? '',
      sellerId: json['seller_id'] ?? '',
      proposedPrice: (json['proposed_price'] ?? 0).toDouble(),
      reason: json['reason'] ?? '',
      status: json['status'] ?? 'pending',
      counterPrice: json['counter_price']?.toDouble(),
      createdAt: json['created_at'] ?? '',
      expiresAt: json['expires_at'],
    );
  }

  bool get isPending => status == 'pending';
  bool get isCountered => status == 'countered';
  bool get isExpired => status == 'expired';
  bool get isFinal => status == 'approved' || status == 'rejected';
}

/// Order summary for list view.
class Order {
  final String id;
  final String listingId;
  final String listingTitle;
  final String buyerId;
  final String sellerId;
  final String buyerUsername;
  final String sellerUsername;
  final double finalPriceCny;
  final String status;
  final bool autoDelist;
  final String? confirmedAt;
  final String? autoDelistedAt;
  final String listingStatus;
  final String createdAt;
  final String role;

  const Order({
    required this.id,
    required this.listingId,
    required this.listingTitle,
    required this.buyerId,
    required this.sellerId,
    required this.buyerUsername,
    required this.sellerUsername,
    required this.finalPriceCny,
    required this.status,
    this.autoDelist = true,
    this.confirmedAt,
    this.autoDelistedAt,
    this.listingStatus = '',
    required this.createdAt,
    required this.role,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] ?? '',
      listingId: json['listing_id'] ?? '',
      listingTitle: json['listing_title'] ?? '',
      buyerId: json['buyer_id'] ?? '',
      sellerId: json['seller_id'] ?? '',
      buyerUsername: json['buyer_username'] ?? '',
      sellerUsername: json['seller_username'] ?? '',
      finalPriceCny: (json['final_price_cny'] ?? 0).toDouble(),
      status: json['status'] ?? 'intent_pending',
      autoDelist: json['auto_delist'] ?? true,
      confirmedAt: json['confirmed_at'],
      autoDelistedAt: json['auto_delisted_at'],
      listingStatus: json['listing_status'] ?? '',
      createdAt: json['created_at'] ?? '',
      role: json['role'] ?? 'buyer',
    );
  }

  String get statusLabel {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return '待卖家确认';
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return '已确认成交';
      case 'cancelled':
        return '已取消';
      default:
        return status;
    }
  }

  Color get statusColor {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return const Color(0xFFF59E0B);
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return const Color(0xFF10B981);
      case 'cancelled':
        return const Color(0xFF6B7280);
      default:
        return Colors.grey;
    }
  }
}

class OrdersResponse {
  final List<Order> items;
  final int total;
  final int limit;
  final int offset;

  const OrdersResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory OrdersResponse.fromJson(Map<String, dynamic> json) {
    return OrdersResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => Order.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] ?? 0,
      limit: json['limit'] ?? 20,
      offset: json['offset'] ?? 0,
    );
  }
}

class OrderDetail {
  final String id;
  final String listingId;
  final String listingTitle;
  final String buyerId;
  final String sellerId;
  final String buyerUsername;
  final String sellerUsername;
  final double finalPriceCny;
  final String status;
  final bool autoDelist;
  final String? confirmedAt;
  final String? confirmedBy;
  final String? autoDelistedAt;
  final String listingStatus;
  final String createdAt;
  final String? paidAt;
  final String? shippedAt;
  final String? completedAt;
  final String? cancelledAt;
  final String? cancellationReason;
  final bool canConfirmDeal;
  final bool canCancelDeal;
  final bool canChooseAutoDelist;

  const OrderDetail({
    required this.id,
    required this.listingId,
    required this.listingTitle,
    required this.buyerId,
    required this.sellerId,
    required this.buyerUsername,
    required this.sellerUsername,
    required this.finalPriceCny,
    required this.status,
    this.autoDelist = true,
    this.confirmedAt,
    this.confirmedBy,
    this.autoDelistedAt,
    this.listingStatus = '',
    required this.createdAt,
    this.paidAt,
    this.shippedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancellationReason,
    this.canConfirmDeal = false,
    this.canCancelDeal = false,
    this.canChooseAutoDelist = false,
  });

  factory OrderDetail.fromJson(Map<String, dynamic> json) {
    return OrderDetail(
      id: json['id'] ?? '',
      listingId: json['listing_id'] ?? '',
      listingTitle: json['listing_title'] ?? '',
      buyerId: json['buyer_id'] ?? '',
      sellerId: json['seller_id'] ?? '',
      buyerUsername: json['buyer_username'] ?? '',
      sellerUsername: json['seller_username'] ?? '',
      finalPriceCny: (json['final_price_cny'] ?? 0).toDouble(),
      status: json['status'] ?? 'intent_pending',
      autoDelist: json['auto_delist'] ?? true,
      confirmedAt: json['confirmed_at'],
      confirmedBy: json['confirmed_by'],
      autoDelistedAt: json['auto_delisted_at'],
      listingStatus: json['listing_status'] ?? '',
      createdAt: json['created_at'] ?? '',
      paidAt: json['paid_at'],
      shippedAt: json['shipped_at'],
      completedAt: json['completed_at'],
      cancelledAt: json['cancelled_at'],
      cancellationReason: json['cancellation_reason'],
      canConfirmDeal: json['capabilities']?['can_confirm'] ?? false,
      canCancelDeal: json['capabilities']?['can_cancel'] ?? false,
      canChooseAutoDelist:
          json['capabilities']?['can_choose_auto_delist'] ?? false,
    );
  }

  String get statusLabel {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return '待卖家确认';
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return '已确认成交';
      case 'cancelled':
        return '已取消';
      default:
        return status;
    }
  }

  Color get statusColor {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return const Color(0xFFF59E0B);
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return const Color(0xFF10B981);
      case 'cancelled':
        return const Color(0xFF6B7280);
      default:
        return Colors.grey;
    }
  }

  bool get canPay => false;
  bool get canShip => false;
  bool get canConfirm => canConfirmDeal;
  bool get canCancel => canCancelDeal;
}

/// What someone wants, before it has been forced into a form.
///
/// The five kinds share one model on purpose: a thing to sell, a partner to
/// find and a favour to ask are the same object, and giving each its own screen
/// is what makes people file their own life under the wrong menu.
enum IntentKind {
  goodsOffer('goods_offer'),
  goodsSeek('goods_seek'),
  companion('companion'),
  help('help'),
  activity('activity');

  const IntentKind(this.wire);
  final String wire;

  static IntentKind? fromWire(String? value) {
    for (final kind in IntentKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }

  /// Whether this kind has a price worth asking about. Nobody prices a
  /// badminton partner.
  bool get hasPrice => this == goodsOffer || this == goodsSeek;
}

/// A price the author may have declined to pin down.
///
/// `whatever` is a complete answer, not a blank. Someone clearing a dorm room
/// says "能卖多少卖多少" and means exactly that; making them type a number would
/// put a figure on the listing that they never chose.
class PriceSlot {
  final String kind; // exact | range | free | whatever
  final int? cents;
  final int? maxCents;
  final String? hint;

  const PriceSlot({required this.kind, this.cents, this.maxCents, this.hint});

  static const whatever = PriceSlot(kind: 'whatever');
  static const free = PriceSlot(kind: 'free');
  factory PriceSlot.exact(int cents) => PriceSlot(kind: 'exact', cents: cents);
  factory PriceSlot.upTo(int cents) =>
      PriceSlot(kind: 'range', maxCents: cents);

  factory PriceSlot.fromJson(Map<String, dynamic> json) => PriceSlot(
    kind: json['kind']?.toString() ?? 'whatever',
    cents: (json['cents'] as num?)?.toInt(),
    maxCents: (json['max_cents'] as num?)?.toInt(),
    hint: json['hint']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (cents != null) 'cents': cents,
    if (maxCents != null) 'max_cents': maxCents,
    if (hint != null && hint!.isNotEmpty) 'hint': hint,
  };
}

/// A time the author may have left open.
class TimeSlot {
  final String kind; // exact | window | flexible
  final DateTime? at;
  final String? hint;

  const TimeSlot({required this.kind, this.at, this.hint});

  static TimeSlot flexible([String? hint]) =>
      TimeSlot(kind: 'flexible', hint: hint);

  factory TimeSlot.fromJson(Map<String, dynamic> json) => TimeSlot(
    kind: json['kind']?.toString() ?? 'flexible',
    at: DateTime.tryParse(json['at']?.toString() ?? ''),
    hint: json['hint']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (at != null) 'at': at!.toUtc().toIso8601String(),
    if (hint != null && hint!.isNotEmpty) 'hint': hint,
  };
}

/// The structured reading of an intent. Every field may be absent — a partial
/// intent is a real one.
class IntentSlots {
  final String? subject;
  final String? category;
  final PriceSlot? price;
  final TimeSlot? time;
  final String? place;

  const IntentSlots({
    this.subject,
    this.category,
    this.price,
    this.time,
    this.place,
  });

  factory IntentSlots.fromJson(Map<String, dynamic> json) => IntentSlots(
    subject: json['subject']?.toString(),
    category: json['category']?.toString(),
    price: json['price'] is Map<String, dynamic>
        ? PriceSlot.fromJson(json['price'] as Map<String, dynamic>)
        : null,
    time: json['time'] is Map<String, dynamic>
        ? TimeSlot.fromJson(json['time'] as Map<String, dynamic>)
        : null,
    place: json['place']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    if (subject != null && subject!.isNotEmpty) 'subject': subject,
    if (category != null && category!.isNotEmpty) 'category': category,
    if (price != null) 'price': price!.toJson(),
    if (time != null) 'time': time!.toJson(),
    if (place != null && place!.isNotEmpty) 'place': place,
  };
}

class UserIntent {
  final String id;
  final IntentKind kind;
  final String rawInput;
  final IntentSlots slots;
  final String status;
  final DateTime? validUntil;
  final String? projectedListingId;
  final String? rankReason;
  final List<String> matchSummary;
  final String? source;

  const UserIntent({
    required this.id,
    required this.kind,
    required this.rawInput,
    required this.slots,
    required this.status,
    this.validUntil,
    this.projectedListingId,
    this.rankReason,
    this.matchSummary = const [],
    this.source,
  });

  factory UserIntent.fromJson(Map<String, dynamic> json) => UserIntent(
    id: json['id']?.toString() ?? '',
    kind:
        IntentKind.fromWire(json['kind']?.toString()) ?? IntentKind.goodsOffer,
    rawInput: json['raw_input']?.toString() ?? '',
    slots: json['slots'] is Map<String, dynamic>
        ? IntentSlots.fromJson(json['slots'] as Map<String, dynamic>)
        : const IntentSlots(),
    status: json['status']?.toString() ?? 'active',
    validUntil: DateTime.tryParse(json['valid_until']?.toString() ?? ''),
    projectedListingId: json['projected_listing_id']?.toString(),
    rankReason: json['rank_reason']?.toString(),
    matchSummary: (json['match_summary'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(),
    source: json['source']?.toString(),
  );

  /// Inferred rather than stated, so it is waiting on the author before anyone
  /// else can see it.
  bool get isDraft => status == 'draft';
}

/// Result of recording an intent.
class IntentCreated {
  final String id;

  /// Present only when the intent could also be shown honestly as a listing.
  /// Absent for unpriced ones — the grid needs a price and inventing one would
  /// misrepresent the owner.
  final String? projectedListingId;

  /// 0..1 of how much was pinned down. Used to decide whether one follow-up
  /// question is worth asking, never to reject the intent.
  final double specificity;

  const IntentCreated({
    required this.id,
    this.projectedListingId,
    required this.specificity,
  });

  factory IntentCreated.fromJson(Map<String, dynamic> json) => IntentCreated(
    id: json['id']?.toString() ?? '',
    projectedListingId: json['projected_listing_id']?.toString(),
    specificity: (json['specificity'] as num?)?.toDouble() ?? 0,
  );
}

/// A private-limit price negotiation.
///
/// Note what this class cannot hold: the other side's limit, or how far apart
/// the two were. The server never sends either, and there is deliberately
/// nowhere here to put them — a field would be an invitation.
class PriceDiscoverySession {
  final String id;
  final String status; // proposed | open | matched | no_deal | declined
  /// The agreed price, present only on a match. This is the agreement, not
  /// either party's position.
  final int? matchedCents;

  /// Whether *you* have stated your limit. Never whether they have: knowing
  /// someone is still deciding is itself a small advantage.
  final bool youHaveStated;

  const PriceDiscoverySession({
    required this.id,
    required this.status,
    this.matchedCents,
    required this.youHaveStated,
  });

  factory PriceDiscoverySession.fromJson(Map<String, dynamic> json) =>
      PriceDiscoverySession(
        id: json['id']?.toString() ?? '',
        status: json['status']?.toString() ?? 'proposed',
        matchedCents: (json['matched_cents'] as num?)?.toInt(),
        youHaveStated: json['you_have_stated'] == true,
      );

  bool get isProposed => status == 'proposed';
  bool get isOpen => status == 'open';
  bool get isMatched => status == 'matched';
  bool get isNoDeal => status == 'no_deal';
  bool get isDeclined => status == 'declined';
}

/// A session plus the rule that produced it.
///
/// The rule travels with every response so the interface can always show it. A
/// pricing black box is worse than haggling — at least haggling is legible.
class PriceDiscoveryResult {
  final PriceDiscoverySession? session;
  final String rule;
  final String? sessionId;
  final String? outcome;

  const PriceDiscoveryResult({
    this.session,
    required this.rule,
    this.sessionId,
    this.outcome,
  });

  factory PriceDiscoveryResult.fromJson(Map<String, dynamic> json) =>
      PriceDiscoveryResult(
        session: json['session'] is Map<String, dynamic>
            ? PriceDiscoverySession.fromJson(
                json['session'] as Map<String, dynamic>,
              )
            : null,
        rule: json['rule']?.toString() ?? '',
        sessionId: json['session_id']?.toString(),
        outcome: json['outcome']?.toString(),
      );
}

/// One term of an arrangement.
class AgreementTerm {
  final String slot;

  /// In whoever's words it came from. Not normalised: the card exists so both
  /// people recognise their own arrangement in it.
  final String value;
  final int? valueCents;
  final String proposedBy;
  final List<String> agreedBy;

  /// An extraction nobody has confirmed. Rendered as a suggestion, never as the
  /// arrangement — a proposal that looks like a decision is the failure mode
  /// this whole design guards against.
  final bool isSuggestion;

  const AgreementTerm({
    required this.slot,
    required this.value,
    this.valueCents,
    required this.proposedBy,
    required this.agreedBy,
    required this.isSuggestion,
  });

  factory AgreementTerm.fromJson(Map<String, dynamic> json) => AgreementTerm(
    slot: json['slot']?.toString() ?? '',
    value: json['value']?.toString() ?? '',
    valueCents: (json['value_cents'] as num?)?.toInt(),
    proposedBy: json['proposed_by']?.toString() ?? '',
    agreedBy: (json['agreed_by'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    isSuggestion: json['is_suggestion'] == true,
  );

  bool settledBy(List<String> participants) =>
      participants.every(agreedBy.contains);
}

/// The living state of an arrangement: what, how much, when, where.
class Agreement {
  final String id;
  final String kind; // deal | meetup
  final String status; // forming | settled | abandoned
  final List<AgreementTerm> terms;
  final List<String> participants;
  final bool fullyAgreed;
  final List<String> availableSlots;

  const Agreement({
    required this.id,
    required this.kind,
    required this.status,
    required this.terms,
    required this.participants,
    required this.fullyAgreed,
    required this.availableSlots,
  });

  factory Agreement.fromJson(Map<String, dynamic> json) {
    final a = json['agreement'] as Map<String, dynamic>? ?? const {};
    return Agreement(
      id: a['id']?.toString() ?? '',
      kind: a['kind']?.toString() ?? 'deal',
      status: a['status']?.toString() ?? 'forming',
      terms: (a['terms'] as List<dynamic>? ?? [])
          .map((e) => AgreementTerm.fromJson(e as Map<String, dynamic>))
          .toList(),
      participants: (a['participants'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      fullyAgreed: json['fully_agreed'] == true,
      // Taken from the server so the client does not hardcode a list that
      // drifts from what the card can actually hold.
      availableSlots: (json['available_slots'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  bool get isSettled => status == 'settled';
}

/// What is known about someone, in facts.
///
/// No score. "Completed 12, on time 11" is a sentence a person can check
/// against their own memory; a rating out of five can only be resented, and on
/// a campus where everyone meets again, it is either all fives or a fight.
class Reputation {
  final int completed;
  final int onTime;
  final int missed;

  /// Whether there is enough here to mean anything. A newcomer is unmeasured,
  /// not untrusted, and the interface has to say which.
  final bool hasTrackRecord;

  /// Exposed so ranking is explainable rather than a hidden score.
  final double matchingWeight;

  const Reputation({
    required this.completed,
    required this.onTime,
    required this.missed,
    required this.hasTrackRecord,
    required this.matchingWeight,
  });

  factory Reputation.fromJson(Map<String, dynamic> json) {
    final r = json['reputation'] as Map<String, dynamic>? ?? const {};
    return Reputation(
      completed: (r['completed'] as num?)?.toInt() ?? 0,
      onTime: (r['on_time'] as num?)?.toInt() ?? 0,
      missed: (r['missed'] as num?)?.toInt() ?? 0,
      hasTrackRecord: r['has_track_record'] == true,
      matchingWeight: (json['matching_weight'] as num?)?.toDouble() ?? 0.5,
    );
  }
}
