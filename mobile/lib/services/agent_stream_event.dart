/// Token usage summary sent at turn completion.
class AgentUsageSummary {
  final int modelSteps;
  final int toolCalls;
  final int? promptTokens;
  final int? completionTokens;

  const AgentUsageSummary({
    required this.modelSteps,
    required this.toolCalls,
    this.promptTokens,
    this.completionTokens,
  });

  factory AgentUsageSummary.fromJson(Map<String, dynamic> json) {
    return AgentUsageSummary(
      modelSteps: (json['model_steps'] as num?)?.toInt() ?? 0,
      toolCalls: (json['tool_calls'] as num?)?.toInt() ?? 0,
      promptTokens: (json['prompt_tokens'] as num?)?.toInt(),
      completionTokens: (json['completion_tokens'] as num?)?.toInt(),
    );
  }
}

/// Structured agent event from the v2 protocol.
class AgentStreamEvent {
  const AgentStreamEvent({
    required this.type,
    required this.seq,
    this.protocolVersion = '2.0',
    this.turnId,
    this.conversationId,
    this.text,
    this.toolName,
    this.toolStatus,
    this.actionType,
    this.actionPayload,
    this.status,
    this.errorCode,
    this.errorMessage,
    this.cancelReason,
    this.usage,
  });

  static const Set<String> _knownTypes = {
    'turn_started',
    'status_changed',
    'text_delta',
    'tool_started',
    'tool_finished',
    'ui_action',
    'usage',
    'heartbeat',
    'turn_completed',
    'turn_failed',
    'turn_cancelled',
  };

  factory AgentStreamEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == null || type.trim().isEmpty) {
      throw const FormatException('Missing or empty event type');
    }
    if (!_knownTypes.contains(type)) {
      throw FormatException('Unknown event type: $type');
    }
    final rawSeq = json['seq'];
    if (rawSeq is! int || rawSeq < 1) {
      throw const FormatException('seq must be a positive integer >= 1');
    }
    final seq = rawSeq;
    final protocolVersion = json['protocol_version'] as String?;
    if (protocolVersion == null || protocolVersion != '2.0') {
      throw FormatException(
        'Invalid protocol version: $protocolVersion (expected 2.0)',
      );
    }
    final turnId = json['turn_id'] as String?;
    if (turnId == null || turnId.trim().isEmpty) {
      throw const FormatException(
        'Missing or empty turn_id in agent stream event',
      );
    }
    final conversationId = json['conversation_id'] as String?;
    if (conversationId == null || conversationId.trim().isEmpty) {
      throw const FormatException(
        'Missing or empty conversation_id in agent stream event',
      );
    }
    String? text;
    String? toolName;
    String? toolStatus;
    String? actionType;
    Map<String, dynamic>? actionPayload;
    String? status;
    String? errorCode;
    String? errorMessage;
    String? cancelReason;
    AgentUsageSummary? usage;

    switch (type) {
      case 'text_delta':
        final rawText = json['text'];
        if (rawText is! String) {
          throw const FormatException('Missing or invalid text in text_delta event');
        }
        text = rawText;
      case 'tool_started' || 'tool_finished':
        final call = json['call'];
        if (call is! Map) {
          throw FormatException('Missing or invalid call in $type event');
        }
        toolName = call['name'] as String?;
        toolStatus = call['status'] as String?;
        if (toolName == null || toolName.trim().isEmpty) {
          throw FormatException('Missing or empty call name in $type event');
        }
      case 'ui_action':
        final action = json['action'];
        if (action is! Map) {
          throw const FormatException('Missing or invalid action in ui_action event');
        }
        actionType = action['action_type'] as String?;
        if (actionType == null || actionType.trim().isEmpty) {
          throw const FormatException('Missing or empty action_type in ui_action event');
        }
        if (action['payload'] != null) {
          actionPayload = Map<String, dynamic>.from(action['payload'] as Map);
        }
      case 'status_changed':
        final rawStatus = json['status'];
        if (rawStatus is! String || rawStatus.trim().isEmpty) {
          throw const FormatException('Missing or empty status in status_changed event');
        }
        status = rawStatus;
      case 'turn_started':
        status = 'started';
      case 'turn_completed':
        final rawUsage = json['usage'];
        if (rawUsage is! Map) {
          throw const FormatException('Missing usage in turn_completed event');
        }
        usage = AgentUsageSummary.fromJson(
          Map<String, dynamic>.from(rawUsage),
        );
      case 'turn_failed':
        final error = json['error'];
        if (error is! Map) {
          throw const FormatException('Missing error in turn_failed event');
        }
        errorCode = error['code'] as String?;
        errorMessage = error['message'] as String?;
        if (errorCode == null || errorCode.trim().isEmpty || errorMessage == null || errorMessage.trim().isEmpty) {
          throw const FormatException('Missing error code or message in turn_failed event');
        }
      case 'turn_cancelled':
        final reason = json['reason'];
        if (reason is! String || reason.trim().isEmpty) {
          throw const FormatException('Missing reason in turn_cancelled event');
        }
        cancelReason = reason;
      case 'heartbeat':
        break;
      case 'usage':
        final rawUsage = json['usage'];
        if (rawUsage is! Map) {
          throw const FormatException('Missing usage in usage event');
        }
        usage = AgentUsageSummary.fromJson(
          Map<String, dynamic>.from(rawUsage),
        );
    }

    return AgentStreamEvent(
      type: type,
      seq: seq,
      protocolVersion: protocolVersion,
      turnId: turnId,
      conversationId: conversationId,
      text: text,
      toolName: toolName,
      toolStatus: toolStatus,
      actionType: actionType,
      actionPayload: actionPayload,
      status: status,
      errorCode: errorCode,
      errorMessage: errorMessage,
      cancelReason: cancelReason,
      usage: usage,
    );
  }

  final String type;
  final int seq;
  final String protocolVersion;
  final String? turnId;
  final String? conversationId;
  final String? text;
  final String? toolName;
  final String? toolStatus;
  final String? actionType;
  final Map<String, dynamic>? actionPayload;
  final String? status;
  final String? errorCode;
  final String? errorMessage;
  final String? cancelReason;
  final AgentUsageSummary? usage;

  bool get isTerminal =>
      type == 'turn_completed' ||
      type == 'turn_failed' ||
      type == 'turn_cancelled';
}

class StreamTruncatedException implements Exception {
  final String message;
  const StreamTruncatedException([
    this.message =
        'Agent stream terminated prematurely without a terminal event',
  ]);

  @override
  String toString() => 'StreamTruncatedException: $message';
}

class ProtocolViolationException implements Exception {
  final String message;
  const ProtocolViolationException(this.message);

  @override
  String toString() => 'ProtocolViolationException: $message';
}

/// Validates protocol 2.0 stream monotonicity, turn ID consistency,
/// expected conversation ID, fixed start (turn_started with seq=1),
/// and terminal completion before stream termination.
class AgentTurnValidator {
  AgentTurnValidator({this.expectedConversationId});

  String? expectedConversationId;
  String? _activeTurnId;
  int? _expectedSeq;
  bool _terminalEventSeen = false;

  bool get hasSeenTerminalEvent => _terminalEventSeen;

  /// Validates an incoming parsed [AgentStreamEvent].
  /// Returns `true` if the event is a heartbeat frame that should be filtered
  /// after sequence validation.
  bool validateEvent(AgentStreamEvent event) {
    if (_terminalEventSeen) {
      throw ProtocolViolationException(
        'Event ${event.type} (seq=${event.seq}) received after terminal event was already received',
      );
    }

    if (event.protocolVersion != '2.0') {
      throw ProtocolViolationException(
        'Protocol version mismatch: expected 2.0, got ${event.protocolVersion}',
      );
    }

    final turnId = event.turnId;
    if (turnId == null || turnId.trim().isEmpty) {
      throw const ProtocolViolationException('Missing or empty turn_id');
    }

    if (_activeTurnId == null) {
      _activeTurnId = turnId;
    } else if (turnId != _activeTurnId) {
      throw ProtocolViolationException(
        'Turn ID mismatch: expected $_activeTurnId, got $turnId',
      );
    }

    final convId = event.conversationId;
    if (convId == null || convId.trim().isEmpty) {
      throw const ProtocolViolationException('Missing or empty conversation_id');
    }

    if (expectedConversationId == null) {
      expectedConversationId = convId;
    } else if (convId != expectedConversationId) {
      throw ProtocolViolationException(
        'Conversation ID mismatch: expected $expectedConversationId, got $convId',
      );
    }

    if (_expectedSeq == null) {
      if (event.type != 'turn_started' || event.seq != 1) {
        throw ProtocolViolationException(
          'First event must be turn_started with seq=1, got ${event.type} with seq=${event.seq}',
        );
      }
      _expectedSeq = 1;
    } else if (event.seq != _expectedSeq) {
      throw ProtocolViolationException(
        'Sequence gap or regression: expected seq $_expectedSeq, got ${event.seq} (type=${event.type})',
      );
    }
    _expectedSeq = _expectedSeq! + 1;

    if (event.isTerminal) {
      _terminalEventSeen = true;
    }

    return event.type == 'heartbeat';
  }

  /// Call on stream EOF (`onDone`).
  /// Throws [StreamTruncatedException] if the stream closed before receiving
  /// a terminal event (`turn_completed`, `turn_failed`, or `turn_cancelled`).
  void assertTerminalEventSeen() {
    if (!_terminalEventSeen) {
      throw const StreamTruncatedException(
        'Agent stream closed (EOF) before terminal event was received',
      );
    }
  }

  void reset({String? expectedConversationId}) {
    this.expectedConversationId = expectedConversationId;
    _activeTurnId = null;
    _expectedSeq = null;
    _terminalEventSeen = false;
  }
}
