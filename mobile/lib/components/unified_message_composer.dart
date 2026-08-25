import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/speech_dictation.dart';

/// A contextual action exposed by [UnifiedMessageComposer].
///
/// The composer owns layout and interaction state while each conversation
/// surface supplies only the actions that make sense in that context.
class MessageComposerAction {
  const MessageComposerAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// Shared message entry surface for assistant, direct, and group conversations.
class UnifiedMessageComposer extends StatefulWidget {
  const UnifiedMessageComposer({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onSend,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.primaryActions = const [],
    this.expandedActions = const [],
    this.contextContent = const [],
    this.statusContent,
    this.enabled = true,
    this.isSending = false,
    this.onStop,
    this.isEditing = false,
    this.enableDictation = true,
    this.dictation,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final VoidCallback onSend;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<MessageComposerAction> primaryActions;
  final List<MessageComposerAction> expandedActions;
  final List<Widget> contextContent;
  final Widget? statusContent;
  final bool enabled;
  final bool isSending;
  final VoidCallback? onStop;
  final bool isEditing;
  final bool enableDictation;
  final SpeechDictation? dictation;

  @override
  State<UnifiedMessageComposer> createState() => _UnifiedMessageComposerState();
}

class _UnifiedMessageComposerState extends State<UnifiedMessageComposer> {
  bool _toolsExpanded = false;
  late final SpeechDictation _dictation;
  late final bool _ownsDictation;
  bool _isDictating = false;
  String? _dictationError;
  String _dictationPrefix = '';
  String _finalTranscript = '';

  @override
  void initState() {
    super.initState();
    _ownsDictation = widget.dictation == null;
    _dictation = widget.dictation ?? createSpeechDictation();
  }

  @override
  void didUpdateWidget(covariant UnifiedMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expandedActions.isEmpty && _toolsExpanded) {
      _toolsExpanded = false;
    }
  }

  @override
  void dispose() {
    if (_ownsDictation) _dictation.dispose();
    super.dispose();
  }

  Future<void> _toggleDictation() async {
    if (_isDictating) {
      await _dictation.stop();
      return;
    }
    if (!_dictation.isSupported) {
      setState(() => _dictationError = 'unsupported');
      return;
    }

    _dictationPrefix = widget.controller.text.trimRight();
    _finalTranscript = '';
    setState(() {
      _dictationError = null;
      _isDictating = true;
    });
    await _dictation.start(
      locale: Localizations.localeOf(context).toLanguageTag(),
      onResult: _applyDictationResult,
      onError: (code) {
        if (!mounted) return;
        setState(() {
          _dictationError = code;
          _isDictating = false;
        });
      },
      onEnded: () {
        if (!mounted) return;
        setState(() => _isDictating = false);
      },
    );
  }

  void _applyDictationResult(SpeechDictationResult result) {
    if (!mounted) return;
    if (result.isFinal) _finalTranscript += result.text;
    final liveTranscript = result.isFinal
        ? _finalTranscript
        : '$_finalTranscript${result.text}';
    final separator = _needsJoinSpace(_dictationPrefix, liveTranscript)
        ? ' '
        : '';
    final text = '$_dictationPrefix$separator$liveTranscript';
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
    widget.onChanged?.call(text);
    setState(() => _dictationError = null);
  }

  bool _needsJoinSpace(String prefix, String transcript) {
    if (prefix.isEmpty || transcript.isEmpty) return false;
    if (RegExp(r'[\u3400-\u9fff]$').hasMatch(prefix)) return false;
    if (RegExp(r'^[\u3400-\u9fff\s，。！？、,.!?;；:：]').hasMatch(transcript)) {
      return false;
    }
    return true;
  }

  void _submit(String value) {
    if (!widget.enabled || widget.isSending) return;
    widget.onSubmitted?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final interactive = widget.enabled && !widget.isSending;
    final dictationMessage = switch (_dictationError) {
      'not-allowed' || 'service-not-allowed' => l.dictationPermissionDenied,
      'unsupported' => l.dictationUnsupported,
      'network' => l.dictationNetworkError,
      String() => l.dictationUnavailable,
      null => null,
    };

    return Container(
      key: const Key('unified-message-composer'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.statusContent != null) ...[
              widget.statusContent!,
              const SizedBox(height: 8),
            ],
            if (_isDictating || dictationMessage != null) ...[
              Row(
                children: [
                  Icon(
                    _isDictating
                        ? Icons.graphic_eq_rounded
                        : Icons.info_outline_rounded,
                    color: _isDictating ? scheme.primary : scheme.error,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isDictating ? l.dictationListening : dictationMessage!,
                      style: TextStyle(
                        color: _isDictating ? scheme.primary : scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_isDictating)
                    TextButton(
                      key: const Key('composer-dictation-stop'),
                      onPressed: _toggleDictation,
                      child: Text(l.stopAction),
                    )
                  else
                    IconButton(
                      tooltip: l.cancel,
                      onPressed: () => setState(() => _dictationError = null),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            for (final content in widget.contextContent) ...[
              content,
              const SizedBox(height: 8),
            ],
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: !_toolsExpanded
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: widget.expandedActions
                              .map(
                                (action) => ActionChip(
                                  key: Key('composer-tool-${action.id}'),
                                  avatar: Icon(action.icon, size: 18),
                                  label: Text(action.label),
                                  onPressed:
                                      !interactive || action.onPressed == null
                                      ? null
                                      : () {
                                          action.onPressed!();
                                          setState(
                                            () => _toolsExpanded = false,
                                          );
                                        },
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.expandedActions.isNotEmpty)
                  IconButton(
                    key: const Key('composer-tools-toggle'),
                    tooltip: _toolsExpanded
                        ? l.composerHideTools
                        : l.composerMoreTools,
                    onPressed: widget.enabled
                        ? () => setState(() => _toolsExpanded = !_toolsExpanded)
                        : null,
                    icon: AnimatedRotation(
                      turns: _toolsExpanded ? 0.125 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: const Icon(Icons.add_circle_outline_rounded),
                    ),
                  ),
                for (final action in widget.primaryActions)
                  IconButton(
                    key: Key('composer-action-${action.id}'),
                    tooltip: action.label,
                    onPressed: !interactive ? null : action.onPressed,
                    icon: Icon(action.icon),
                  ),
                Expanded(
                  child: TextField(
                    key: const Key('composer-text-field'),
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onChanged: widget.onChanged,
                    onSubmitted: _submit,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      filled: true,
                      fillColor: scheme.surfaceContainerLowest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                if (widget.enableDictation)
                  IconButton(
                    key: const Key('composer-dictation'),
                    tooltip: _isDictating
                        ? l.dictationStopAction
                        : l.dictationStartAction,
                    onPressed: !interactive ? null : _toggleDictation,
                    icon: Icon(
                      _isDictating
                          ? Icons.stop_circle_rounded
                          : Icons.mic_none_rounded,
                      color: _isDictating ? scheme.error : null,
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: Key(
                    widget.isSending && widget.onStop != null
                        ? 'composer-stop'
                        : 'composer-send',
                  ),
                  tooltip: widget.isSending && widget.onStop != null
                      ? l.composerStopTooltip
                      : widget.isEditing
                      ? l.confirm
                      : l.composerSendTooltip,
                  onPressed: widget.isSending && widget.onStop != null
                      ? widget.onStop
                      : interactive
                      ? widget.onSend
                      : null,
                  icon: widget.isSending && widget.onStop != null
                      ? const Icon(Icons.stop_rounded)
                      : widget.isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          widget.isEditing
                              ? Icons.check_rounded
                              : Icons.send_rounded,
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
