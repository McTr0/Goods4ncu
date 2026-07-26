import 'dart:convert';

import '../models/models.dart';
import 'base_service.dart';

/// Trust built from what actually happened.
///
/// There is no method to leave a comment, because there is no endpoint that
/// takes one. A free-text field is where the social cost of an honest answer
/// comes straight back in.
class ReputationService extends BaseService {
  /// POST /api/handoffs/{id}/confirm — say what happened. Answerable once.
  Future<void> confirm(
    String agreementId, {
    required bool happened,
    bool? onTime,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/handoffs/$agreementId/confirm'),
      headers,
      jsonEncode({'happened': happened, 'on_time': ?onTime}),
    );
    handleResponse(response, (_) {});
  }

  /// GET /api/handoffs/pending — arrangements still owed an answer.
  Future<List<String>> pending() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/handoffs/pending'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['items'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
  }

  /// GET /api/users/{id}/reputation
  Future<Reputation> of(String userId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/users/$userId/reputation'),
      headers,
    );
    return Reputation.fromJson(
      handleResponse(response, (d) => d as Map<String, dynamic>),
    );
  }
}
