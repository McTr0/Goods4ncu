import 'voice_provider.dart';

/// Non-web platforms fall back to "no voice" until a native TTS provider is
/// added (graceful degradation level 2, goal §74).
VoiceProvider createVoiceProvider() => UnsupportedVoiceProvider();
