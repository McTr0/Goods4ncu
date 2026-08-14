import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';
import '../services/api_service.dart';
import '../services/chat_service.dart';
import '../services/sse_service.dart';
import '../services/upload_service.dart';
import '../services/ws_service.dart';
import '../models/models.dart';
import '../components/audio_message_player.dart';
import '../components/assistant_markdown.dart';
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
  final VoidCallback? onExit;

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
    this.onExit,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _uuid = Uuid();
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  late final ApiService _apiService;
  late final ChatService _chatService;
  late final SseService _sseService;
  late final bool _ownsSseService;
  late final UploadService _uploadService;
  late final ChatPageMediaSender _mediaSender;
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();

  XFile? _selectedImage;
  Uint8List? _selectedImageBytes;
  List<int>? _selectedAudioBytes;
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
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

  @override
  void initState() {
    super.initState();
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
      setState(() {
        _messages.add(
          ChatMessage(
            sender: 'bot',
            content: l.aiGreeting,
            timestamp: DateTime.now(),
          ),
        );
      });
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
    _audioRecorder.dispose();
    _controller.dispose();
    if (_ownsSseService) _sseService.dispose();
    _wsSubscription?.cancel();
    _recordingTimer?.cancel();
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

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (path != null) {
        final bytes = await File(path).readAsBytes();
        setState(() {
          _isRecording = false;
          _selectedAudioBytes = bytes;
        });
        _sendMessage();
      } else {
        setState(() => _isRecording = false);
      }
    } else {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        final path =
            '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.ogg';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.opus),
          path: path,
        );
        setState(() {
          _isRecording = true;
          _recordingSeconds = 0;
        });
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (mounted) {
            setState(() => _recordingSeconds++);
            if (_recordingSeconds >= 60) {
              _toggleRecording(); // 自动停止
            }
          }
        });
      }
    }
  }

  /// Send a message using SSE streaming (token-by-token render).
  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    final selectedImage = _selectedImage;
    final selectedImageBytes = _selectedImageBytes;
    final selectedAudioBytes = _selectedAudioBytes;
    if (text.isEmpty &&
        selectedImageBytes == null &&
        selectedAudioBytes == null) {
      return;
    }

    setState(() {
      _isStreaming = true;
    });

    try {
      final uploadedMedia = await _mediaSender.uploadSelectedMedia(
        pickedImage: selectedImage,
        imageBytes: selectedImageBytes,
        audioBytes: selectedAudioBytes,
      );

      final userMsg = ChatMessage(
        sender: 'user',
        content: text.isEmpty ? '[Multimedia Message]' : text,
        imageUrl: uploadedMedia.imageUrl,
        audioUrl: uploadedMedia.audioUrl,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(userMsg);
        _controller.clear();
        _selectedImage = null;
        _selectedImageBytes = null;
        _selectedAudioBytes = null;
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
              audioUrl: uploadedMedia.audioUrl,
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

      String fullReply = '';
      await for (final token in _sseService.stream) {
        if (!mounted) break;
        if (token.error != null) {
          throw Exception(token.error);
        }
        fullReply += token.token;
        setState(() {
          if (botMsgIndex < _messages.length) {
            _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
              content: fullReply,
              isPartial: true,
            );
          }
        });
      }

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
        _selectedAudioBytes = selectedAudioBytes;
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        _AssistantHeader(embedded: widget.embedded, onExit: _exitAssistant),
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
        // Pending agent action plans: the model proposed these writes, and
        // nothing executes until the user confirms here.
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
        // Writes that already happened and are still reversible. Visually
        // quieter than the pending-confirmation block above: nothing is being
        // asked of the user, the action is simply still recoverable.
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
        // Negotiation cards strip at the top of chat
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
        if (_isLoadingHistory)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_isStreaming ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length && _isStreaming) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(strokeWidth: 2),
                          const SizedBox(width: 8),
                          Text(
                            l.assistantTyping,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final msg = _messages[index];
                final isUser = msg.sender == 'user';
                return _ChatBubble(
                  message: msg,
                  isUser: isUser,
                  hitlRequests: _hitlRequests,
                  currentUserId: _currentUserId ?? '',
                  apiService: _apiService,
                  onHitlUpdated: _loadNegotiations,
                );
              },
            ),
          ),
        if (_selectedImageBytes != null)
          Container(
            padding: const EdgeInsets.all(8),
            height: 100,
            child: Stack(
              children: [
                Image.memory(_selectedImageBytes!),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.red),
                    onPressed: () => setState(() {
                      _selectedImage = null;
                      _selectedImageBytes = null;
                    }),
                  ),
                ),
              ],
            ),
          ),
        if (_isRecording)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.circle, color: Colors.red, size: 12),
                const SizedBox(width: 8),
                Text(
                  l.recordingStatus(_recordingSeconds),
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                // Simple waveform animation
                Row(
                  children: List.generate(
                    5,
                    (i) => Container(
                      width: 3,
                      height: 8 + (i % 2 == 0 ? 4 : 0),
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: Colors.red.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.image), onPressed: _pickImage),
              IconButton(
                icon: Icon(
                  _isRecording ? Icons.stop : Icons.mic,
                  color: _isRecording ? Colors.red : null,
                ),
                onPressed: _toggleRecording,
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: l.typeMessage,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.send,
                  color: _isStreaming ? Colors.grey : const Color(0xFF6366F1),
                ),
                onPressed: _isStreaming ? null : _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _exitAssistant() {
    if (widget.onExit != null) {
      widget.onExit!();
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/conversations');
    }
  }

  void _showNegotiationCard(HitlRequest req) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(
              builder: (ctx) => Text(
                AppLocalizations.of(ctx)!.negotiationDetails,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 12),
            Text(AppLocalizations.of(context)!.listingLine(req.listingId)),
            Text(
              AppLocalizations.of(
                context,
              )!.buyerOfferLine(req.proposedPrice.toStringAsFixed(2)),
            ),
            Text(AppLocalizations.of(context)!.reasonLine(req.reason)),
            Text(AppLocalizations.of(context)!.statusLine(req.status)),
            if (req.counterPrice != null)
              Text(
                AppLocalizations.of(
                  context,
                )!.counterPriceLine(req.counterPrice!.toStringAsFixed(2)),
              ),
            const SizedBox(height: 16),
            if (_currentUserId != null)
              NegotiationCard(
                request: req,
                currentUserId: _currentUserId!,
                apiService: _apiService,
                onUpdated: () {
                  Navigator.pop(context);
                  _loadNegotiations();
                },
              )
            else
              Text(AppLocalizations.of(context)!.loading),
          ],
        ),
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

class _AssistantHeader extends StatelessWidget {
  const _AssistantHeader({required this.embedded, required this.onExit});

  final bool embedded;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(embedded ? 20 : 16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const XiaochangAvatar(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.assistantName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  l.assistantHeaderSubtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const _AgentStatusPill(),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: l.closeConversationAction,
            onPressed: onExit,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
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
                if ((message.audioUrl != null &&
                        message.audioUrl!.isNotEmpty) ||
                    (message.audioBase64 != null &&
                        message.audioBase64!.isNotEmpty))
                  AudioMessagePlayer(
                    audioUrl: message.audioUrl,
                    audioBase64: message.audioBase64,
                    isMe: isUser,
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
