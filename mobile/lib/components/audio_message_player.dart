import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class AudioMessagePlayer extends StatefulWidget {
  const AudioMessagePlayer({super.key, this.audioUrl, required this.isMe});

  final String? audioUrl;
  final bool isMe;

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((value) {
      if (!mounted) return;
      setState(() => _duration = value);
    });
    _player.onPositionChanged.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
    });
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying = state == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }

    setState(() => _isLoading = true);
    try {
      Source? source;
      if (widget.audioUrl != null && widget.audioUrl!.isNotEmpty) {
        source = UrlSource(widget.audioUrl!);
      }

      if (source != null) {
        await _player.play(source);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isMe ? Colors.white : Colors.black87;
    final secondary = widget.isMe ? Colors.white70 : Colors.black54;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _isLoading ? null : _toggle,
          child: Icon(
            _isLoading
                ? Icons.hourglass_empty
                : (_isPlaying ? Icons.pause_circle : Icons.play_circle),
            size: 18,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _duration.inSeconds > 0
              ? '${_position.inSeconds}s / ${_duration.inSeconds}s'
              : '语音消息',
          style: TextStyle(fontSize: 12, color: secondary),
        ),
      ],
    );
  }
}
