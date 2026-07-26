import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:goods4ncu_mobile/pages/user_chat_media_sender.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';

class _FakeUploadService extends UploadService {
  _FakeUploadService({
    this.imageUrl = 'https://cdn.example.com/image.jpg',
    this.audioUrl = 'https://cdn.example.com/audio.ogg',
    this.failImageUpload = false,
    this.failAudioUpload = false,
  });

  final String imageUrl;
  final String audioUrl;
  final bool failImageUpload;
  final bool failAudioUpload;

  List<int>? uploadedImageBytes;
  String? uploadedImageExtension;
  String? uploadedImageContentType;
  List<int>? uploadedAudioBytes;

  @override
  Future<String> uploadImageBytes(
    List<int> imageBytes, {
    String extension = 'jpg',
    String contentType = 'image/jpeg',
  }) async {
    if (failImageUpload) {
      throw Exception('image upload failed');
    }
    uploadedImageBytes = imageBytes;
    uploadedImageExtension = extension;
    uploadedImageContentType = contentType;
    return imageUrl;
  }

  @override
  Future<String> uploadAudioBytes(List<int> audioBytes) async {
    if (failAudioUpload) {
      throw Exception('audio upload failed');
    }
    uploadedAudioBytes = audioBytes;
    return audioUrl;
  }
}

Future<XFile> _createTempXFile(String filename, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('user_chat_media_sender');
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes);
  return XFile(file.path);
}

void main() {
  test('sendPickedImage uploads image and forwards URL-only payload', () async {
    final uploadService = _FakeUploadService(
      imageUrl: 'https://cdn.example.com/custom-image.jpg',
    );
    final mediaSender = UserChatMediaSender(uploadService: uploadService);
    final picked = await _createTempXFile('photo.png', <int>[1, 2, 3, 4]);

    String? sentContent;
    String? sentImageBase64;
    String? sentImageUrl;

    await mediaSender.sendPickedImage(
      picked,
      sendMessage:
          ({
            required String content,
            String? imageBase64,
            String? audioBase64,
            String? imageUrl,
            String? audioUrl,
          }) async {
            assert(audioBase64 == null);
            assert(audioUrl == null);
            sentContent = content;
            sentImageBase64 = imageBase64;
            sentImageUrl = imageUrl;
          },
    );

    expect(uploadService.uploadedImageBytes, <int>[1, 2, 3, 4]);
    expect(uploadService.uploadedImageExtension, 'png');
    expect(uploadService.uploadedImageContentType, 'image/png');
    expect(sentContent, '[图片消息]');
    expect(sentImageBase64, isNull);
    expect(sentImageUrl, 'https://cdn.example.com/custom-image.jpg');
  });

  test(
    'sendAudioBytes uploads audio and forwards URL-only voice payload',
    () async {
      final uploadService = _FakeUploadService(
        audioUrl: 'https://cdn.example.com/custom-audio.ogg',
      );
      final mediaSender = UserChatMediaSender(uploadService: uploadService);

      String? sentContent;
      String? sentAudioBase64;
      String? sentAudioUrl;

      await mediaSender.sendAudioBytes(
        <int>[9, 8, 7],
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) async {
              assert(imageBase64 == null);
              assert(imageUrl == null);
              sentContent = content;
              sentAudioBase64 = audioBase64;
              sentAudioUrl = audioUrl;
            },
      );

      expect(uploadService.uploadedAudioBytes, <int>[9, 8, 7]);
      expect(sentContent, '[语音消息]');
      expect(sentAudioBase64, isNull);
      expect(sentAudioUrl, 'https://cdn.example.com/custom-audio.ogg');
    },
  );

  test(
    'sendPickedImage surfaces upload failures with user facing message',
    () async {
      final mediaSender = UserChatMediaSender(
        uploadService: _FakeUploadService(failImageUpload: true),
      );
      final picked = await _createTempXFile('photo.jpg', <int>[4, 5, 6]);

      expect(
        () => mediaSender.sendPickedImage(
          picked,
          sendMessage:
              ({
                required String content,
                String? imageBase64,
                String? audioBase64,
                String? imageUrl,
                String? audioUrl,
              }) async {},
        ),
        throwsA(
          isA<UserChatMediaSendException>().having(
            (e) => e.message,
            'message',
            '图片上传失败，请重试',
          ),
        ),
      );
    },
  );

  test(
    'sendAudioBytes surfaces upload failures with user facing message',
    () async {
      final mediaSender = UserChatMediaSender(
        uploadService: _FakeUploadService(failAudioUpload: true),
      );

      expect(
        () => mediaSender.sendAudioBytes(
          <int>[7, 7, 7],
          sendMessage:
              ({
                required String content,
                String? imageBase64,
                String? audioBase64,
                String? imageUrl,
                String? audioUrl,
              }) async {},
        ),
        throwsA(
          isA<UserChatMediaSendException>().having(
            (e) => e.message,
            'message',
            '语音上传失败，请重试',
          ),
        ),
      );
    },
  );
}
