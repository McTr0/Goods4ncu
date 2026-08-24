import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/companion_memory_service.dart';
import '../theme/app_theme.dart';

/// Full-screen manager for 小昌's memory, long-term instructions, and
/// user-authored skills. Everything here maps 1:1 onto existing
/// /api/agent/* endpoints.
class AssistantMemoryPanel extends StatefulWidget {
  const AssistantMemoryPanel({super.key, this.service});

  final CompanionMemoryService? service;

  static Future<void> show(
    BuildContext context, {
    CompanionMemoryService? service,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AssistantMemoryPanel(service: service),
      ),
    );
  }

  @override
  State<AssistantMemoryPanel> createState() => _AssistantMemoryPanelState();
}

/// Copy-paste-safe import sample (half-width JSON punctuation only).
const String kSkillImportExample =
    '[{"name": "砍价助手", "instructions": "帮我用友善语气砍价", "chip_label": "帮我砍价"}]';

class _AssistantMemoryPanelState extends State<AssistantMemoryPanel> {
  late final CompanionMemoryService _service =
      widget.service ?? CompanionMemoryService();

  final TextEditingController _instructionsController = TextEditingController();
  final TextEditingController _skillNameController = TextEditingController();
  final TextEditingController _skillInstructionsController =
      TextEditingController();
  final TextEditingController _importController = TextEditingController();

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _memories = [];
  List<Map<String, dynamic>> _skills = [];
  bool _savingInstructions = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _instructionsController.dispose();
    _skillNameController.dispose();
    _skillInstructionsController.dispose();
    _importController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await _service.getProfile();
      final memories = await _service.listMemories();
      final skills = await _service.listSkills();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _memories = memories;
        _skills = skills;
        _instructionsController.text = (profile['custom_instructions'] ?? '')
            .toString();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveInstructions() async {
    setState(() => _savingInstructions = true);
    try {
      await _service.saveCustomInstructions(
        _instructionsController.text.trim(),
      );
      if (!mounted) return;
      _toast(AppLocalizations.of(context)!.memorySavedToast);
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    } finally {
      if (mounted) setState(() => _savingInstructions = false);
    }
  }

  Future<void> _toggleMemory(bool enabled) async {
    try {
      await _service.setMemoryEnabled(enabled);
      if (!mounted) return;
      setState(() => _profile = {...?_profile, 'is_memory_enabled': enabled});
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _deleteMemory(Map<String, dynamic> memory) async {
    try {
      await _service.deleteMemory(memory['id'].toString());
      if (!mounted) return;
      setState(() => _memories.removeWhere((m) => m['id'] == memory['id']));
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _clearMemories() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.memoryClearAllTitle),
        content: Text(l.memoryClearAllBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(l.memoryClearAllAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.clearAllMemories();
      await _service.clearSessionMemory();
      if (!mounted) return;
      setState(() => _memories = []);
      _toast(l.memoryClearedToast);
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _toggleSkill(Map<String, dynamic> skill) async {
    final id = skill['id'].toString();
    final next = !(skill['enabled'] == true);
    try {
      await _service.setSkillEnabled(id, next);
      if (!mounted) return;
      setState(
        () => _skills = [
          for (final s in _skills)
            if (s['id'] == id) {...s, 'enabled': next} else s,
        ],
      );
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _deleteSkill(Map<String, dynamic> skill) async {
    try {
      await _service.deleteSkill(skill['id'].toString());
      if (!mounted) return;
      setState(() => _skills.removeWhere((s) => s['id'] == skill['id']));
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _addSkill() async {
    final l = AppLocalizations.of(context)!;
    final name = _skillNameController.text.trim();
    final instructions = _skillInstructionsController.text.trim();
    if (name.isEmpty || instructions.isEmpty) {
      _toast(l.skillMissingFields);
      return;
    }
    try {
      final skill = await _service.upsertSkill(
        name: name,
        instructions: instructions,
      );
      if (!mounted) return;
      setState(() {
        _skills.removeWhere((s) => s['name'] == name);
        _skills = [..._skills, skill];
        _skillNameController.clear();
        _skillInstructionsController.clear();
      });
      _toast(l.skillSavedToast);
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    }
  }

  Future<void> _importSkills() async {
    final l = AppLocalizations.of(context)!;
    final raw = _importController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _importing = true);
    try {
      jsonDecode(raw); // validate before hitting the API
      final count = await _service.importSkillsJson(raw);
      if (!mounted) return;
      final skills = await _service.listSkills();
      setState(() {
        _skills = skills;
        _importController.clear();
      });
      _toast(l.skillsImported(count));
    } on FormatException {
      _toast(l.skillImportBadJson);
    } catch (error) {
      if (!mounted) return;
      _toast(error.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.assistantMemoryPanelTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : ListView(
              padding: const EdgeInsets.all(AppTheme.sp16),
              children: [
                _buildSectionTitle(l.memoryInstructionsTitle),
                TextField(
                  key: const Key('memory-instructions-field'),
                  controller: _instructionsController,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    hintText: l.memoryInstructionsHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.icon(
                      key: const Key('memory-instructions-save'),
                      onPressed: _savingInstructions ? null : _saveInstructions,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: Text(l.confirm),
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const Key('memory-enabled-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.memoryEnabledTitle),
                  subtitle: Text(l.memoryEnabledSubtitle),
                  value: _profile?['is_memory_enabled'] != false,
                  onChanged: _toggleMemory,
                ),
                const Divider(height: AppTheme.sp32),
                Row(
                  children: [
                    Expanded(child: _buildSectionTitle(l.memoriesListTitle)),
                    TextButton.icon(
                      key: const Key('memory-clear-all'),
                      // Session memory can exist without long-term entries,
                      // so clearing must stay reachable either way.
                      onPressed: _clearMemories,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: Text(l.memoryClearAllAction),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.error,
                      ),
                    ),
                  ],
                ),
                if (_memories.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      l.memoriesEmpty,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                  )
                else ...[
                  for (final memory in _memories)
                    ListTile(
                      key: Key('memory-item-${memory['id']}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.memory_outlined),
                      title: Text(
                        memory['content']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => _deleteMemory(memory),
                      ),
                    ),
                ],
                const Divider(height: AppTheme.sp32),
                _buildSectionTitle(l.skillsTitle),
                ...[
                  for (final skill in _skills)
                    ListTile(
                      key: Key('skill-item-${skill['id']}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(skill['name']?.toString() ?? ''),
                      subtitle: Text(
                        skill['instructions']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: skill['enabled'] == true,
                            onChanged: (_) => _toggleSkill(skill),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => _deleteSkill(skill),
                          ),
                        ],
                      ),
                    ),
                ],
                TextField(
                  key: const Key('skill-name-field'),
                  controller: _skillNameController,
                  decoration: InputDecoration(
                    labelText: l.skillNameLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('skill-instructions-field'),
                  controller: _skillInstructionsController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: l.skillInstructionsLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('skill-add'),
                    onPressed: _addSkill,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: Text(l.skillAddAction),
                  ),
                ),
                const Divider(height: AppTheme.sp32),
                _buildSectionTitle(l.skillsImportTitle),
                TextField(
                  key: const Key('skill-import-field'),
                  controller: _importController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: l.skillsImportHint(kSkillImportExample),
                    border: const OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.tonalIcon(
                      key: const Key('skill-import-run'),
                      onPressed: _importing ? null : _importSkills,
                      icon: const Icon(Icons.upload_outlined, size: 18),
                      label: Text(l.skillsImportAction),
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.sp32),
              ],
            ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
