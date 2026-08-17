import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/intent_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

class CreateErrandPage extends StatefulWidget {
  const CreateErrandPage({super.key, this.intentService});

  final IntentService? intentService;

  @override
  State<CreateErrandPage> createState() => _CreateErrandPageState();
}

class _CreateErrandPageState extends State<CreateErrandPage> {
  final _formKey = GlobalKey<FormState>();
  final _subjectController = TextEditingController();
  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  final _timeController = TextEditingController();
  final _rewardController = TextEditingController();
  final _notesController = TextEditingController();
  late final IntentService _intentService;
  String _mode = 'pickup';
  String _serviceDirection = 'wanted';
  String _validFor = '24h';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _intentService = widget.intentService ?? context.read<IntentService>();
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _pickupController.dispose();
    _dropoffController.dispose();
    _timeController.dispose();
    _rewardController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String _modeLabel(AppLocalizations l, String mode) => switch (mode) {
    'pickup' => l.errandModePickup,
    'buy' => l.errandModeBuy,
    'queue' => l.errandModeQueue,
    'print' => l.errandModePrint,
    'return' => l.errandModeReturn,
    _ => l.errandModeOther,
  };

  String _rawInput() {
    final parts = <String>[
      '${_modeLabel(AppLocalizations.of(context)!, _mode)}：${_subjectController.text.trim()}',
      if (_pickupController.text.trim().isNotEmpty)
        '取件：${_pickupController.text.trim()}',
      if (_dropoffController.text.trim().isNotEmpty)
        '送到：${_dropoffController.text.trim()}',
      if (_timeController.text.trim().isNotEmpty)
        '时间：${_timeController.text.trim()}',
      if (_rewardController.text.trim().isNotEmpty)
        '报酬：${_rewardController.text.trim()} 元',
      if (_notesController.text.trim().isNotEmpty)
        '补充：${_notesController.text.trim()}',
    ];
    return parts.join('；');
  }

  DateTime _expiry() {
    final duration = switch (_validFor) {
      '3d' => const Duration(days: 3),
      '7d' => const Duration(days: 7),
      _ => const Duration(hours: 24),
    };
    return DateTime.now().add(duration);
  }

  Future<void> _submit() async {
    if (_submitting || _formKey.currentState?.validate() != true) return;
    setState(() => _submitting = true);
    try {
      final reward = double.tryParse(
        _rewardController.text.trim().replaceAll(',', '.'),
      );
      final rewardCents = reward == null || reward <= 0
          ? null
          : (reward * 100).round();
      final pickup = _pickupController.text.trim();
      final dropoff = _dropoffController.text.trim();
      final timeHint = _timeController.text.trim();
      final notes = _notesController.text.trim();
      await _intentService.createIntent(
        kind: IntentKind.help,
        rawInput: _rawInput(),
        slots: IntentSlots(
          subject: _subjectController.text.trim(),
          category: 'campus_errand',
          serviceDirection: _serviceDirection,
          serviceMode: _mode,
          pickupPlace: pickup.isEmpty ? null : pickup,
          dropoffPlace: dropoff.isEmpty ? null : dropoff,
          place: pickup.isNotEmpty ? pickup : dropoff,
          time: TimeSlot.flexible(timeHint.isEmpty ? null : timeHint),
          price: rewardCents == null ? null : PriceSlot.exact(rewardCents),
          notes: notes.isEmpty ? const [] : [notes],
        ),
        validUntil: _expiry(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.errandPublishSuccess),
        ),
      );
      await Navigator.of(context).maybePop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.errandPublishFailed),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    const modes = ['pickup', 'buy', 'queue', 'print', 'return', 'other'];
    return Scaffold(
      appBar: AppBar(title: Text(l.errandPublishTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: ResponsiveContent(
          maxWidth: 760,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppTheme.sp16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.directions_run_rounded, color: scheme.primary),
                      const SizedBox(width: AppTheme.sp12),
                      Expanded(child: Text(l.errandPublishIntro)),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.sp20),
                TextFormField(
                  key: const ValueKey('errand-subject-field'),
                  controller: _subjectController,
                  maxLength: 160,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.errandSubjectLabel,
                    hintText: l.errandSubjectHint,
                  ),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? l.errandSubjectRequired
                      : null,
                ),
                const SizedBox(height: AppTheme.sp8),
                Text(
                  l.errandServiceDirectionLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppTheme.sp8),
                SegmentedButton<String>(
                  key: const ValueKey('errand-service-direction'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: 'wanted',
                      icon: const Icon(Icons.south_west_rounded, size: 18),
                      label: Text(l.errandServiceWanted),
                    ),
                    ButtonSegment(
                      value: 'offer',
                      icon: const Icon(Icons.north_east_rounded, size: 18),
                      label: Text(l.errandServiceOffer),
                    ),
                  ],
                  selected: {_serviceDirection},
                  onSelectionChanged: _submitting
                      ? null
                      : (values) {
                          if (values.isNotEmpty) {
                            setState(() => _serviceDirection = values.first);
                          }
                        },
                ),
                const SizedBox(height: AppTheme.sp8),
                Text(
                  _serviceDirection == 'offer'
                      ? l.errandServiceOfferHint
                      : l.errandServiceWantedHint,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: AppTheme.sp16),
                Text(
                  l.errandModeLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppTheme.sp8),
                Wrap(
                  spacing: AppTheme.sp8,
                  runSpacing: AppTheme.sp8,
                  children: [
                    for (final mode in modes)
                      ChoiceChip(
                        key: ValueKey('errand-mode-$mode'),
                        label: Text(_modeLabel(l, mode)),
                        selected: _mode == mode,
                        onSelected: _submitting
                            ? null
                            : (selected) {
                                if (selected) setState(() => _mode = mode);
                              },
                      ),
                  ],
                ),
                const SizedBox(height: AppTheme.sp16),
                TextFormField(
                  key: const ValueKey('errand-pickup-field'),
                  controller: _pickupController,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.errandPickupLabel,
                    hintText: l.errandPickupHint,
                    prefixIcon: const Icon(Icons.upload_outlined),
                  ),
                ),
                const SizedBox(height: AppTheme.sp12),
                TextFormField(
                  key: const ValueKey('errand-dropoff-field'),
                  controller: _dropoffController,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.errandDropoffLabel,
                    hintText: l.errandDropoffHint,
                    prefixIcon: const Icon(Icons.download_outlined),
                  ),
                ),
                const SizedBox(height: AppTheme.sp12),
                TextFormField(
                  key: const ValueKey('errand-time-field'),
                  controller: _timeController,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.errandTimeLabel,
                    hintText: l.errandTimeHint,
                    prefixIcon: const Icon(Icons.schedule_outlined),
                  ),
                ),
                const SizedBox(height: AppTheme.sp12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('errand-reward-field'),
                        controller: _rewardController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: l.errandRewardLabel,
                          hintText: l.errandRewardHint,
                          prefixIcon: const Icon(Icons.payments_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppTheme.sp12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('errand-valid-for-field'),
                        initialValue: _validFor,
                        decoration: InputDecoration(
                          labelText: l.errandValidForLabel,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '24h',
                            child: Text(l.errandValidForDay),
                          ),
                          DropdownMenuItem(
                            value: '3d',
                            child: Text(l.errandValidForThreeDays),
                          ),
                          DropdownMenuItem(
                            value: '7d',
                            child: Text(l.errandValidForWeek),
                          ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _validFor = value);
                                }
                              },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.sp12),
                TextFormField(
                  key: const ValueKey('errand-notes-field'),
                  controller: _notesController,
                  maxLength: 240,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l.errandNotesLabel,
                    hintText: l.errandNotesHint,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: AppTheme.sp20),
                FilledButton.icon(
                  key: const ValueKey('errand-publish-action'),
                  onPressed: _submitting ? null : _submit,
                  icon: const Icon(Icons.publish_rounded),
                  label: Text(l.errandPublishAction),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
