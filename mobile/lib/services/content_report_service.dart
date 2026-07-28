import 'dart:convert';

import 'base_service.dart';

/// Reports marketplace content without requiring the reporter to contact the
/// person first.
class ContentReportService extends BaseService {
  Future<String> reportListing(
    String listingId, {
    required String reason,
    String? details,
  }) => _submit(
    '/api/listings/${Uri.encodeComponent(listingId)}/report',
    reason: reason,
    details: details,
  );

  Future<String> reportUser(
    String userId, {
    required String reason,
    String? details,
  }) => _submit(
    '/api/users/${Uri.encodeComponent(userId)}/report',
    reason: reason,
    details: details,
  );

  Future<String> _submit(
    String path, {
    required String reason,
    String? details,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl$path'),
      headers,
      jsonEncode({
        'reason': reason.trim(),
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
      }),
    );
    return handleResponse(
      response,
      (data) => (data as Map<String, dynamic>)['report_id']?.toString() ?? '',
    );
  }
}
