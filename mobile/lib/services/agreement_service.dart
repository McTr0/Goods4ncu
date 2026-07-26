import 'dart:convert';

import '../models/models.dart';
import 'base_service.dart';

/// The arrangement card for a conversation.
class AgreementService extends BaseService {
  /// POST /api/agreements — the card, created on first use.
  Future<Agreement> ensure(String conversationId, String kind) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agreements'),
      headers,
      jsonEncode({'conversation_id': conversationId, 'kind': kind}),
    );
    return Agreement.fromJson(
      handleResponse(response, (d) => d as Map<String, dynamic>),
    );
  }

  /// PUT /api/agreements/{id}/terms — state or change a term.
  ///
  /// Stating it counts as agreeing to it. Changing it withdraws the other
  /// side's agreement, because their yes was to the old value.
  Future<Agreement> setTerm(
    String agreementId,
    String slot,
    String value, {
    int? valueCents,
  }) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse('$baseUrl/api/agreements/$agreementId/terms'),
      headers,
      jsonEncode({'slot': slot, 'value': value, 'value_cents': ?valueCents}),
    );
    return Agreement.fromJson(
      handleResponse(response, (d) => d as Map<String, dynamic>),
    );
  }

  /// POST /api/agreements/{id}/adopt — say yes to a term as it stands.
  ///
  /// `expectedValue` is sent so a tap on a card that changed while it was on
  /// screen cannot agree to something else.
  Future<Agreement> adopt(
    String agreementId,
    String slot,
    String expectedValue,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agreements/$agreementId/adopt'),
      headers,
      jsonEncode({'slot': slot, 'expected_value': expectedValue}),
    );
    return Agreement.fromJson(
      handleResponse(response, (d) => d as Map<String, dynamic>),
    );
  }

  /// POST /api/agreements/{id}/settle
  Future<Agreement> settle(String agreementId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agreements/$agreementId/settle'),
      headers,
      jsonEncode({}),
    );
    return Agreement.fromJson(
      handleResponse(response, (d) => d as Map<String, dynamic>),
    );
  }
}
