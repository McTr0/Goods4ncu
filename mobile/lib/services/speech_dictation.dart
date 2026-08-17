import 'speech_dictation_stub.dart'
    if (dart.library.io) 'speech_dictation_native.dart'
    if (dart.library.html) 'speech_dictation_web.dart'
    as platform;

export 'speech_dictation_contract.dart';

import 'speech_dictation_contract.dart';

SpeechDictation createSpeechDictation() => platform.createSpeechDictation();
