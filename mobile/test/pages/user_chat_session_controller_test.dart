import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/pages/user_chat_media_sender.dart';
import 'package:goods4ncu_mobile/pages/user_chat_session_controller.dart';
import 'package:goods4ncu_mobile/services/ws_service.dart';

class _FakeAudioRecorder implements UserChatAudioRecorder {
  _FakeAudioRecorder({this.hasRecorderPermission = true, this.stopResult});

  final bool hasRecorderPermission;
  String? stopResult;
  String? startedPath;
  bool disposed = false;

  @override
  Future<bool> hasPermission() async => hasRecorderPermission;

  @override
  Future<void> start(String path) async {
    startedPath = path;
  }

  @override
  Future<String?> stop() async => stopResult ?? startedPath;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeNotificationSource implements UserChatNotificationSource {
  final StreamController<WsNotification> controller =
      StreamController<WsNotification>.broadcast();

  @override
  Stream<WsNotification> get stream => controller.stream;
}

class _FakeMediaSender extends UserChatMediaSender {
  _FakeMediaSender({this.shouldThrow = false});

  final bool shouldThrow;
  List<int>? audioBytes;

  @override
  Future<void> sendAudioBytes(
    List<int> audioBytes, {
    required UserChatSendMessage sendMessage,
  }) async {
    if (shouldThrow) {
      throw UserChatMediaSendException('语音上传失败，请重试');
    }
    this.audioBytes = audioBytes;
    await sendMessage(
      content: '[语音消息]',
      audioUrl: 'https://cdn.example.com/audio.ogg',
    );
  }
}

Future<String> _createTempDirectoryPath() async {
  final dir = await Directory.systemTemp.createTemp('user_chat_session');
  return dir.path;
}

void main() {
  test(
    'toggleRecording does nothing when recorder permission is denied',
    () async {
      final recorder = _FakeAudioRecorder(hasRecorderPermission: false);
      final controller = UserChatSessionController(
        audioRecorder: recorder,
        mediaSender: _FakeMediaSender(),
        tempDirectoryPath: _createTempDirectoryPath,
      );

      await controller.toggleRecording(
        canSendMedia: () => true,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {},
        onError: (_) {},
      );

      expect(controller.isRecording, isFalse);
      expect(recorder.startedPath, isNull);

      controller.dispose();
    },
  );

  test(
    'toggleRecording starts and stops recording with forwarded audio send',
    () async {
      final recorder = _FakeAudioRecorder();
      final mediaSender = _FakeMediaSender();
      final controller = UserChatSessionController(
        audioRecorder: recorder,
        mediaSender: mediaSender,
        tempDirectoryPath: _createTempDirectoryPath,
      );

      String? sentContent;
      String? sentAudioBase64;
      String? sentAudioUrl;

      await controller.toggleRecording(
        canSendMedia: () => true,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {
              sentContent = content;
              sentAudioBase64 = audioBase64;
              sentAudioUrl = audioUrl;
            },
        onError: (_) {},
      );

      expect(controller.isRecording, isTrue);
      expect(controller.recordingSeconds, 0);
      expect(recorder.startedPath, isNotNull);

      final file = File(recorder.startedPath!);
      await file.writeAsBytes(<int>[1, 2, 3]);

      await controller.toggleRecording(
        canSendMedia: () => true,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {
              sentContent = content;
              sentAudioBase64 = audioBase64;
              sentAudioUrl = audioUrl;
            },
        onError: (_) {},
      );

      expect(controller.isRecording, isFalse);
      expect(mediaSender.audioBytes, <int>[1, 2, 3]);
      expect(sentContent, '[语音消息]');
      expect(sentAudioBase64, isNull);
      expect(sentAudioUrl, 'https://cdn.example.com/audio.ogg');

      controller.dispose();
    },
  );

  test(
    'toggleRecording surfaces media sender errors when upload fails',
    () async {
      final recorder = _FakeAudioRecorder(stopResult: null);
      final mediaSender = _FakeMediaSender(shouldThrow: true);
      final controller = UserChatSessionController(
        audioRecorder: recorder,
        mediaSender: mediaSender,
        tempDirectoryPath: _createTempDirectoryPath,
      );

      String? errorMessage;

      await controller.toggleRecording(
        canSendMedia: () => true,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {},
        onError: (message) => errorMessage = message,
      );

      final file = File(recorder.startedPath!);
      await file.writeAsBytes(<int>[7, 8, 9]);
      recorder.stopResult = recorder.startedPath;

      await controller.toggleRecording(
        canSendMedia: () => true,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {},
        onError: (message) => errorMessage = message,
      );

      expect(errorMessage, '语音上传失败，请重试');

      controller.dispose();
    },
  );

  test('toggleRecording surfaces disconnected state when stopping', () async {
    final recorder = _FakeAudioRecorder();
    final mediaSender = _FakeMediaSender();
    final controller = UserChatSessionController(
      audioRecorder: recorder,
      mediaSender: mediaSender,
      tempDirectoryPath: _createTempDirectoryPath,
    );

    String? errorMessage;

    await controller.toggleRecording(
      canSendMedia: () => true,
      sendMessage:
          ({
            required String content,
            String? imageBase64,
            String? audioBase64,
            String? imageUrl,
            String? audioUrl,
          }) async {},
      onError: (message) => errorMessage = message,
    );

    final file = File(recorder.startedPath!);
    await file.writeAsBytes(<int>[4, 5, 6]);

    await controller.toggleRecording(
      canSendMedia: () => false,
      sendMessage:
          ({
            required String content,
            String? imageBase64,
            String? audioBase64,
            String? imageUrl,
            String? audioUrl,
          }) async {},
      onError: (message) => errorMessage = message,
    );

    expect(mediaSender.audioBytes, isNull);
    expect(errorMessage, '等待连接建立后再发送消息');

    controller.dispose();
  });

  test('connectWs forwards notifications from the source stream', () async {
    final notificationSource = _FakeNotificationSource();
    final controller = UserChatSessionController(
      notificationSource: notificationSource,
      audioRecorder: _FakeAudioRecorder(),
      mediaSender: _FakeMediaSender(),
      tempDirectoryPath: _createTempDirectoryPath,
    );

    WsNotification? received;
    controller.connectWs((notification) {
      received = notification;
    });

    final notification = WsNotification(
      eventType: 'typing',
      title: 'typing',
      body: '',
      conversationId: 'conv-1',
      typingUserId: 'user-2',
    );
    notificationSource.controller.add(notification);
    await Future<void>.delayed(Duration.zero);

    expect(received?.eventType, 'typing');
    expect(received?.conversationId, 'conv-1');

    controller.dispose();
    await notificationSource.controller.close();
  });
}
