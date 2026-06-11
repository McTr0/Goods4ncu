import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../services/api_service.dart';
import '../services/sse_service.dart';
import '../services/upload_service.dart';
import '../services/ws_service.dart';
import '../models/models.dart';
import '../components/audio_message_player.dart';
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
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'approve',
      );
      widget.onUpdated();
    } catch (e) {
      _showError('操作失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'reject',
      );
      widget.onUpdated();
    } catch (e) {
      _showError('操作失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _counter() async {
    final price = double.tryParse(_counterController.text.trim());
    if (price == null || price <= 0) {
      _showError('请输入有效的还价金额');
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
      _showError('操作失败: $e');
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
            Text('报价: ¥${widget.request.proposedPrice.toStringAsFixed(2)}'),
            if (widget.request.reason.isNotEmpty)
              Text('理由: ${widget.request.reason}'),
            if (widget.request.expiresAt != null)
              Text(
                '有效期至: ${_formatExpiry(widget.request.expiresAt!)}',
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
                      label: const Text('接受'),
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
                      label: const Text('拒绝'),
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
                      decoration: const InputDecoration(
                        hintText: '还价金额',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
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
                    child: const Text('还价'),
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
    setState(() => _isLoading = true);
    try {
      await widget.apiService.acceptCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError('操作失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    setState(() => _isLoading = true);
    try {
      await widget.apiService.rejectCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError('操作失败: $e');
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
                  '卖家还价 ¥${widget.request.counterPrice?.toStringAsFixed(2) ?? '?'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '您 original offer: ¥${widget.request.proposedPrice.toStringAsFixed(2)}',
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
                      label: const Text('接受还价'),
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
                      label: const Text('拒绝'),
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
  final SseService? sseService;
  final UploadService? uploadService;
  final ChatPageMediaSender? mediaSender;

  const ChatPage({
    super.key,
    this.apiService,
    this.sseService,
    this.uploadService,
    this.mediaSender,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  late final ApiService _apiService;
  late final SseService _sseService;
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
  String? _currentUserId;

  // Active HITL requests shown as cards in the chat.
  List<HitlRequest> _hitlRequests = [];

  StreamSubscription? _wsSubscription;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _sseService = widget.sseService ?? context.read<SseService>();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
    _mediaSender =
        widget.mediaSender ??
        ChatPageMediaSender(uploadService: _uploadService);
    _loadCurrentUser();
    _connectWs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    });
  }

  Future<void> _loadCurrentUser() async {
    try {
      final profile = await _apiService.getUserProfile();
      setState(() {
        _currentUserId = profile['user_id']?.toString();
      });
      await _loadNegotiations();
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
            ? SnackBarAction(label: '查看', onPressed: _loadNegotiations)
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
    _sseService.dispose();
    _wsSubscription?.cancel();
    _recordingTimer?.cancel();
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
      bool connected;
      try {
        await _sseService
            .connect(
              message: userMsg.content,
              imageUrl: uploadedMedia.imageUrl,
              audioUrl: uploadedMedia.audioUrl,
            )
            .timeout(const Duration(seconds: 30));
        connected = true;
      } catch (_) {
        connected = false;
      }
      if (!connected && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('连接失败，请检查网络'),
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
              content: fullReply.isEmpty ? '（无回复）' : fullReply,
              isPartial: false,
            );
          }
        });
      }

      // Refresh negotiations after chat (the agent may have created a HITL request).
      await _loadNegotiations();
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
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length + (_isStreaming ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _messages.length && _isStreaming) {
                return const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2),
                        SizedBox(width: 8),
                        Text(
                          'AI 正在输入...',
                          style: TextStyle(color: Colors.grey),
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
                  '录音中 ${_recordingSeconds}s / 60s',
                  style: TextStyle(
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
            Text('商品: ${req.listingId}'),
            Text('买家报价: ¥${req.proposedPrice.toStringAsFixed(2)}'),
            Text('理由: ${req.reason}'),
            Text('状态: ${req.status}'),
            if (req.counterPrice != null)
              Text('还价: ¥${req.counterPrice!.toStringAsFixed(2)}'),
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
              const Text('加载中...'),
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
      label = '议价已${request.status}';
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
