import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/api_service.dart';
import '../services/chat_service.dart';
import '../services/sse_service.dart';
import '../services/upload_service.dart';
import '../services/ws_service.dart';
import '../models/models.dart';
import '../components/assistant_markdown.dart';
import '../components/live2d/live2d_character_widget.dart';
import '../components/live2d/live2d_controller.dart';
import '../components/live2d/live2d_lipsync_driver.dart';
import '../components/unified_message_composer.dart';
import '../components/xiaochang_avatar.dart';
import 'chat_page_media_sender.dart';

/// Negotiation action card shown in the chat for HITL requests.
class NegotiationCard extends StatelessWidget {
  final HitlRequest request;
  final String currentUserId;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const NegotiationCard({
    super.key,
    required this.request,
    required this.currentUserId,
    required this.apiService,
    required this.onUpdated,
  });

  bool get isSeller => request.sellerId == currentUserId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final isPending = request.status == 'pending';
    final isCountered = request.status == 'countered';

    if (isPending && isSeller) {
      return _SellerPendingCard(
        request: request,
        apiService: apiService,
        onUpdated: onUpdated,
      );
    }
    if (isCountered && !isSeller) {
      return _BuyerCounteredCard(
        request: request,
        apiService: apiService,
        onUpdated: onUpdated,
      );
    }
    if (request.isExpired) {
      return _StatusBadge(
        icon: Icons.timer_off,
        label: l.negotiationExpired,
        color: Colors.grey,
      );
    }
    if (request.status == 'approved') {
      return _StatusBadge(
        icon: Icons.check_circle,
        label: l.sellerAcceptedDealComplete,
        color: Colors.green,
      );
    }
    if (request.status == 'rejected' || request.status == 'buyer_rejected') {
      return _StatusBadge(
        icon: Icons.cancel,
        label: l.negotiationRejected,
        color: Colors.red,
      );
    }
    return const SizedBox.shrink();
  }
}

class _SellerPendingCard extends StatefulWidget {
  final HitlRequest request;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const _SellerPendingCard({
    required this.request,
    required this.apiService,
    required this.onUpdated,
  });

  @override
  State<_SellerPendingCard> createState() => _SellerPendingCardState();
}

class _SellerPendingCardState extends State<_SellerPendingCard> {
  bool _isLoading = false;
  final _counterController = TextEditingController();

  @override
  void dispose() {
    _counterController.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'approve',
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'reject',
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _counter() async {
    final l = AppLocalizations.of(context)!;
    final price = double.tryParse(_counterController.text.trim());
    if (price == null || price <= 0) {
      _showError(l.enterValidCounterAmount);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'counter',
        counterPrice: price,
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.handshake, color: Color(0xFF6366F1), size: 20),
                const SizedBox(width: 8),
                Text(
                  l.buyerInitiatedNegotiation,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.offerPriceLine(widget.request.proposedPrice.toStringAsFixed(2)),
            ),
            if (widget.request.reason.isNotEmpty)
              Text(l.reasonLine(widget.request.reason)),
            if (widget.request.expiresAt != null)
              Text(
                l.expiresAtLine(_formatExpiry(widget.request.expiresAt!)),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _approve,
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(l.acceptAction),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reject,
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(l.rejectAction),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _counterController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}'),
                        ),
                      ],
                      decoration: InputDecoration(
                        hintText: l.counterOfferAmount,
                        isDense: true,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _counter,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l.counterOfferAction),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatExpiry(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

class _BuyerCounteredCard extends StatefulWidget {
  final HitlRequest request;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const _BuyerCounteredCard({
    required this.request,
    required this.apiService,
    required this.onUpdated,
  });

  @override
  State<_BuyerCounteredCard> createState() => _BuyerCounteredCardState();
}

class _BuyerCounteredCardState extends State<_BuyerCounteredCard> {
  bool _isLoading = false;

  Future<void> _accept() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.acceptCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.rejectCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.countertops, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text(
                  l.sellerCounterPriceLine(
                    widget.request.counterPrice?.toStringAsFixed(2) ?? '?',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.yourOriginalOfferLine(
                widget.request.proposedPrice.toStringAsFixed(2),
              ),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _accept,
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(l.acceptCounterAction),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reject,
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(l.rejectAction),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final ApiService? apiService;
  final ChatService? chatService;
  final SseService? sseService;
  final UploadService? uploadService;
  final ChatPageMediaSender? mediaSender;
  final String? initialPrompt;
  final bool embedded;
  final VoidCallback? onConversationUpdated;

  const ChatPage({
    super.key,
    this.apiService,
    this.chatService,
    this.sseService,
    this.uploadService,
    this.mediaSender,
    this.initialPrompt,
    this.embedded = false,
    this.onConversationUpdated,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _uuid = Uuid();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final List<ChatMessage> _messages = [];
  late final ApiService _apiService;
  late final ChatService _chatService;
  late final SseService _sseService;
  late final bool _ownsSseService;
  late final UploadService _uploadService;
  late final ChatPageMediaSender _mediaSender;
  final ImagePicker _picker = ImagePicker();

  XFile? _selectedImage;
  Uint8List? _selectedImageBytes;
  bool _isStreaming = false;
  bool _isLoadingHistory = true;
  String? _historyError;
  String? _currentUserId;

  // Active HITL requests shown as cards in the chat.
  List<HitlRequest> _hitlRequests = [];
  List<AgentPlan> _agentPlans = [];
  // Actions the assistant already performed that are still reversible. Kept
  // separate from _agentPlans: those await the user, these have happened.
  List<UndoableAction> _undoableActions = [];
  Timer? _undoTicker;

  StreamSubscription? _wsSubscription;

  late final Live2DController _live2DController;
  late final Live2DLipSyncDriver _lipSyncDriver;

  @override
  void initState() {
    super.initState();
    _live2DController = Live2DController();
    _lipSyncDriver = Live2DLipSyncDriver(controller: _live2DController);
    _apiService = widget.apiService ?? context.read<ApiService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _ownsSseService = widget.sseService == null;
    _sseService = widget.sseService ?? SseService();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
    _mediaSender =
        widget.mediaSender ??
        ChatPageMediaSender(uploadService: _uploadService);
    _connectWs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    await Future.wait([_loadCurrentUser(), _loadAssistantHistory()]);
    if (!mounted) return;
    if (_messages.isEmpty) {
      final l = AppLocalizations.of(context)!;
      _live2DController.showSpeechBubble(l.aiGreeting);
      setState(() {
        _messages.add(
          ChatMessage(
            sender: 'bot',
            content: l.aiGreeting,
            timestamp: DateTime.now(),
          ),
        );
      });
    } else {
      final lastBot = _messages.reversed.firstWhere(
        (m) => m.sender == 'bot',
        orElse: () => _messages.last,
      );
      _live2DController.showSpeechBubble(lastBot.content);
    }
    final initialPrompt = widget.initialPrompt?.trim();
    if (initialPrompt != null && initialPrompt.isNotEmpty) {
      _controller.text = initialPrompt;
      await _sendMessage();
    }
  }

  Future<void> _loadAssistantHistory() async {
    try {
      final history = await _chatService.getAssistantHistory();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history.messages);
        _isLoadingHistory = false;
        _historyError = null;
      });
      if (_messages.isNotEmpty) {
        final lastBot = _messages.reversed.firstWhere(
          (m) => m.sender == 'bot',
          orElse: () => _messages.last,
        );
        _live2DController.showSpeechBubble(lastBot.content);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingHistory = false;
        _historyError = error.toString();
      });
    }
  }

  Future<void> _loadCurrentUser() async {
    try {
      final profile = await _apiService.getUserProfile();
      if (!mounted) return;
      setState(() {
        _currentUserId = profile['user_id']?.toString();
      });
      await _loadNegotiations();
      await _loadAgentPlans();
      await _loadUndoableActions();
    } catch (_) {}
  }

  Future<void> _loadNegotiations() async {
    try {
      final requests = await _apiService.getNegotiations();
      if (!mounted) return;
      setState(() {
        _hitlRequests = requests
            .where((r) => r.isPending || r.isCountered || r.isExpired)
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _loadAgentPlans() async {
    try {
      final plans = await _apiService.getAgentPlans();
      if (!mounted) return;
      setState(() => _agentPlans = plans);
    } catch (_) {}
  }

  Future<void> _loadUndoableActions() async {
    try {
      final actions = await _apiService.getUndoableActions();
      if (!mounted) return;
      setState(() {
        _undoableActions = actions.where((a) => !a.expired).toList();
      });
      _syncUndoTicker();
    } catch (_) {}
  }

  /// Drives the countdown, and only while something is actually undoable — a
  /// permanent one-second timer would repaint the whole chat forever.
  void _syncUndoTicker() {
    if (_undoableActions.isEmpty) {
      _undoTicker?.cancel();
      _undoTicker = null;
      return;
    }
    _undoTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final live = _undoableActions.where((a) => !a.expired).toList();
      setState(() => _undoableActions = live);
      if (live.isEmpty) _syncUndoTicker();
    });
  }

  Future<void> _undo(UndoableAction action) async {
    final l = AppLocalizations.of(context)!;
    // Drop it from the strip immediately: leaving a button the user already
    // pressed invites a second press, and the answer will be the same anyway.
    setState(
      () => _undoableActions = _undoableActions
          .where((a) => a.id != action.id)
          .toList(),
    );
    try {
      final result = await _apiService.undoAction(action.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isEmpty
                ? (result.undone ? l.undoSucceeded : l.undoConflict)
                : result.message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.undoFailed)));
    }
    await _loadUndoableActions();
  }

  Future<void> _confirmAgentPlan(AgentPlan plan) async {
    final l = AppLocalizations.of(context)!;
    try {
      // An armed plan has already consumed its primary token. This can happen
      // after a reload, a lost first response, or when the user dismissed the
      // second-confirmation dialog earlier. Never send its execution token
      // until the user has explicitly accepted the high-risk dialog.
      String token = plan.confirmationToken;
      if (plan.isHighRisk && plan.isArmed) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l.agentPlanSecondConfirmTitle),
            content: Text(plan.summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l.agentPlanSecondConfirmAction),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          await _loadAgentPlans();
          return;
        }
      }

      var outcome = await _apiService.confirmAgentPlan(plan.id, token);
      if (!mounted) return;
      if (outcome.needsSecondConfirmation) {
        // The primary token can only arm an L3 plan. Execution requires the
        // freshly rotated token returned by that transition; reusing the
        // primary token must remain a transport-idempotent no-op.
        final secondToken = outcome.confirmationToken;
        if (secondToken == null || secondToken.isEmpty) {
          await _loadAgentPlans();
          throw StateError('Second confirmation token was not returned');
        }

        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l.agentPlanSecondConfirmTitle),
            content: Text(plan.summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l.agentPlanSecondConfirmAction),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          await _loadAgentPlans();
          return;
        }
        token = secondToken;
        outcome = await _apiService.confirmAgentPlan(plan.id, token);
        if (!mounted) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.result.isEmpty ? l.agentPlanExecuted : outcome.result,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    }
    await _loadAgentPlans();
  }

  Future<void> _cancelAgentPlan(AgentPlan plan) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _apiService.cancelAgentPlan(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.agentPlanCancelled)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    }
    await _loadAgentPlans();
  }

  void _connectWs() {
    _wsSubscription = WsService.instance.stream.listen((notification) {
      _handleWsNotification(notification);
    });
  }

  void _handleWsNotification(WsNotification notif) {
    if (!mounted) return;
    // Show a snackbar for real-time negotiation updates.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${notif.title}: ${notif.body}'),
        duration: const Duration(seconds: 4),
        action: notif.negotiationId != null
            ? SnackBarAction(
                label: AppLocalizations.of(context)!.viewAction,
                onPressed: _loadNegotiations,
              )
            : null,
      ),
    );
    // Refresh negotiation list if relevant.
    if (notif.eventType.startsWith('negotiation')) {
      _loadNegotiations();
    }
  }

  @override
  void dispose() {
    _lipSyncDriver.dispose();
    _live2DController.dispose();
    _controller.dispose();
    _composerFocusNode.dispose();
    if (_ownsSseService) _sseService.dispose();
    _wsSubscription?.cancel();
    _undoTicker?.cancel();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 1024,
    );
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _selectedImage = image;
        _selectedImageBytes = bytes;
      });
    }
  }

  /// Send a message using SSE streaming (token-by-token render).
  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    final selectedImage = _selectedImage;
    final selectedImageBytes = _selectedImageBytes;
    if (text.isEmpty && selectedImageBytes == null) {
      return;
    }

    setState(() {
      _isStreaming = true;
    });

    try {
      final uploadedMedia = await _mediaSender.uploadSelectedMedia(
        pickedImage: selectedImage,
        imageBytes: selectedImageBytes,
      );

      final userMsg = ChatMessage(
        sender: 'user',
        content: text.isEmpty ? '[Multimedia Message]' : text,
        imageUrl: uploadedMedia.imageUrl,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(userMsg);
        _controller.clear();
        _selectedImage = null;
        _selectedImageBytes = null;
      });

      // Append a placeholder streaming message.
      final botMsgIndex = _messages.length;
      _messages.add(
        ChatMessage(
          sender: 'bot',
          content: '',
          timestamp: DateTime.now(),
          isPartial: true,
        ),
      );

      // Connect SSE stream with timeout.
      final proposalIdempotencyKey = _uuid.v4();
      bool connected;
      try {
        await _sseService
            .connect(
              message: userMsg.content,
              conversationId: '__agent__',
              imageUrl: uploadedMedia.imageUrl,
              idempotencyKey: proposalIdempotencyKey,
            )
            .timeout(const Duration(seconds: 30));
        connected = true;
      } catch (_) {
        connected = false;
      }
      if (!connected && mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.connectionFailedNetwork),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isStreaming = false;
          if (botMsgIndex < _messages.length) {
            _messages.removeAt(botMsgIndex);
          }
        });
        return;
      }

      _live2DController.setExpression(Live2DExpression.thinking);
      _live2DController.showSpeechBubble('小昌在思考中，正在检索校园记忆...');
      String fullReply = '';
      await for (final token in _sseService.stream) {
        if (!mounted) break;
        if (token.error != null) {
          throw Exception(token.error);
        }
        _lipSyncDriver.feedStreamingChunk(token.token);
        _live2DController.setExpression(Live2DExpression.happy);
        fullReply += token.token;
        _live2DController.showSpeechBubble(fullReply);
        setState(() {
          if (botMsgIndex < _messages.length) {
            _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
              content: fullReply,
              isPartial: true,
            );
          }
        });
      }
      _lipSyncDriver.onStreamComplete();
      _live2DController.setExpression(Live2DExpression.idle);
      _live2DController.showSpeechBubble(
        fullReply.isEmpty ? '小昌收到啦！随时为你服务~' : fullReply,
      );

      // Finalize the message (no longer partial).
      if (mounted && botMsgIndex < _messages.length) {
        setState(() {
          if (botMsgIndex < _messages.length) {
            _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
              content: fullReply.isEmpty
                  ? AppLocalizations.of(context)!.emptyReplyPlaceholder
                  : fullReply,
              isPartial: false,
            );
          }
        });
      }

      // Refresh negotiations and pending plans after chat (the agent may have
      // created a HITL request or proposed an action awaiting confirmation).
      await _loadNegotiations();
      await _loadAgentPlans();
      // The turn may have carried out a reversible write, so surface the undo
      // affordance right after the reply that caused it.
      await _loadUndoableActions();
      widget.onConversationUpdated?.call();
    } on ChatPageMediaUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
      setState(() {
        _isStreaming = false;
        _selectedImage = selectedImage;
        _selectedImageBytes = selectedImageBytes;
      });
      return;
    } catch (e) {
      final botMsgIndex = _messages.isEmpty ? -1 : _messages.length - 1;
      if (mounted && botMsgIndex >= 0 && botMsgIndex < _messages.length) {
        final l = AppLocalizations.of(context)!;
        setState(() {
          _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
            content: '${l.aiError}: $e',
            isPartial: false,
          );
        });
      }
    } finally {
      await _sseService.disconnect();
      if (mounted) {
        setState(() => _isStreaming = false);
      }
    }
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '📜 历史对话与智能记忆',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F766E),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _isLoadingHistory
                      ? const Center(child: CircularProgressIndicator())
                      : _messages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无历史对话',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            return _ChatBubble(
                              message: msg,
                              isUser: msg.sender == 'user',
                              hitlRequests: _hitlRequests,
                              currentUserId: _currentUserId ?? '',
                              apiService: _apiService,
                              onHitlUpdated: _loadNegotiations,
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildQuickSuggestionChips() {
    final chips = [
      '🚲 校园二手车',
      '📚 考研二手教材',
      '🎒 闲置数码与iPad',
      '📦 查我的校园订单',
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: chips.map((prompt) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(
              label: Text(
                prompt,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F766E),
                ),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.9),
              side: BorderSide(
                color: const Color(0xFF0F766E).withValues(alpha: 0.25),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              onPressed: () {
                _controller.text = prompt.replaceAll(RegExp(r'^[^\s]+\s*'), '');
                _sendMessage();
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        _AssistantDigitalHumanHeader(
          onOpenHistory: _showHistorySheet,
        ),
        if (_historyError != null)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3CD),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l.assistantHistoryLoadFailed,
              style: const TextStyle(fontSize: 12, color: Color(0xFF765A16)),
            ),
          ),
        // Pending agent action plans
        if (_agentPlans.isNotEmpty)
          Container(
            color: const Color(0xFFF1F5FF),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.agentPlanPendingHeader,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3F51B5),
                  ),
                ),
                ..._agentPlans.map(
                  (plan) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          plan.isHighRisk
                              ? Icons.warning_amber_rounded
                              : Icons.pending_actions,
                          size: 18,
                          color: plan.isHighRisk
                              ? const Color(0xFFB45309)
                              : const Color(0xFF3F51B5),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            plan.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _cancelAgentPlan(plan),
                          child: Text(l.cancel),
                        ),
                        FilledButton(
                          onPressed: () => _confirmAgentPlan(plan),
                          child: Text(l.agentPlanConfirmAction),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Reversible writes undo strip
        if (_undoableActions.isNotEmpty)
          Container(
            color: const Color(0xFFF4F6F4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.undoDoneHeader,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5F6B5F),
                  ),
                ),
                ..._undoableActions.map((action) {
                  final remaining = action.remaining();
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          size: 16,
                          color: Color(0xFF5F6B5F),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            action.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (remaining != null)
                          Text(
                            l.undoRemainingSeconds(remaining.inSeconds),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF8A968A),
                            ),
                          ),
                        TextButton(
                          onPressed: () => _undo(action),
                          child: Text(l.undoAction),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        // Negotiation cards strip
        if (_hitlRequests.isNotEmpty)
          SizedBox(
            height: 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: _hitlRequests.length,
              itemBuilder: (context, index) {
                final req = _hitlRequests[index];
                return SizedBox(
                  width: 200,
                  child: _HitlChip(
                    request: req,
                    onTap: () => _showNegotiationCard(req),
                  ),
                );
              },
            ),
          ),
        // Main Digital Human Virtual Avatar Stage
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.1),
                radius: 0.85,
                colors: [
                  Color(0xFFE1F4EF),
                  Color(0xFFFFFBF5),
                ],
              ),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),
                  // Live2D Character with dynamic speech bubble & tap physics
                  Live2DCharacterWidget(
                    controller: _live2DController,
                    size: 260,
                    showSpeechBubble: true,
                    enableTouchTracking: true,
                  ),
                  const SizedBox(height: 18),
                  // Quick suggestion chips
                  _buildQuickSuggestionChips(),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
        // Bottom Input Message Composer
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F766E).withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: UnifiedMessageComposer(
            controller: _controller,
            focusNode: _composerFocusNode,
            hintText: '和小昌说说话，找好物、问跑腿...',
            isSending: _isStreaming,
            onSubmitted: (_) => _sendMessage(),
            onSend: _sendMessage,
            primaryActions: [
              MessageComposerAction(
                id: 'image',
                icon: Icons.image_outlined,
                label: l.composerImageAction,
                onPressed: _pickImage,
              ),
            ],
            expandedActions: [
              MessageComposerAction(
                id: 'assistant-find',
                icon: Icons.search_rounded,
                label: l.assistantToolFind,
                onPressed: () => _applyAssistantPrompt(l.assistantToolFindPrompt),
              ),
              MessageComposerAction(
                id: 'assistant-estimate',
                icon: Icons.price_check_outlined,
                label: l.assistantToolEstimate,
                onPressed: () =>
                    _applyAssistantPrompt(l.assistantToolEstimatePrompt),
              ),
            ],
            contextContent: [
              if (_selectedImageBytes != null) _buildSelectedImagePreview(l),
            ],
          ),
        ),
      ],
    );
  }

  void _applyAssistantPrompt(String prompt) {
    _controller.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _composerFocusNode.requestFocus();
  }

  Widget _buildSelectedImagePreview(AppLocalizations l) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 84,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_selectedImageBytes!),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  setState(() {
                    _selectedImage = null;
                    _selectedImageBytes = null;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNegotiationCard(HitlRequest req) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: NegotiationCard(
            request: req,
            currentUserId: _currentUserId ?? '',
            apiService: _apiService,
            onUpdated: _loadNegotiations,
          ),
        ),
      ),
    );
  }
}

class _AssistantDigitalHumanHeader extends StatelessWidget {
  const _AssistantDigitalHumanHeader({required this.onOpenHistory});

  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const XiaochangAvatar(size: 36),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '小昌 · 智能数字人',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '实时语音动作 · 记忆增强 · 校园生活助理',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: '历史对话',
            icon: const Icon(Icons.history_rounded, color: Color(0xFF0F766E)),
            onPressed: onOpenHistory,
          ),
          const SizedBox(width: 4),
          const _AgentStatusPill(),
        ],
      ),
    );
  }
}

class _HitlChip extends StatelessWidget {
  final HitlRequest request;
  final VoidCallback onTap;

  const _HitlChip({required this.request, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    Color tagColor;
    String label;
    if (request.isPending) {
      tagColor = Colors.orange;
      label = l.pendingNegotiation;
    } else if (request.isCountered) {
      tagColor = Colors.blue;
      label = l.sellerCounterOffered;
    } else {
      tagColor = Colors.grey;
      label = l.negotiationStatusLine(request.status);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tagColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tagColor.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: tagColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            Text(
              '¥${request.proposedPrice.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentStatusPill extends StatelessWidget {
  const _AgentStatusPill();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE1F4EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l.assistantSystemBadge,
        style: const TextStyle(
          color: Color(0xFF0F766E),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isUser;
  final List<HitlRequest> hitlRequests;
  final String currentUserId;
  final ApiService apiService;
  final VoidCallback onHitlUpdated;

  const _ChatBubble({
    required this.message,
    required this.isUser,
    required this.hitlRequests,
    required this.currentUserId,
    required this.apiService,
    required this.onHitlUpdated,
  });

  @override
  Widget build(BuildContext context) {
    // Show negotiation cards after bot messages.
    Widget? trailingCard;
    if (!isUser && message.content.isNotEmpty && !message.isPartial) {
      // Detect if this message contains a HITL request and show a card.
      // The backend injects system messages with negotiation context.
      if (message.content.contains('议价')) {
        final relatedReqs = hitlRequests
            .where((r) => r.isPending && r.sellerId == currentUserId)
            .toList();
        if (relatedReqs.isNotEmpty) {
          trailingCard = NegotiationCard(
            request: relatedReqs.first,
            currentUserId: currentUserId,
            apiService: apiService,
            onUpdated: onHitlUpdated,
          );
        }
      }
    }

    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser ? const Color(0xFF6366F1) : Colors.grey[200],
              borderRadius: BorderRadius.circular(16).copyWith(
                bottomRight: isUser
                    ? const Radius.circular(0)
                    : const Radius.circular(16),
                bottomLeft: !isUser
                    ? const Radius.circular(0)
                    : const Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((message.imageUrl != null &&
                        message.imageUrl!.isNotEmpty) ||
                    (message.imageBase64 != null &&
                        message.imageBase64!.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child:
                          message.imageUrl != null &&
                              message.imageUrl!.isNotEmpty
                          ? Image.network(
                              message.imageUrl!,
                              errorBuilder: (context, error, stackTrace) {
                                if (message.imageBase64 != null &&
                                    message.imageBase64!.isNotEmpty) {
                                  return Image.memory(
                                    base64Decode(message.imageBase64!),
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            )
                          : Image.memory(base64Decode(message.imageBase64!)),
                    ),
                  ),
                if (!isUser && !message.isPartial)
                  AssistantMarkdown(data: message.content)
                else
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isUser ? Colors.white : Colors.black87,
                      fontSize: 16,
                    ),
                    softWrap: true,
                  ),
                if (message.isPartial)
                  const Text(
                    '▊',
                    style: TextStyle(color: Colors.grey),
                  ), // Typing cursor
              ],
            ),
          ),
        ),
        ?trailingCard,
      ],
    );
  }
}
