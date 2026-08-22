import 'dart:async';

/// Every observable occurrence inside the companion runtime.
///
/// The bus is the single nervous system: producers emit, the debug console,
/// character director, and timeline recorder all subscribe. Nothing polls.
enum CompanionEventType {
  sessionStarted,
  userSpeechStart,
  userSpeechEnd,
  agentThinking,
  agentResponseStart,
  agentResponseEnd,
  ttsStart,
  ttsEnd,
  interrupted,
  toolStarted,
  toolFinished,
  environmentChanged,
  attentionChanged,
  emotionChanged,
  relationshipChanged,
  characterStateChanged,
  motionStarted,
  motionFinished,
}

class CompanionEvent {
  const CompanionEvent({
    required this.type,
    required this.timestamp,
    this.data = const {},
  });

  final CompanionEventType type;
  final DateTime timestamp;

  /// Small structured payload (tool name, latency ms, from/to states, …).
  /// Never contains message bodies or private content.
  final Map<String, Object?> data;

  @override
  String toString() => 'CompanionEvent(${type.name}, $data)';
}

/// Typed publish/subscribe hub for companion runtime events (goal §67).
class CompanionEventBus {
  final StreamController<CompanionEvent> _controller =
      StreamController.broadcast();

  Stream<CompanionEvent> get stream => _controller.stream;

  bool _closed = false;

  void emit(CompanionEventType type, [Map<String, Object?> data = const {}]) {
    if (_closed) return;
    _controller.add(
      CompanionEvent(type: type, timestamp: DateTime.now(), data: data),
    );
  }

  StreamSubscription<CompanionEvent> on(
    CompanionEventType type,
    void Function(CompanionEvent event) handler,
  ) {
    return stream
        .where((event) => event.type == type)
        .listen((event) => handler(event));
  }

  Future<void> dispose() {
    _closed = true;
    return _controller.close();
  }
}

/// Rolling in-memory event history backing the timeline debugger (§69).
class CompanionTimeline {
  CompanionTimeline({this.capacity = 500});

  final int capacity;
  final List<CompanionEvent> _events = [];

  void attachTo(CompanionEventBus bus) {
    bus.stream.listen(_events.add);
  }

  List<CompanionEvent> get events => List.unmodifiable(_events);

  void clear() => _events.clear();
}
