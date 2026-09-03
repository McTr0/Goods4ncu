import 'package:image_picker/image_picker.dart';

import '../services/upload_service.dart';

typedef UserChatSendMessage =
    Future<void> Function({
      required String content,
      String? imageUrl,
      String? audioUrl,
    });

class UserChatMediaSendException implements Exception {
  UserChatMediaSendException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UserChatMediaSender {
  UserChatMediaSender({UploadService? uploadService})
    : _uploadService = uploadService ?? UploadService();

  final UploadService _uploadService;

  Future<void> sendPickedImage(
    XFile pickedImage, {
    required UserChatSendMessage sendMessage,
  }) async {
    final bytes = await pickedImage.readAsBytes();

    String uploadedImageUrl;
    try {
      final extension = inferImageExtension(pickedImage.path);
      final contentType = contentTypeForImageExtension(extension);
      uploadedImageUrl = await _uploadService.uploadImageBytes(
        bytes,
        extension: extension,
        contentType: contentType,
      );
    } catch (_) {
      throw UserChatMediaSendException('图片上传失败，请重试');
    }

    try {
      await sendMessage(content: '[图片消息]', imageUrl: uploadedImageUrl);
    } catch (e) {
      throw UserChatMediaSendException('发送失败: $e');
    }
  }

  Future<void> sendAudioBytes(
    List<int> audioBytes, {
    required UserChatSendMessage sendMessage,
  }) async {
    String uploadedAudioUrl;
    try {
      uploadedAudioUrl = await _uploadService.uploadAudioBytes(audioBytes);
    } catch (_) {
      throw UserChatMediaSendException('语音上传失败，请重试');
    }

    try {
      await sendMessage(content: '[语音消息]', audioUrl: uploadedAudioUrl);
    } catch (e) {
      throw UserChatMediaSendException('发送失败: $e');
    }
  }

  String inferImageExtension(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    return 'jpg';
  }

  String contentTypeForImageExtension(String extension) {
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }
}
