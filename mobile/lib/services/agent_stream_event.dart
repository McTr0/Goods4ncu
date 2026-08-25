/// Structured agent event from the v2 protocol.
class AgentStreamEvent {
  AgentStreamEvent._({
    required this.type,
    required this.seq,
    this.text,
    this.toolName,
    this.toolStatus,
    this.actionType,
    this.actionPayload,
    this.status,
    this.errorCode,
    this.errorMessage,
    this.cancelReason,
  });

  factory AgentStreamEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    final seq = (json['seq'] as num?)?.toInt() ?? 0;
    String? text;
    String? toolName;
    String? toolStatus;
    String? actionType;
    Map<String, dynamic>? actionPayload;
    String? status;
    String? errorCode;
    String? errorMessage;
    String? cancelReason;

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
      case 'turn_failed':
        final error = json['error'] as Map<String, dynamic>?;
        errorCode = error?['code'] as String?;
        errorMessage = error?['message'] as String?;
      case 'turn_cancelled':
        cancelReason = json['reason'] as String?;
    }

    return AgentStreamEvent._(
      type: type,
      seq: seq,
      text: text,
      toolName: toolName,
      toolStatus: toolStatus,
      actionType: actionType,
      actionPayload: actionPayload,
      status: status,
      errorCode: errorCode,
      errorMessage: errorMessage,
      cancelReason: cancelReason,
    );
  }

  /// Parse a legacy v1 SSE chunk into a compatible event (or null).
  static AgentStreamEvent? fromLegacyChunk(Map<String, dynamic> chunk) {
    if (chunk.containsKey('token')) {
      return AgentStreamEvent._(
        type: 'text_delta',
        seq: 0,
        text: chunk['token'] as String?,
      );
    }
    return null;
  }

  final String type;
  final int seq;
  final String? text;
  final String? toolName;
  final String? toolStatus;
  final String? actionType;
  final Map<String, dynamic>? actionPayload;
  final String? status;
  final String? errorCode;
  final String? errorMessage;
  final String? cancelReason;

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

  void onLegacyToken() {
    if (isActive && _state != AgentTurnState.answering) {
      _transition(AgentTurnState.answering);
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
