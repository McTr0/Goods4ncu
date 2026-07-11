import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:good4ncu_mobile/pages/chat_page_media_sender.dart';
import 'package:good4ncu_mobile/services/upload_service.dart';
import 'package:image_picker/image_picker.dart';

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
  final dir = await Directory.systemTemp.createTemp('chat_page_media_sender');
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes);
  return XFile(file.path);
}

void main() {
  test(
    'uploadSelectedMedia uploads image and audio and returns URL payloads',
    () async {
      final uploadService = _FakeUploadService(
        imageUrl: 'https://cdn.example.com/chat-image.png',
        audioUrl: 'https://cdn.example.com/chat-audio.ogg',
      );
      final sender = ChatPageMediaSender(uploadService: uploadService);
      final picked = await _createTempXFile('draft.png', <int>[1, 2, 3]);

      final result = await sender.uploadSelectedMedia(
        pickedImage: picked,
        imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
        audioBytes: <int>[7, 8, 9],
      );

      expect(result.imageUrl, 'https://cdn.example.com/chat-image.png');
      expect(result.audioUrl, 'https://cdn.example.com/chat-audio.ogg');
      expect(uploadService.uploadedImageBytes, <int>[1, 2, 3]);
      expect(uploadService.uploadedImageExtension, 'png');
      expect(uploadService.uploadedImageContentType, 'image/png');
      expect(uploadService.uploadedAudioBytes, <int>[7, 8, 9]);
    },
  );

  test(
    'uploadPickedImage surfaces upload failures with retryable message',
    () async {
      final sender = ChatPageMediaSender(
        uploadService: _FakeUploadService(failImageUpload: true),
      );
      final picked = await _createTempXFile('draft.jpg', <int>[4, 5, 6]);

      expect(
        () => sender.uploadPickedImage(
          picked,
          imageBytes: Uint8List.fromList(<int>[4, 5, 6]),
        ),
        throwsA(
          isA<ChatPageMediaUploadException>().having(
            (e) => e.message,
            'message',
            '图片上传失败，请重试',
          ),
        ),
      );
    },
  );

  test(
    'uploadAudioBytes surfaces upload failures with retryable message',
    () async {
      final sender = ChatPageMediaSender(
        uploadService: _FakeUploadService(failAudioUpload: true),
      );

      expect(
        () => sender.uploadAudioBytes(<int>[9, 9, 9]),
        throwsA(
          isA<ChatPageMediaUploadException>().having(
            (e) => e.message,
            'message',
            '语音上传失败，请重试',
          ),
        ),
      );
    },
  );
}
