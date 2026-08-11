import 'dart:convert';

import 'package:flutter/material.dart';

import '../components/audio_message_player.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';

Future<void> showUserChatConnectionRequestDialog({
  required BuildContext context,
  required WsNotification notification,
  required ValueChanged<String> onAccept,
  required ValueChanged<String> onReject,
}) {
  final connectionId = notification.connectionId;
  if (connectionId == null) {
    return Future.value();
  }

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final l = AppLocalizations.of(ctx)!;
      return AlertDialog(
        title: Text(l.connectionRequestTitle),
        content: Text(
          l.connectionRequestReadReceiptNotice(
            notification.title,
            notification.body,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onReject(connectionId);
            },
            child: Text(l.rejectAction),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              onAccept(connectionId);
            },
            child: Text(l.acceptAction),
          ),
        ],
      );
    },
  );
}

class ConnectionIndicator extends StatefulWidget {
  final String? status;
  final bool isWsConnected;

  const ConnectionIndicator({
    super.key,
    this.status,
    this.isWsConnected = false,
  });

  @override
  State<ConnectionIndicator> createState() => ConnectionIndicatorState();
}

class ConnectionIndicatorState extends State<ConnectionIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    Color color;
    String label;
    Widget dot;

    if (!widget.isWsConnected) {
      color = Colors.grey;
      label = l.offlineStatus;
      dot = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    } else {
      switch (widget.status) {
        case 'connected':
          color = AppTheme.success;
          label = l.onlineStatus;
          dot = Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          );
          break;
        case 'pending':
          color = AppTheme.warning;
          label = l.pendingAcceptStatus;
          dot = Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          );
          break;
        case 'connecting':
          color = AppTheme.warning;
          label = l.connectingStatus;
          dot = AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.5 + 0.5 * _controller.value),
                shape: BoxShape.circle,
              ),
            ),
          );
          break;
        default:
          color = Colors.grey;
          label = l.offlineStatus;
          dot = Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          );
          break;
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

class MessageBubble extends StatelessWidget {
  final ConversationMessage message;
  final bool isMe;
  final bool isConnected;
  final VoidCallback? onEdit;
  final VoidCallback? onReply;
  final ValueChanged<String>? onReact;
  final ValueChanged<MessageAcknowledgementKind>? onAcknowledge;
  final VoidCallback? onWithdrawAcknowledgement;
  final VoidCallback? onHide;
  final VoidCallback? onReport;
  final bool deliveryOnly;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isConnected,
    this.onEdit,
    this.onReply,
    this.onReact,
    this.onAcknowledge,
    this.onWithdrawAcknowledgement,
    this.onHide,
    this.onReport,
    this.deliveryOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageActions(context),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isMe ? AppTheme.primary : Colors.grey[200],
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: isMe
                  ? const Radius.circular(0)
                  : const Radius.circular(16),
              bottomLeft: !isMe
                  ? const Radius.circular(0)
                  : const Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((message.imageUrl != null && message.imageUrl!.isNotEmpty) ||
                  (message.imageBase64 != null &&
                      message.imageBase64!.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child:
                        message.imageUrl != null && message.imageUrl!.isNotEmpty
                        ? Image.network(
                            message.imageUrl!,
                            width: 200,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              if (message.imageBase64 != null &&
                                  message.imageBase64!.isNotEmpty) {
                                return Image.memory(
                                  base64Decode(message.imageBase64!),
                                  width: 200,
                                  fit: BoxFit.cover,
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          )
                        : Image.memory(
                            base64Decode(message.imageBase64!),
                            width: 200,
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
              if ((message.audioUrl != null && message.audioUrl!.isNotEmpty) ||
                  (message.audioBase64 != null &&
                      message.audioBase64!.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AudioMessagePlayer(
                    audioUrl: message.audioUrl,
                    audioBase64: message.audioBase64,
                    isMe: isMe,
                  ),
                ),
              if (message.replyPreview != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (isMe ? Colors.white : AppTheme.primary).withValues(
                      alpha: 0.14,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border(
                      left: BorderSide(
                        color: isMe ? Colors.white70 : AppTheme.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    message.replyPreview!.content.isEmpty
                        ? l.replyPreviewGeneric
                        : message.replyPreview!.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isMe ? Colors.white70 : Colors.black54,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (message.quote != null)
                _StructuredQuoteCard(quote: message.quote!, isMe: isMe),
              Text(
                message.content,
                style: TextStyle(
                  color: isMe ? Colors.white : Colors.black87,
                  fontSize: 16,
                ),
              ),
              if (message.editedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l.editedSuffix,
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe ? Colors.white60 : Colors.black38,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              if (message.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: message.reactions.map((reaction) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: reaction.reactedByMe
                              ? Colors.white.withValues(alpha: 0.28)
                              : Colors.black.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${reaction.emoji} ${reaction.count}',
                          style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontSize: 12,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              if (message.acknowledgements.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: message.acknowledgements.map((acknowledgement) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: (isMe ? Colors.white : Colors.black)
                              .withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _acknowledgementLabel(context, acknowledgement.kind),
                          style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontSize: 12,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(message.sentAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe ? Colors.white70 : Colors.black45,
                    ),
                  ),
                  if (isMe && onEdit != null) ...[
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: onEdit,
                      child: Text(
                        l.editAction,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white60,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    _buildStatus(context),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessageActions(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final actionsAvailable =
        onReply != null ||
        onReact != null ||
        onAcknowledge != null ||
        onWithdrawAcknowledgement != null ||
        onEdit != null ||
        onHide != null ||
        onReport != null;
    if (!actionsAvailable) return;
    if (onEdit != null &&
        onReply == null &&
        onReact == null &&
        onHide == null &&
        onReport == null) {
      onEdit?.call();
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: Text(l.replyAction),
                onTap: () {
                  Navigator.pop(context);
                  onReply?.call();
                },
              ),
            if (onReact != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: ['👍', '❤️', '😂', '😮', '😢', '🙏'].map((emoji) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(emoji),
                        onPressed: () {
                          Navigator.pop(context);
                          onReact?.call(emoji);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            if (onAcknowledge != null) ...[
              ListTile(
                leading: const Icon(Icons.check_circle_outline_rounded),
                title: Text(l.acknowledgementReceived),
                onTap: () {
                  Navigator.pop(context);
                  onAcknowledge?.call(MessageAcknowledgementKind.received);
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: Text(l.acknowledgementWillReview),
                onTap: () {
                  Navigator.pop(context);
                  onAcknowledge?.call(MessageAcknowledgementKind.willReview);
                },
              ),
              ListTile(
                leading: const Icon(Icons.task_alt_rounded),
                title: Text(l.acknowledgementCompleted),
                onTap: () {
                  Navigator.pop(context);
                  onAcknowledge?.call(MessageAcknowledgementKind.completed);
                },
              ),
            ],
            if (onWithdrawAcknowledgement != null)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: Text(l.acknowledgementWithdraw),
                onTap: () {
                  Navigator.pop(context);
                  onWithdrawAcknowledgement?.call();
                },
              ),
            if (onEdit != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.editAction),
                onTap: () {
                  Navigator.pop(context);
                  onEdit?.call();
                },
              ),
            if (onHide != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l.hideMessageAction),
                subtitle: Text(l.hideMessageActionSubtitle),
                onTap: () {
                  Navigator.pop(context);
                  onHide?.call();
                },
              ),
            if (onReport != null)
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text(l.reportAction),
                onTap: () {
                  Navigator.pop(context);
                  onReport?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final status = switch (message.status) {
      'delivered' || 'read' => 'sent',
      final value => value,
    };
    if (deliveryOnly && status != 'sending' && status != 'failed') {
      return _DeliveryTicks(
        status: 'sent',
        color: isMe ? Colors.white70 : Colors.black45,
      );
    }
    switch (status) {
      case 'sending':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(
                strokeWidth: 1,
                color: Colors.white54,
              ),
            ),
            SizedBox(width: 2),
          ],
        );
      case 'sent':
        return _DeliveryTicks(
          status: 'sent',
          color: isMe ? Colors.white70 : Colors.black45,
        );
      case 'failed':
        return Tooltip(
          message: AppLocalizations.of(context)!.sendFailedShort,
          child: const Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: Colors.red,
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  String _acknowledgementLabel(
    BuildContext context,
    MessageAcknowledgementKind kind,
  ) {
    final l = AppLocalizations.of(context)!;
    return switch (kind) {
      MessageAcknowledgementKind.received => l.acknowledgementReceived,
      MessageAcknowledgementKind.willReview => l.acknowledgementWillReview,
      MessageAcknowledgementKind.completed => l.acknowledgementCompleted,
    };
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _DeliveryTicks extends StatelessWidget {
  const _DeliveryTicks({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final (icon, label) = switch (status) {
      'sent' => (Icons.done_rounded, l.messageSentStatus),
      _ => (Icons.done_rounded, l.messageSentStatus),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }
}

class UserChatTypingBanner extends StatelessWidget {
  final String username;

  const UserChatTypingBanner({super.key, required this.username});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Colors.grey[100],
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            AppLocalizations.of(context)!.typingIndicator(username),
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StructuredQuoteCard extends StatelessWidget {
  const _StructuredQuoteCard({required this.quote, required this.isMe});

  final MessageStructuredQuote quote;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final price = quote.primaryPrice;
    final status = quote.status;
    final l = AppLocalizations.of(context)!;
    final label = switch (quote.kind) {
      'listing' => l.quoteListing,
      'order' => l.quoteOrder,
      'hitl_offer' => l.quoteHitlOffer,
      _ => l.quoteGeneric,
    };
    final foreground = isMe ? Colors.white : AppTheme.textPrimary;
    final secondary = isMe ? Colors.white70 : AppTheme.textSecondary;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (isMe ? Colors.white : AppTheme.accent).withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (isMe ? Colors.white : AppTheme.accent).withValues(
            alpha: 0.24,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: secondary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            quote.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: foreground, fontWeight: FontWeight.w800),
          ),
          if (price != null || status != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (price != null) '¥${price.toStringAsFixed(2)}',
                if (status != null && status.isNotEmpty) status,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: secondary),
            ),
          ],
        ],
      ),
    );
  }
}

class UserChatMessageList extends StatelessWidget {
  final bool isLoading;
  final String? error;
  final List<ConversationMessage> messages;
  final String? currentUserId;
  final String? connectionStatus;
  final ScrollController scrollController;
  final VoidCallback onRetry;
  final ValueChanged<ConversationMessage> onEditMessage;
  final ValueChanged<ConversationMessage>? onReplyMessage;
  final void Function(ConversationMessage message, String emoji)?
  onReactMessage;
  final void Function(
    ConversationMessage message,
    MessageAcknowledgementKind kind,
  )?
  onAcknowledgeMessage;
  final ValueChanged<ConversationMessage>? onWithdrawAcknowledgement;
  final ValueChanged<ConversationMessage>? onHideMessage;
  final ValueChanged<ConversationMessage>? onReportMessage;
  final bool allowEditing;
  final bool deliveryOnly;

  const UserChatMessageList({
    super.key,
    required this.isLoading,
    required this.error,
    required this.messages,
    required this.currentUserId,
    required this.connectionStatus,
    required this.scrollController,
    required this.onRetry,
    required this.onEditMessage,
    this.onReplyMessage,
    this.onReactMessage,
    this.onAcknowledgeMessage,
    this.onWithdrawAcknowledgement,
    this.onHideMessage,
    this.onReportMessage,
    this.allowEditing = true,
    this.deliveryOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (isLoading && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(l.loadFailedWithError(error!)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: Text(l.retry)),
          ],
        ),
      );
    }
    if (messages.isEmpty) {
      return Center(
        child: Text(
          l.noMessagesYet,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final isMe = msg.isFrom(currentUserId ?? '');
        return MessageBubble(
          message: msg,
          isMe: isMe,
          isConnected: connectionStatus == 'connected',
          deliveryOnly: deliveryOnly,
          onReply: onReplyMessage == null ? null : () => onReplyMessage!(msg),
          onReact: msg.canReact && onReactMessage != null
              ? (emoji) => onReactMessage!(msg, emoji)
              : null,
          onAcknowledge: !isMe && onAcknowledgeMessage != null
              ? (kind) => onAcknowledgeMessage!(msg, kind)
              : null,
          onWithdrawAcknowledgement:
              !isMe &&
                  onWithdrawAcknowledgement != null &&
                  msg.acknowledgements.any(
                    (acknowledgement) =>
                        acknowledgement.userId == (currentUserId ?? ''),
                  )
              ? () => onWithdrawAcknowledgement!(msg)
              : null,
          onHide: msg.canHide && onHideMessage != null
              ? () => onHideMessage!(msg)
              : null,
          onReport: msg.canReport && onReportMessage != null
              ? () => onReportMessage!(msg)
              : null,
          onEdit: isMe && allowEditing && msg.canEdit && msg.kind == 'message'
              ? () => onEditMessage(msg)
              : null,
        );
      },
    );
  }
}

class UserChatInputArea extends StatelessWidget {
  final String? connectionStatus;
  final bool isRecording;
  final int recordingSeconds;
  final bool isSending;
  final bool isEditing;
  final ConversationMessage? replyingToMessage;
  final String? structuredQuoteLabel;
  final TextEditingController textController;
  final VoidCallback onPickImage;
  final VoidCallback onToggleRecording;
  final VoidCallback? onPickQuote;
  final VoidCallback? onCancelQuote;
  final VoidCallback onCancelEdit;
  final VoidCallback? onCancelReply;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final String unavailableMessage;

  const UserChatInputArea({
    super.key,
    required this.connectionStatus,
    required this.isRecording,
    required this.recordingSeconds,
    required this.isSending,
    required this.isEditing,
    this.replyingToMessage,
    this.structuredQuoteLabel,
    required this.textController,
    required this.onPickImage,
    required this.onToggleRecording,
    this.onPickQuote,
    this.onCancelQuote,
    required this.onCancelEdit,
    this.onCancelReply,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSend,
    this.unavailableMessage = '',
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (connectionStatus != 'connected') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          border: Border(top: BorderSide(color: Colors.orange.shade200)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.hourglass_empty,
              color: Colors.orange.shade700,
              size: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                unavailableMessage.isEmpty
                    ? l.conversationWaitingPeer
                    : unavailableMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.orange.shade700),
              ),
            ),
          ],
        ),
      );
    }

    if (isRecording) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          border: Border(top: BorderSide(color: Colors.red.shade200)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.circle, color: Colors.red, size: 12),
            const SizedBox(width: 8),
            Text(
              l.recordingStatus(recordingSeconds),
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TextButton(onPressed: onToggleRecording, child: Text(l.stopAction)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingToMessage != null)
              Container(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.reply_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        replyingToMessage!.content.isEmpty
                            ? l.replyMediaMessage
                            : replyingToMessage!.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l.cancelReply,
                      onPressed: onCancelReply,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            if (structuredQuoteLabel != null)
              Container(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.format_quote_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        structuredQuoteLabel!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l.cancelQuote,
                      onPressed: onCancelQuote,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image),
                  onPressed: isSending ? null : onPickImage,
                ),
                IconButton(
                  tooltip: l.quoteContextTooltip,
                  icon: const Icon(Icons.format_quote_rounded),
                  onPressed: isSending ? null : onPickQuote,
                ),
                IconButton(
                  icon: Icon(
                    isRecording ? Icons.stop : Icons.mic,
                    color: isRecording ? Colors.red : null,
                  ),
                  onPressed: onToggleRecording,
                ),
                if (isEditing)
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: onCancelEdit,
                  ),
                Expanded(
                  child: TextField(
                    controller: textController,
                    decoration: InputDecoration(
                      hintText: isEditing
                          ? l.editMessageHint
                          : l.messageInputHint,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                    isEditing ? Icons.check : Icons.send,
                    color: isEditing ? Colors.green : AppTheme.primary,
                  ),
                  onPressed: onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
