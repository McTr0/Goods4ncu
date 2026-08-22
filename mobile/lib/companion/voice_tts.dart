import 'voice_tts_default.dart'
    if (dart.library.js_interop) 'voice_tts_web.dart'
    as impl;

import 'voice_provider.dart';

/// Platform-selected TTS provider: Web Speech Synthesis on web,
/// unsupported no-op elsewhere until a native provider lands.
VoiceProvider createCompanionVoiceProvider() => impl.createVoiceProvider();
