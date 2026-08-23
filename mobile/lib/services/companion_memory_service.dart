import 'dart:convert';

import 'base_service.dart';

/// Typed access to the companion memory / profile / skill APIs.
class CompanionMemoryService extends BaseService {
  // ---- profile ----------------------------------------------------------

  Future<Map<String, dynamic>> getProfile() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/agent/profile'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['profile'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Saves the free-form long-term instruction. Other profile fields are
  /// preserved by sending them back untouched.
  Future<void> saveCustomInstructions(String text) async {
    final profile = await getProfile();
    final headers = await authHeaders();
    final body = jsonEncode({
      'preferred_locations': profile['preferred_locations'] ?? [],
      'interested_categories': profile['interested_categories'] ?? [],
      'budget_preferences': profile['budget_preferences'] ?? {},
      'custom_instructions': text,
      'privacy_level': profile['privacy_level'] ?? 'standard',
      'is_memory_enabled': profile['is_memory_enabled'] ?? true,
      'is_proactive_enabled': profile['is_proactive_enabled'] ?? true,
    });
    final response = await put(
      Uri.parse('$baseUrl/api/agent/profile'),
      headers,
      body,
    );
    handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  Future<void> setMemoryEnabled(bool enabled) async {
    final profile = await getProfile();
    final headers = await authHeaders();
    final body = jsonEncode({
      'preferred_locations': profile['preferred_locations'] ?? [],
      'interested_categories': profile['interested_categories'] ?? [],
      'budget_preferences': profile['budget_preferences'] ?? {},
      'custom_instructions': profile['custom_instructions'],
      'privacy_level': profile['privacy_level'] ?? 'standard',
      'is_memory_enabled': enabled,
      'is_proactive_enabled': profile['is_proactive_enabled'] ?? true,
    });
    final response = await put(
      Uri.parse('$baseUrl/api/agent/profile'),
      headers,
      body,
    );
    handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  // ---- episodic memories ------------------------------------------------

  Future<List<Map<String, dynamic>>> listMemories() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/agent/memories?limit=100'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    final items = data['memories'] ?? data['items'] ?? [];
    return [
      for (final e in items as List<dynamic>)
        (e as Map).cast<String, dynamic>(),
    ];
  }

  Future<void> deleteMemory(String id) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/agent/memories/$id'),
      headers,
    );
    handleResponse(response, (d) => d is Map<String, dynamic>);
  }

  Future<int> clearAllMemories() async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/agent/memories'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['cleared'] as num?)?.toInt() ?? 0;
  }

  Future<void> clearSessionMemory() async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/agent/session-memory'),
      headers,
    );
    handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  // ---- skills -----------------------------------------------------------

  Future<List<Map<String, dynamic>>> listSkills() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/agent/skills'), headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    final items = data['skills'] as List<dynamic>? ?? [];
    return [for (final e in items) (e as Map).cast<String, dynamic>()];
  }

  Future<Map<String, dynamic>> upsertSkill({
    required String name,
    required String instructions,
    String? chipLabel,
    bool enabled = true,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agent/skills'),
      headers,
      jsonEncode({
        'name': name,
        'instructions': instructions,
        if (chipLabel != null && chipLabel.trim().isNotEmpty)
          'chip_label': chipLabel.trim(),
        'enabled': enabled,
      }),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['skill'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  Future<void> setSkillEnabled(String id, bool enabled) async {
    final headers = await authHeaders();
    final response = await patch(
      Uri.parse('$baseUrl/api/agent/skills/$id'),
      headers,
      jsonEncode({'enabled': enabled}),
    );
    handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  Future<void> deleteSkill(String id) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/agent/skills/$id'),
      headers,
    );
    handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  /// Imports a JSON array of {name, instructions, chip_label?, enabled?}.
  /// Returns the number of imported (or refreshed) skills.
  Future<int> importSkillsJson(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('expected a JSON array');
    var count = 0;
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final map = entry.cast<String, dynamic>();
      final name = map['name']?.toString() ?? '';
      final instructions = map['instructions']?.toString() ?? '';
      if (name.isEmpty || instructions.isEmpty) continue;
      await upsertSkill(
        name: name,
        instructions: instructions,
        chipLabel: map['chip_label']?.toString(),
        enabled: map['enabled'] is bool ? map['enabled'] as bool : true,
      );
      count++;
    }
    return count;
  }
}
