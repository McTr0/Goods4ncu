import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class Listing {
  final String id;
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

  /// Why the feed ranked this item here (server-provided, personalized feeds).
  final String? rankReason;

  Listing({
    required this.id,
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
    this.rankReason,
  });

  factory Listing.fromJson(Map<String, dynamic> json) {
    return Listing(
      id: json['id'] ?? '',
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
      rankReason: json['rank_reason'],
    );
  }

  String get conditionLabel => AppTheme.conditionLabel(conditionScore);

  Color get conditionColor => AppTheme.conditionColor(conditionScore);

  bool get isWanted => direction == 'wanted';

  bool get isOffer => !isWanted;

  String get directionLabelZh => isWanted ? '收' : '出';

  String get priceSemanticLabelZh => isWanted ? '预算上限' : '价格';

  String get conditionSemanticLabelZh => isWanted ? '最低成色' : '成色';
}

class ListingsResponse {
  final List<Listing> items;
  final int total;
  final int limit;
  final int offset;

  ListingsResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory ListingsResponse.fromJson(Map<String, dynamic> json) {
    return ListingsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => Listing.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] ?? 0,
      limit: json['limit'] ?? 20,
      offset: json['offset'] ?? 0,
    );
  }
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
  final bool isRead;
  final String createdAt;

  const AppNotification({
    required this.id,
    required this.eventType,
    required this.title,
    required this.body,
    this.relatedOrderId,
    this.relatedListingId,
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

enum ConnectionStatusType { online, offline, pending }

class Conversation {
  Conversation({
    required this.id,
    String? initiatorId,
    String? requesterId,
    this.recipientId = '',
    required this.otherUserId,
    required this.otherUsername,
    ConversationMode? mode,
    ConversationState? state,
    String? status,
    this.listingId,
    this.listingTitle,
    this.subject,
    this.lastMessage,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.readReceiptMode = 'inherit',
    this.effectiveReadReceiptMode = 'auto',
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
  final int unreadCount;
  final String readReceiptMode;
  final String effectiveReadReceiptMode;
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
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      readReceiptMode: json['read_receipt_mode']?.toString() ?? 'inherit',
      effectiveReadReceiptMode:
          json['effective_read_receipt_mode']?.toString() ?? 'auto',
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
        ? ConnectionStatusType.online
        : ConnectionStatusType.offline;
  }
}

class ChatThread {
  const ChatThread({
    required this.peerUserId,
    required this.peerUsername,
    required this.latestActivityAt,
    this.latestPreview,
    this.unreadCount = 0,
    this.conversationCount = 0,
    this.mailCount = 0,
    this.realtimeCount = 0,
    this.pendingCount = 0,
    this.hasActiveRealtime = false,
    this.latestListingTitle,
  });

  final String peerUserId;
  final String peerUsername;
  final DateTime latestActivityAt;
  final String? latestPreview;
  final int unreadCount;
  final int conversationCount;
  final int mailCount;
  final int realtimeCount;
  final int pendingCount;
  final bool hasActiveRealtime;
  final String? latestListingTitle;

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    return ChatThread(
      peerUserId: json['peer_user_id']?.toString() ?? '',
      peerUsername: json['peer_username']?.toString() ?? '',
      latestActivityAt:
          DateTime.tryParse(json['latest_activity_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      latestPreview: json['latest_preview']?.toString(),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      conversationCount: (json['conversation_count'] as num?)?.toInt() ?? 0,
      mailCount: (json['mail_count'] as num?)?.toInt() ?? 0,
      realtimeCount: (json['realtime_count'] as num?)?.toInt() ?? 0,
      pendingCount: (json['pending_count'] as num?)?.toInt() ?? 0,
      hasActiveRealtime: json['has_active_realtime'] == true,
      latestListingTitle: json['latest_listing_title']?.toString(),
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
  final DateTime? readAt;
  final String? replyToMessageId;
  final MessageReplyPreview? replyPreview;
  final MessageStructuredQuote? quote;
  final List<MessageReactionSummary> reactions;
  final bool hiddenForMe;
  final bool canHide;
  final bool canReact;
  final bool canReport;

  /// 消息状态: sending | sent | delivered | read | failed
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
    this.readAt,
    this.replyToMessageId,
    this.replyPreview,
    this.quote,
    this.reactions = const [],
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
      readAt: json['read_at'] != null
          ? DateTime.tryParse(json['read_at'].toString())
          : null,
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
      reactions: (json['reactions'] as List<dynamic>? ?? const []).map((item) {
        return MessageReactionSummary.fromJson(item as Map<String, dynamic>);
      }).toList(),
      hiddenForMe: json['hidden_for_me'] == true,
      canHide: json['can_hide'] != false,
      canReact: json['can_react'] != false,
      canReport: json['can_report'] != false,
      status: json['status'] ?? 'sent',
      editedAt: json['edited_at'] != null
          ? DateTime.tryParse(json['edited_at'].toString())
          : null,
      clientMessageId: json['client_message_id']?.toString(),
      kind: json['kind']?.toString() ?? 'message',
    );
  }

  /// 消息是否已读（有连接且已读）
  bool get isRead => readAt != null;

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
    DateTime? readAt,
    String? replyToMessageId,
    MessageReplyPreview? replyPreview,
    MessageStructuredQuote? quote,
    List<MessageReactionSummary>? reactions,
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
      readAt: readAt ?? this.readAt,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyPreview: replyPreview ?? this.replyPreview,
      quote: quote ?? this.quote,
      reactions: reactions ?? this.reactions,
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
  final String confirmationToken;
  final DateTime? expiresAt;

  AgentPlan({
    required this.id,
    required this.action,
    required this.riskLevel,
    required this.summary,
    required this.confirmationToken,
    this.expiresAt,
  });

  factory AgentPlan.fromJson(Map<String, dynamic> json) => AgentPlan(
    id: json['id']?.toString() ?? '',
    action: json['action']?.toString() ?? '',
    riskLevel: json['risk_level']?.toString() ?? 'L2',
    summary: json['summary']?.toString() ?? '',
    confirmationToken: json['confirmation_token']?.toString() ?? '',
    expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
  );

  bool get isHighRisk => riskLevel == 'L3';
}

/// Outcome of confirming an agent plan.
class AgentPlanConfirmResult {
  final String status;
  final String result;
  AgentPlanConfirmResult({required this.status, required this.result});
  bool get needsSecondConfirmation => status == 'needs_second_confirmation';
  bool get executed => status == 'executed';
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
