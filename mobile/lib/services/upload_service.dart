import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'base_service.dart';
import 'user_service.dart';

class UploadService extends BaseService {
  UploadService({UserService? userService})
    : _userService = userService ?? UserService();

  final UserService _userService;
  final Uuid _uuid = const Uuid();

  /// Upload bytes to an owner-scoped presigned PUT URL. No application or STS
  /// credentials are sent to the object store; the server already bound the
  /// URL to one persona asset key. The completion API still probes the object
  /// before it can enter review or become selectable.
  Future<String> uploadBytesToPresignedUrl(
    List<int> bytes, {
    required String uploadUrl,
    required String contentType,
  }) async {
    final uri = Uri.tryParse(uploadUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw NetworkException('文件上传目标无效');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw NetworkException('文件上传目标无效');
    }
    final response = await http
        .put(
          uri,
          headers: {'Content-Type': contentType},
          body: bytes,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 204) {
      throw NetworkException('文件上传失败: ${response.statusCode}');
    }
    return uploadUrl;
  }

  /// Upload bytes to a server-generated shared-object key. The key is never
  /// chosen by the client; callers must use `ChatSharedObject.uploadKey` and
  /// then call the API completion endpoint so the server probes the object.
  Future<String> uploadBytesToObjectKey(
    List<int> bytes, {
    required String objectKey,
    required String contentType,
  }) async {
    final normalizedKey = objectKey.trim().replaceFirst(RegExp(r'^/+'), '');
    if (normalizedKey.isEmpty || normalizedKey.contains('..')) {
      throw NetworkException('文件上传目标无效');
    }
    final stsToken = await _userService.getUploadToken();
    final endpointHost = stsToken.endpoint
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final ossUrl = Uri.https('${stsToken.bucket}.$endpointHost', normalizedKey);
    final ossDate = _buildOssDateHeader();
    final authorization = _buildOssAuthorization(
      method: 'PUT',
      contentType: contentType,
      date: ossDate,
      bucket: stsToken.bucket,
      objectKey: normalizedKey,
      accessKeyId: stsToken.accessKeyId,
      accessKeySecret: stsToken.accessKeySecret,
      securityToken: stsToken.securityToken,
    );
    final response = await http
        .put(
          ossUrl,
          headers: {
            'Date': ossDate,
            'Authorization': authorization,
            'x-oss-security-token': stsToken.securityToken,
            'Content-Type': contentType,
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw NetworkException('文件上传失败: ${response.statusCode}');
    }
    return ossUrl.toString();
  }

  Future<String> uploadAudioBytes(List<int> audioBytes) async {
    final stsToken = await _userService.getUploadToken();
    final objectKey =
        'chat/audio/${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}.ogg';
    final endpointHost = stsToken.endpoint
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final ossUrl = Uri.https('${stsToken.bucket}.$endpointHost', objectKey);
    const contentType = 'audio/ogg';
    final ossDate = _buildOssDateHeader();
    final authorization = _buildOssAuthorization(
      method: 'PUT',
      contentType: contentType,
      date: ossDate,
      bucket: stsToken.bucket,
      objectKey: objectKey,
      accessKeyId: stsToken.accessKeyId,
      accessKeySecret: stsToken.accessKeySecret,
      securityToken: stsToken.securityToken,
    );

    final response = await http
        .put(
          ossUrl,
          headers: {
            'Date': ossDate,
            'Authorization': authorization,
            'x-oss-security-token': stsToken.securityToken,
            'Content-Type': contentType,
          },
          body: audioBytes,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw NetworkException('语音上传失败: ${response.statusCode}');
    }

    return ossUrl.toString();
  }

  Future<String> uploadImageBytes(
    List<int> imageBytes, {
    String extension = 'jpg',
    String contentType = 'image/jpeg',
  }) async {
    final stsToken = await _userService.getUploadToken();
    final objectKey =
        'chat/image/${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}.$extension';
    final endpointHost = stsToken.endpoint
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final ossUrl = Uri.https('${stsToken.bucket}.$endpointHost', objectKey);
    final ossDate = _buildOssDateHeader();
    final authorization = _buildOssAuthorization(
      method: 'PUT',
      contentType: contentType,
      date: ossDate,
      bucket: stsToken.bucket,
      objectKey: objectKey,
      accessKeyId: stsToken.accessKeyId,
      accessKeySecret: stsToken.accessKeySecret,
      securityToken: stsToken.securityToken,
    );

    final response = await http
        .put(
          ossUrl,
          headers: {
            'Date': ossDate,
            'Authorization': authorization,
            'x-oss-security-token': stsToken.securityToken,
            'Content-Type': contentType,
          },
          body: imageBytes,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw NetworkException('图片上传失败: ${response.statusCode}');
    }

    return ossUrl.toString();
  }

  String _buildOssDateHeader() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final now = DateTime.now().toUtc();
    final weekday = weekdays[now.weekday - 1];
    final day = now.day.toString().padLeft(2, '0');
    final month = months[now.month - 1];
    final year = now.year;
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    return '$weekday, $day $month $year $hour:$minute:$second GMT';
  }

  String _buildOssAuthorization({
    required String method,
    required String contentType,
    required String date,
    required String bucket,
    required String objectKey,
    required String accessKeyId,
    required String accessKeySecret,
    required String securityToken,
  }) {
    final canonicalHeaders = 'x-oss-security-token:$securityToken\n';
    final canonicalResource = '/$bucket/$objectKey';
    final stringToSign =
        '$method\n\n$contentType\n$date\n$canonicalHeaders$canonicalResource';
    final hmac = Hmac(sha1, utf8.encode(accessKeySecret));
    final signature = base64Encode(
      hmac.convert(utf8.encode(stringToSign)).bytes,
    );
    return 'OSS $accessKeyId:$signature';
  }
}
