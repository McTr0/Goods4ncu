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

  factory AgentStreamEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    final seq = (json['seq'] as num?)?.toInt() ?? 0;
    final protocolVersion = json['protocol_version'] as String? ?? '2.0';
    final turnId = json['turn_id'] as String?;
    final conversationId = json['conversation_id'] as String?;
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
        text = json['text'] as String?;
      case 'tool_started' || 'tool_finished':
        final call = json['call'] as Map<String, dynamic>?;
        toolName = call?['name'] as String?;
        toolStatus = call?['status'] as String?;
      case 'ui_action':
        final action = json['action'] as Map<String, dynamic>?;
        actionType = action?['action_type'] as String?;
        if (action?['payload'] != null) {
          actionPayload = Map<String, dynamic>.from(action!['payload']);
        }
      case 'status_changed':
        status = json['status'] as String?;
      case 'turn_started':
        status = 'started';
      case 'turn_completed':
        if (json['usage'] is Map<String, dynamic>) {
          usage = AgentUsageSummary.fromJson(
            json['usage'] as Map<String, dynamic>,
          );
        }
      case 'turn_failed':
        final error = json['error'] as Map<String, dynamic>?;
        errorCode = error?['code'] as String?;
        errorMessage = error?['message'] as String?;
      case 'turn_cancelled':
        cancelReason = json['reason'] as String?;
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

enum AgentTurnState {
  idle,
  connecting,
  routing,
  thinking,
  runningTool,
  answering,
  completed,
  failed,
  cancelled,
}

/// Tracks the lifecycle of one agent turn.
class AgentTurnTracker {
  AgentTurnState _state = AgentTurnState.idle;

  AgentTurnState get state => _state;

  bool get isActive =>
      _state != AgentTurnState.idle &&
      _state != AgentTurnState.completed &&
      _state != AgentTurnState.failed &&
      _state != AgentTurnState.cancelled;

  void start() {
    _state = AgentTurnState.connecting;
  }

  bool consumeEvent(AgentStreamEvent event) {
    switch (event.type) {
      case 'turn_started':
        return _transition(AgentTurnState.routing);
      case 'status_changed':
        return _applyStatus(event.status);
      case 'tool_started':
        return _transition(AgentTurnState.runningTool);
      case 'tool_finished':
        return _transition(AgentTurnState.thinking);
      case 'text_delta':
        if (_state != AgentTurnState.answering) {
          return _transition(AgentTurnState.answering);
        }
        return false;
      case 'turn_completed':
        return _transition(AgentTurnState.completed);
      case 'turn_failed':
        return _transition(AgentTurnState.failed);
      case 'turn_cancelled':
        return _transition(AgentTurnState.cancelled);
      default:
        return false;
    }
  }

  void onStreamClosed() {
    if (isActive) _transition(AgentTurnState.failed);
  }

  void onCancelled() {
    if (isActive) _transition(AgentTurnState.cancelled);
  }

  void reset() {
    _state = AgentTurnState.idle;
  }

  bool _applyStatus(String? status) {
    switch (status) {
      case 'thinking':
        return _transition(AgentTurnState.thinking);
      case 'running_tool':
        return _transition(AgentTurnState.runningTool);
      case 'answering':
        return _transition(AgentTurnState.answering);
      default:
        return false;
    }
  }

  bool _transition(AgentTurnState next) {
    if (next == _state) return false;
    _state = next;
    return true;
  }
}
