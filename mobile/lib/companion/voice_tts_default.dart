import 'voice_provider.dart';

/// Non-web platforms fall back to "no voice" (graceful degradation, §74).
VoiceProvider createVoiceProvider() => UnsupportedVoiceProvider();
