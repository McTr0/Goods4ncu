import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'base_service.dart';

/// Intents: what someone wants, in their own words.
///
/// The whole point of this API is how little it asks for. `rawInput` is the only
/// required field; a price, a time, a category are all optional, and leaving one
/// out is an answer rather than an omission. A client that starts demanding them
/// has rebuilt the listing form this layer exists to replace.
class IntentService extends BaseService {
  static const _uuid = Uuid();

  /// POST /api/intents
  Future<IntentCreated> createIntent({
    required IntentKind kind,
    required String rawInput,
    IntentSlots slots = const IntentSlots(),
    DateTime? validUntil,
    bool private = false,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/intents'),
      headers,
      jsonEncode({
        'kind': kind.wire,
        'raw_input': rawInput,
        'slots': slots.toJson(),
        if (validUntil != null)
          'valid_until': validUntil.toUtc().toIso8601String(),
        if (private) 'visibility': 'private',
      }),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return IntentCreated.fromJson(data);
  }

  /// GET /api/intents — the caller's own, drafts included so they can see what
  /// is waiting on them.
  Future<List<UserIntent>> myIntents() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/intents'), headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['items'] as List<dynamic>? ?? [])
        .map((e) => UserIntent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/intents/{id}/matches
  ///
  /// Hard filtering only — these are the candidates that are *not impossible*,
  /// not a ranked shortlist. The server deliberately does not fold a similarity
  /// score into it, so a stated budget cannot be talked past.
  Future<List<UserIntent>> matchesFor(String intentId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/intents/$intentId/matches'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['items'] as List<dynamic>? ?? [])
        .map((e) => UserIntent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/intents/{id}/confirm — accept an inferred reading as真.
  Future<void> confirmIntent(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/intents/$id/confirm'),
      headers,
      jsonEncode({}),
    );
    handleResponse(response, (_) {});
  }

  /// POST /api/intents/{id}/fulfil — it worked.
  ///
  /// Kept distinct from withdrawing, because "someone helped me" and "never
  /// mind" are opposite outcomes that a single "close" button would merge.
  Future<void> fulfilIntent(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/intents/$id/fulfil'),
      headers,
      jsonEncode({}),
    );
    handleResponse(response, (_) {});
  }

  /// DELETE /api/intents/{id} — never mind.
  Future<void> withdrawIntent(String id) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/intents/$id'),
      headers,
    );
    handleResponse(response, (_) {});
  }

  /// GET /api/intents/feed — what everyone on this campus is currently after.
  ///
  /// Visible without having posted anything, which is the point: otherwise a new
  /// student opens the app, has said nothing, and finds an empty room.
  ///
  /// Author identities are not included. Answering goes through
  /// [respondToIntent], where the server resolves who to open a conversation
  /// with — so this list cannot be read as a directory of who wants what.
  Future<List<UserIntent>> campusFeed({IntentKind? kind, int limit = 30}) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/intents/feed').replace(
      queryParameters: {
        if (kind != null) 'kind': kind.wire,
        'limit': '$limit',
      },
    );
    final response = await get(uri, headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['items'] as List<dynamic>? ?? [])
        .map((e) => UserIntent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/intents/{id}/respond — answer someone, opening a conversation.
  ///
  /// Returns the conversation id. `clientRequestId` is supplied so a retried tap
  /// cannot open two conversations for one answer.
  Future<String> respondToIntent(String intentId, String content) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/intents/$intentId/respond'),
      headers,
      jsonEncode({
        'content': content,
        'client_request_id': _uuid.v4(),
      }),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return data['conversation_id']?.toString() ?? '';
  }

  /// GET /api/spaces/{id}/why — why the caller is in a space.
  ///
  /// Returns null when there is no answer to give: a hand-made group, or one
  /// the caller is not in. One result for both, so this cannot be used to probe
  /// who is in which room.
  Future<String?> whyThisSpace(String spaceId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/spaces/$spaceId/why'),
      headers,
    );
    if (response.statusCode == 404) return null;
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return data['reason']?.toString();
  }
}
