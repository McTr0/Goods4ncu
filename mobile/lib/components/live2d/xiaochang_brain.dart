import 'dart:async';
import 'package:flutter/material.dart';

/// What 小昌 is currently paying attention to.
enum XiaochangAttention {
  user, // Looking at the user, waiting for input
  input, // Focused on the text field while user types
  thinking, // Processing a response
  speaking, // Delivering a response
  away, // User hasn't interacted for a while
}

/// The user's immediate task, inferred from the page and message.
enum XiaochangTask {
  conversation,
  findItem,
  inspectItem,
  negotiate,
  messageSeller,
  getHelp,
}

/// 小昌's emotional state, driven by context rather than random selection.
enum XiaochangMood {
  neutral, // Default calm state
  curious, // User is typing, interested in what they'll say
  happy, // Positive interaction completed
  concerned, // User seems frustrated or stuck
  sleepy, // User away for extended period
  playful, // User is interacting physically (taps, drags)
}

/// A single intentional movement with a reason.
class XiaochangIntent {
  XiaochangIntent({
    required this.action,
    required this.reason,
    this.duration = const Duration(milliseconds: 600),
  });

  final String action;
  final String reason;
  final Duration duration;
}

/// The character brain that decides what 小昌 should do based on context.
///
/// Every motion has a reason. 小昌 doesn't randomly wiggle — she reacts to
/// what the user is doing, remembers recent interactions, and expresses
/// appropriate emotions for the situation.
class XiaochangBrain extends ChangeNotifier {
  Timer? _attentionTimer;
  final List<Timer> _reactionTimers = [];

  XiaochangBrain() {
    _attentionTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _evaluateAttention(),
    );
  }

  // Current state
  XiaochangAttention _attention = XiaochangAttention.user;
  XiaochangMood _mood = XiaochangMood.neutral;

  // Interaction tracking
  DateTime _lastUserActivity = DateTime.now();
  bool _isUserTyping = false;
  bool _isStreamingResponse = false;
  String _page = 'chat';
  XiaochangTask _task = XiaochangTask.conversation;
  String _lastReason = 'Waiting for the user';

  // Intentional movement
  XiaochangIntent? _currentIntent;
  double _gazeTargetX = 0.0;
  double _gazeTargetY = 0.0;
  double _bodyLeanX = 0.0;

  // Getters
  XiaochangAttention get attention => _attention;
  XiaochangMood get mood => _mood;
  XiaochangIntent? get currentIntent => _currentIntent;
  double get gazeTargetX => _gazeTargetX;
  double get gazeTargetY => _gazeTargetY;
  double get bodyLeanX => _bodyLeanX;
  XiaochangTask get task => _task;
  String get page => _page;
  String get lastReason => _lastReason;
  bool get isThinking => _attention == XiaochangAttention.thinking;
  bool get isSpeaking => _attention == XiaochangAttention.speaking;

  /// Give the character the same spatial context the agent receives.
  void onPageChanged(String page, {String? listingId}) {
    _page = page;
    if (page == 'post_detail') {
      _setTask(XiaochangTask.inspectItem);
      _lastReason = 'The user is inspecting a specific item';
      _setIntent('look_at_results', _lastReason);
      _setGaze(0.45, -0.1);
      if (listingId == null) {
        _lastReason = 'The user is inspecting a specific discussion';
        _currentIntent = XiaochangIntent(
          action: 'focus_post',
          reason: _lastReason,
        );
      }
    } else {
      _setTask(XiaochangTask.conversation);
      _lastReason = 'Back at the assistant home';
      _setGaze(0, 0);
    }
  }

  /// Call when the user types in the chat input.
  void onUserTyping() {
    _isUserTyping = true;
    _lastUserActivity = DateTime.now();
    _setAttention(XiaochangAttention.input);
    _setMood(XiaochangMood.curious);
    _setIntent('lean_forward', 'User is typing — leaning in to see');
    _setGaze(0.0, -0.3); // Look down toward input area
  }

  /// Call when the user stops typing (debounced).
  void onUserTypingStopped() {
    _isUserTyping = false;
    if (_attention == XiaochangAttention.input) {
      _setAttention(XiaochangAttention.user);
      _setIntent('look_up', 'User stopped typing — looking back at them');
      _setGaze(0.0, 0.0);
    }
  }

  /// Call when the user sends a message.
  void onMessageSent(String message) {
    _lastUserActivity = DateTime.now();
    _inferTask(message);
    _setAttention(XiaochangAttention.thinking);
    if (_task == XiaochangTask.findItem) {
      _setMood(XiaochangMood.curious);
      _setIntent(
        'scan_inventory',
        'Searching campus listings before answering',
      );
      _setGaze(0.55, -0.05);
    } else if (_task == XiaochangTask.negotiate ||
        _messageMentionsSafety(message)) {
      _setMood(XiaochangMood.concerned);
      _setIntent('careful_review', 'This needs a careful, safe answer');
      _setGaze(-0.25, 0.15);
    } else {
      _setMood(XiaochangMood.neutral);
      _setIntent('think', 'Processing the request without jumping ahead');
      _setGaze(0.2, 0.12);
    }
  }

  /// Call when a response token arrives from the SSE stream.
  void onToolStarted(String tool) {
    _lastUserActivity = DateTime.now();
    _setAttention(XiaochangAttention.thinking);
    _setMood(XiaochangMood.curious);
    final intent = XiaochangIntent(
      action: 'tool_using_$tool',
      reason: 'Using $tool to retrieve real platform evidence',
      duration: const Duration(seconds: 3),
    );
    _currentIntent = intent;
    _delayed(intent.duration, () {
      if (_currentIntent?.action == intent.action) {
        _currentIntent = null;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// Call when a response token arrives from the SSE stream.
  void onResponseToken(String token) {
    if (!_isStreamingResponse) {
      _isStreamingResponse = true;
      _setAttention(XiaochangAttention.speaking);
      _setIntent('speak', 'Starting to respond');
      _setGaze(0.0, 0.0); // Look at user while speaking
    } else if (_attention == XiaochangAttention.thinking) {
      _setAttention(XiaochangAttention.speaking);
    }
    _lastUserActivity = DateTime.now();
  }

  /// Call when the full response is complete.
  void onResponseComplete({bool isError = false, String reply = ''}) {
    _isStreamingResponse = false;
    if (isError) {
      _setMood(XiaochangMood.concerned);
      _setIntent('apologize', 'Error occurred — expressing concern');
      _setGaze(0, 0.18);
    } else if (_task == XiaochangTask.findItem && reply.isNotEmpty) {
      _setMood(XiaochangMood.curious);
      _setIntent('present_results', 'Handing the shortlist over to the user');
      _setGaze(0.5, -0.08);
    } else if (_task == XiaochangTask.negotiate ||
        _messageMentionsSafety(reply)) {
      _setMood(XiaochangMood.concerned);
      _setIntent(
        'confirm_understanding',
        'Make sure the guidance landed safely',
      );
      _setGaze(0, 0);
    } else {
      _setMood(XiaochangMood.happy);
      _setIntent('nod', 'Response delivered — acknowledging completion');
      _setGaze(0, 0);
    }
    _delayed(const Duration(seconds: 3), () {
      if (_attention == XiaochangAttention.speaking) {
        _setAttention(XiaochangAttention.user);
        _setMood(XiaochangMood.neutral);
        _setIntent('idle_return', 'Conversation pause — returning to neutral');
        _setGaze(0.0, 0.0);
      }
    });
  }

  /// Results are real evidence: look toward them, then return to the user.
  void onSearchResultsShown({int count = 0, String? relatedToPostId}) {
    if (count <= 0) {
      _setMood(XiaochangMood.concerned);
      _setIntent('no_results', 'Nothing matched, so set expectations honestly');
      _setGaze(-0.15, 0.1);
      return;
    }
    _setTask(XiaochangTask.findItem);
    if (relatedToPostId != null) _setTask(XiaochangTask.inspectItem);
    _lastUserActivity = DateTime.now();
    _setMood(XiaochangMood.curious);
    _setIntent(
      'look_at_results',
      '$count result(s) appeared — checking them with the user',
    );
    _setGaze(0.6, -0.15);
    _delayed(const Duration(seconds: 4), () {
      if (!_isStreamingResponse) {
        _setIntent(
          'return_gaze',
          'Finished reviewing results — back to the user',
        );
        _setGaze(0, 0);
      }
    });
  }

  /// A specific post became the shared reference point.
  void onFocusPost(String postId) {
    _setTask(XiaochangTask.inspectItem);
    _lastUserActivity = DateTime.now();
    _setMood(XiaochangMood.curious);
    _setIntent('focus_post', 'Looking at the selected listing together');
    _setGaze(0.42, -0.08);
  }

  /// A human message has been drafted, but never sent automatically.
  void onDraftReady() {
    _setTask(XiaochangTask.messageSeller);
    _setMood(XiaochangMood.neutral);
    _setIntent('offer_draft', 'Waiting for explicit approval before sending');
    _setGaze(0, 0);
  }

  /// Reflect the outcome of the user's explicit send decision.
  void onDraftSendComplete({required bool succeeded}) {
    _setTask(succeeded ? XiaochangTask.messageSeller : XiaochangTask.getHelp);
    if (succeeded) {
      _setMood(XiaochangMood.happy);
      _setIntent('nod', 'The approved message was delivered');
    } else {
      _setMood(XiaochangMood.concerned);
      _setIntent('apologize', 'Delivery failed — help the user retry');
    }
    _setGaze(0, 0);
  }

  /// Call when the user physically interacts (tap, drag).
  void onPhysicalInteraction(String zone) {
    _lastUserActivity = DateTime.now();
    _setMood(XiaochangMood.playful);
    switch (zone) {
      case 'head':
        _setIntent('head_tilt', 'Head pat — tilting into the touch');
        _setGaze(-0.2, -0.1); // Slight lean into the pat
      case 'belly':
        _setIntent('giggle', 'Belly poke — playful reaction');
        _setGaze(0.1, 0.1);
      case 'drag':
        _setIntent('surprise', 'Being dragged — startled');
        _setGaze(0.0, -0.5);
    }
    _delayed(const Duration(milliseconds: 1500), () {
      if (_mood == XiaochangMood.playful) {
        _setMood(XiaochangMood.neutral);
        _setIntent('settle', 'Physical interaction done — settling');
      }
    });
  }

  /// Evaluate attention state based on elapsed time since last activity.
  void _evaluateAttention() {
    if (_isStreamingResponse) return;
    final elapsed = DateTime.now().difference(_lastUserActivity);

    if (elapsed.inSeconds > 30 && _attention != XiaochangAttention.away) {
      _setAttention(XiaochangAttention.away);
      _setMood(XiaochangMood.sleepy);
      _setIntent('drowse', 'User away — getting sleepy');
      _setGaze(0.0, 0.3); // Look down, drowsy
    } else if (elapsed.inSeconds <= 5 &&
        _attention == XiaochangAttention.away) {
      _setAttention(XiaochangAttention.user);
      _setMood(XiaochangMood.happy);
      _setIntent('wake_up', 'User returned — happy to see them');
      _setGaze(0.0, 0.0);
    } else if (!_isUserTyping && _attention == XiaochangAttention.input) {
      onUserTypingStopped();
    }
  }

  void _inferTask(String message) {
    final value = message.toLowerCase();
    if (_page == 'post_detail' &&
        RegExp(r'(聊|联系|私|发消息|message|contact|draft)').hasMatch(value)) {
      _setTask(XiaochangTask.messageSeller);
    } else if (RegExp(
      r'(找|买|搜|求|推荐|search|find|recommend|look for)',
    ).hasMatch(value)) {
      _setTask(XiaochangTask.findItem);
    } else if (RegExp(
      r'(价|便宜|砍|议|price|discount|negotiate|bargain)',
    ).hasMatch(value)) {
      _setTask(XiaochangTask.negotiate);
    } else if (RegExp(
      r'(骗|安全|投诉|举报|help|scam|safe|report|problem)',
    ).hasMatch(value)) {
      _setTask(XiaochangTask.getHelp);
    } else if (_page == 'post_detail') {
      _setTask(XiaochangTask.inspectItem);
    } else {
      _setTask(XiaochangTask.conversation);
    }
  }

  bool _messageMentionsSafety(String value) => RegExp(
    r'(骗|风险|安全|投诉|举报|scam|risk|safe|report)',
  ).hasMatch(value.toLowerCase());

  void _setTask(XiaochangTask value) {
    if (_task != value) {
      _task = value;
      notifyListeners();
    }
  }

  void _setAttention(XiaochangAttention a) {
    if (_attention != a) {
      _attention = a;
      notifyListeners();
    }
  }

  void _setMood(XiaochangMood m) {
    if (_mood != m) {
      _mood = m;
      notifyListeners();
    }
  }

  void _setIntent(String action, String reason) {
    _currentIntent = XiaochangIntent(action: action, reason: reason);
    _delayed(_currentIntent?.duration ?? const Duration(milliseconds: 600), () {
      if (_currentIntent?.action == action) {
        _currentIntent = null;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _delayed(Duration duration, VoidCallback callback) {
    late final Timer timer;
    timer = Timer(duration, () {
      _reactionTimers.remove(timer);
      callback();
    });
    _reactionTimers.add(timer);
  }

  void _setGaze(double x, double y) {
    _gazeTargetX = x.clamp(-1.0, 1.0);
    _gazeTargetY = y.clamp(-1.0, 1.0);
    _bodyLeanX = x * 0.3;
    notifyListeners();
  }

  @override
  void dispose() {
    _attentionTimer?.cancel();
    for (final timer in _reactionTimers) {
      timer.cancel();
    }
    _reactionTimers.clear();
    super.dispose();
  }
}
