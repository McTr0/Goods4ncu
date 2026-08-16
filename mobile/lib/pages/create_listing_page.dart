import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/listing_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

typedef ImageBase64Picker = Future<String?> Function(ImageSource source);

class CreateListingPage extends StatefulWidget {
  final ApiService? apiService;
  final ImageBase64Picker? imageBase64Picker;
  final String initialDirection;
  final bool showBackButton;

  const CreateListingPage({
    super.key,
    this.apiService,
    this.imageBase64Picker,
    this.initialDirection = 'offer',
    this.showBackButton = false,
  });

  @override
  State<CreateListingPage> createState() => _CreateListingPageState();
}

class _CreateListingPageState extends State<CreateListingPage> {
  final _formKey = GlobalKey<FormState>();
  late final ApiService _apiService;
  final _imagePicker = ImagePicker();

  final _titleController = TextEditingController();
  final _brandController = TextEditingController();
  final _priceController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _defectController = TextEditingController();

  String _category = 'electronics';
  late String _direction;
  int _conditionScore = 7;
  final List<String> _defects = [];
  bool _isLoading = false;
  bool _isRecognizing = false;
  String? _imageBase64;
  String? _recognitionError;
  String? _submissionFingerprint;
  String? _submissionIdempotencyKey;

  static const _categoryKeys = [
    'electronics',
    'books',
    'digitalAccessories',
    'dailyGoods',
    'clothingShoes',
    'other',
  ];

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _direction = widget.initialDirection == 'wanted' ? 'wanted' : 'offer';
    _titleController.addListener(_refreshRequiredSummary);
    _brandController.addListener(_refreshRequiredSummary);
    _priceController.addListener(_refreshRequiredSummary);
  }

  @override
  void dispose() {
    _titleController.removeListener(_refreshRequiredSummary);
    _brandController.removeListener(_refreshRequiredSummary);
    _priceController.removeListener(_refreshRequiredSummary);
    _titleController.dispose();
    _brandController.dispose();
    _priceController.dispose();
    _descriptionController.dispose();
    _defectController.dispose();
    super.dispose();
  }

  void _refreshRequiredSummary() {
    if (mounted) setState(() {});
  }

  bool get _isWantedMode => _direction == 'wanted';

  Future<void> _takePhotoAndRecognize() =>
      _selectImageAndRecognize(ImageSource.camera);

  Future<void> _pickAndRecognize() =>
      _selectImageAndRecognize(ImageSource.gallery);

  Future<void> _selectImageAndRecognize(ImageSource source) async {
    if (_isWantedMode) return;
    final base64 =
        await (widget.imageBase64Picker?.call(source) ??
            _pickImageAsBase64(source));
    if (base64 == null) return;
    await _recognizeBase64(base64);
  }

  Future<String?> _pickImageAsBase64(ImageSource source) async {
    final image = await _imagePicker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 1024,
    );
    if (image == null) return null;

    final bytes = await image.readAsBytes();
    return base64Encode(bytes);
  }

  Future<void> _retryRecognition() async {
    final imageBase64 = _imageBase64;
    if (imageBase64 == null) return;
    await _recognizeBase64(imageBase64);
  }

  Future<void> _recognizeBase64(String base64) async {
    if (!mounted) return;
    setState(() {
      _isRecognizing = true;
      _imageBase64 = base64;
      _recognitionError = null;
    });

    try {
      final result = await _apiService.recognizeItem(base64);
      if (!mounted) return;

      setState(() {
        _applyRecognizedResult(result);
        _isRecognizing = false;
      });

      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.recognitionSuccess)));
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      final message = l.recognitionFailed(e.toString());
      setState(() {
        _isRecognizing = false;
        _recognitionError = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _applyRecognizedResult(RecognizedItem result) {
    if (_titleController.text.trim().isEmpty &&
        result.title.trim().isNotEmpty) {
      _titleController.text = result.title.trim();
    }
    if (_brandController.text.trim().isEmpty &&
        result.brand.trim().isNotEmpty) {
      _brandController.text = result.brand.trim();
    }
    if (_descriptionController.text.trim().isEmpty &&
        result.description.trim().isNotEmpty) {
      _descriptionController.text = result.description.trim();
    }
    if (_categoryKeys.contains(result.category)) {
      _category = result.category;
    }
    _conditionScore = result.conditionScore.clamp(1, 10);
    if (_defects.isEmpty) {
      _defects.addAll(result.defects.where((d) => d.trim().isNotEmpty));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final price = double.tryParse(_priceController.text) ?? 0;
      final title = _titleController.text.trim();
      final brand = _isWantedMode && _brandController.text.trim().isEmpty
          ? '不限'
          : _brandController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();
      final submissionFingerprint = jsonEncode({
        'title': title,
        'category': _category,
        'brand': brand,
        'direction': _direction,
        'condition_score': _conditionScore,
        'suggested_price_cny': price,
        'defects': _defects,
        'description': description,
      });
      if (_submissionFingerprint != submissionFingerprint) {
        _submissionFingerprint = submissionFingerprint;
        _submissionIdempotencyKey = const Uuid().v4();
      }

      final id = await _apiService.createListing(
        title: title,
        category: _category,
        brand: brand,
        conditionScore: _conditionScore,
        suggestedPriceCny: price,
        defects: _defects,
        description: description,
        direction: _direction,
        idempotencyKey: _submissionIdempotencyKey,
      );

      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.createSuccess)));
      context.go('/listing/$id');
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.createError}: $e')));
      setState(() => _isLoading = false);
    }
  }

  void _addDefect() {
    final text = _defectController.text.trim();
    if (text.isEmpty || _defects.contains(text)) return;

    setState(() => _defects.add(text));
    _defectController.clear();
  }

  Widget _buildModeSwitch() {
    final l = AppLocalizations.of(context)!;
    return _buildCard(
      child: SegmentedButton<String>(
        segments: [
          ButtonSegment(
            value: 'offer',
            icon: const Icon(Icons.north_east_rounded),
            label: Text(l.createListingModeOffer),
          ),
          ButtonSegment(
            value: 'wanted',
            icon: const Icon(Icons.south_west_rounded),
            label: Text(l.createListingModeWanted),
          ),
        ],
        selected: {_direction},
        onSelectionChanged: (values) {
          final next = values.first;
          if (next == _direction) return;
          setState(() {
            _direction = next;
            if (_isWantedMode && _brandController.text.trim().isEmpty) {
              _brandController.text = '不限';
            }
          });
        },
      ),
    );
  }

  String _getCategoryDisplayName(BuildContext context, String key) {
    final l = AppLocalizations.of(context)!;
    switch (key) {
      case 'electronics':
        return l.electronics;
      case 'books':
        return l.books;
      case 'digitalAccessories':
        return l.digitalAccessories;
      case 'dailyGoods':
        return l.dailyGoods;
      case 'clothingShoes':
        return l.clothingShoes;
      case 'other':
        return l.other;
      default:
        return key;
    }
  }

  String _conditionDisplayLabel(AppLocalizations l) {
    if (_conditionScore >= 9) return l.conditionLikeNew;
    if (_conditionScore >= 7) return l.conditionGood;
    if (_conditionScore >= 5) return l.conditionFair;
    return l.conditionPoor;
  }

  Color get _conditionColor => AppTheme.conditionColor(_conditionScore);

  bool get _hasValidPrice {
    final raw = _priceController.text.trim();
    return raw.isNotEmpty && double.tryParse(raw) != null;
  }

  List<String> _missingRequiredFields(AppLocalizations l) {
    final fields = <String>[];
    if (_titleController.text.trim().isEmpty) fields.add(l.title);
    if (!_isWantedMode && _brandController.text.trim().isEmpty) {
      fields.add(l.brand);
    }
    if (!_hasValidPrice) {
      fields.add(_isWantedMode ? l.wantedBudgetShort : l.price);
    }
    return fields;
  }

  Widget _buildSectionHeader(String title, IconData icon, {String? subtitle}) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.sp12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Icon(icon, size: 20, color: colorScheme.primary),
          ),
          const SizedBox(width: AppTheme.sp12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.sp20),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        boxShadow: AppTheme.softShadow,
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.58)),
      ),
      child: child,
    );
  }

  Widget _buildAiCapturePanel({bool compact = false}) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (_isWantedMode) {
      return Container(
        key: const ValueKey('create-wanted-prompt-panel'),
        width: double.infinity,
        padding: const EdgeInsets.all(AppTheme.sp24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radius2xl),
          gradient: LinearGradient(
            colors: theme.brightness == Brightness.dark
                ? const [Color(0xFF16312D), Color(0xFF10211F)]
                : const [Color(0xFFEAF7EF), Color(0xFFFFF7E8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.18)),
          boxShadow: AppTheme.softShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.search_rounded,
              size: compact ? 36 : 46,
              color: AppTheme.primary,
            ),
            const SizedBox(height: AppTheme.sp16),
            Text(
              l.createWantedPanelTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: AppTheme.sp8),
            Text(
              l.createWantedPanelSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    final isDark = theme.brightness == Brightness.dark;
    final onGradientText = isDark ? Colors.white : AppTheme.primaryDark;
    final secondaryText = isDark
        ? Colors.white.withValues(alpha: 0.76)
        : AppTheme.textSecondary;

    return Container(
      key: const ValueKey('create-ai-capture-panel'),
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radius2xl),
        gradient: LinearGradient(
          colors: isDark
              ? [AppTheme.primaryDark, const Color(0xFF0B3B39)]
              : [AppTheme.mint, AppTheme.sand],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: isDark ? 0.18 : 0.10),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (_imageBase64 == null)
            Padding(
              padding: EdgeInsets.all(compact ? AppTheme.sp20 : AppTheme.sp24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppTheme.sp16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(
                        alpha: isDark ? 0.12 : 0.7,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      size: compact ? 40 : 48,
                      color: isDark ? AppTheme.primaryLight : AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp16),
                  Text(
                    l.createListingAiTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: onGradientText,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp8),
                  Text(
                    l.createListingAiSubtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: secondaryText,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp20),
                  _buildImageActionButtons(),
                  if (_isRecognizing) _buildRecognizingIndicator(),
                ],
              ),
            )
          else
            _buildImagePreview(compact: compact),
        ],
      ),
    );
  }

  Widget _buildImagePreview({required bool compact}) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            AspectRatio(
              aspectRatio: compact ? 16 / 9 : 4 / 3,
              child: Image.memory(
                base64Decode(_imageBase64!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.72),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            Positioned(
              top: AppTheme.sp12,
              right: AppTheme.sp12,
              child: IconButton.filled(
                tooltip: l.createListingChangeImage,
                onPressed: _isRecognizing
                    ? null
                    : () => setState(() {
                        _imageBase64 = null;
                        _recognitionError = null;
                      }),
                icon: const Icon(Icons.close, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            Positioned(
              left: AppTheme.sp16,
              right: AppTheme.sp16,
              bottom: AppTheme.sp16,
              child: Wrap(
                spacing: AppTheme.sp8,
                runSpacing: AppTheme.sp8,
                children: [
                  _buildStatusPill(
                    icon: _recognitionError == null
                        ? Icons.check_circle
                        : Icons.error_outline,
                    label: _recognitionError == null
                        ? l.createListingAiReady
                        : l.createListingAiNeedsRetry,
                    color: _recognitionError == null
                        ? AppTheme.success
                        : AppTheme.error,
                  ),
                  if (_isRecognizing)
                    _buildStatusPill(
                      icon: Icons.auto_awesome,
                      label: l.createListingAiRecognizing,
                      color: AppTheme.info,
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_recognitionError != null || _isRecognizing)
          Container(
            padding: const EdgeInsets.all(AppTheme.sp16),
            color: theme.cardTheme.color?.withValues(alpha: 0.72),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_recognitionError != null)
                  Text(
                    _recognitionError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (_isRecognizing) _buildRecognizingIndicator(compact: true),
                if (_recognitionError != null) ...[
                  const SizedBox(height: AppTheme.sp12),
                  Wrap(
                    spacing: AppTheme.sp8,
                    runSpacing: AppTheme.sp8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _retryRecognition,
                        icon: const Icon(Icons.refresh),
                        label: Text(l.retry),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _pickAndRecognize,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(l.createListingChangeImage),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStatusPill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.sp12,
        vertical: AppTheme.sp8,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: AppTheme.sp6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageActionButtons() {
    final l = AppLocalizations.of(context)!;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AppTheme.sp12,
      runSpacing: AppTheme.sp12,
      children: [
        FilledButton.icon(
          key: const ValueKey('create-camera-button'),
          onPressed: _isRecognizing ? null : _takePhotoAndRecognize,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(l.takePhoto),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.sp24,
              vertical: AppTheme.sp14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
          ),
        ),
        FilledButton.tonalIcon(
          key: const ValueKey('create-gallery-button'),
          onPressed: _isRecognizing ? null : _pickAndRecognize,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(l.fromGallery),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.sp24,
              vertical: AppTheme.sp14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecognizingIndicator({bool compact = false}) {
    final l = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(top: compact ? 0 : AppTheme.sp16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(width: AppTheme.sp8),
          Flexible(
            child: Text(
              l.createListingAiRecognizing,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    final l = AppLocalizations.of(context)!;
    final basicsDone =
        _titleController.text.trim().isNotEmpty &&
        _brandController.text.trim().isNotEmpty &&
        _hasValidPrice;

    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.createListingProgressTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: AppTheme.sp6),
          Text(
            l.createListingProgressSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.sp16),
          _buildProgressItem(
            complete: _imageBase64 != null,
            label: l.createListingProgressImage,
          ),
          _buildProgressItem(
            complete: basicsDone,
            label: l.createListingProgressBasics,
          ),
          _buildProgressItem(
            complete: true,
            label: l.createListingProgressCondition,
          ),
          _buildProgressItem(
            complete:
                _descriptionController.text.trim().isNotEmpty ||
                _defects.isNotEmpty,
            label: l.createListingProgressDescription,
            optional: true,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressItem({
    required bool complete,
    required String label,
    bool optional = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = complete ? AppTheme.success : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.sp6),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: color,
          ),
          const SizedBox(width: AppTheme.sp8),
          Expanded(
            child: Text(
              optional
                  ? '$label · ${AppLocalizations.of(context)!.optional}'
                  : label,
              style: TextStyle(
                color: color,
                fontWeight: complete ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBasicsSection() {
    final l = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('create-basics-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          _isWantedMode ? l.createWantedBasicInfo : l.createListingBasicInfo,
          Icons.info_outline,
          subtitle: _isWantedMode
              ? l.createWantedBasicInfoSubtitle
              : l.createListingBasicInfoSubtitle,
        ),
        _buildCard(
          child: Column(
            children: [
              TextFormField(
                key: const ValueKey('create-title-field'),
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: '${l.title} *',
                  hintText: _isWantedMode
                      ? l.createWantedTitleHint
                      : l.createListingTitleHint,
                  prefixIcon: const Icon(Icons.title),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? l.titleRequired : null,
              ),
              const SizedBox(height: AppTheme.sp16),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: InputDecoration(
                  labelText: '${l.category} *',
                  prefixIcon: const Icon(Icons.category_outlined),
                ),
                items: _categoryKeys
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(_getCategoryDisplayName(context, c)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
                icon: const Icon(Icons.keyboard_arrow_down),
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              ),
              const SizedBox(height: AppTheme.sp16),
              TextFormField(
                key: const ValueKey('create-brand-field'),
                controller: _brandController,
                decoration: InputDecoration(
                  labelText: _isWantedMode
                      ? l.createWantedBrandLabel
                      : '${l.brand} *',
                  hintText: _isWantedMode
                      ? l.createWantedBrandHint
                      : l.createListingBrandHint,
                  prefixIcon: const Icon(Icons.branding_watermark_outlined),
                ),
                validator: (v) {
                  if (_isWantedMode) return null;
                  return v == null || v.trim().isEmpty
                      ? l.createListingBrandRequired
                      : null;
                },
              ),
              const SizedBox(height: AppTheme.sp16),
              TextFormField(
                key: const ValueKey('create-price-field'),
                controller: _priceController,
                decoration: InputDecoration(
                  labelText: _isWantedMode
                      ? l.createWantedBudgetLabel
                      : l.createListingPriceLabel,
                  hintText: '0.00',
                  prefixIcon: const Icon(Icons.currency_yuan),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l.createListingPriceRequired;
                  }
                  if (double.tryParse(v.trim()) == null) {
                    return l.createListingPriceInvalid;
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConditionSection() {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          _isWantedMode
              ? l.createWantedConditionSection
              : l.createListingConditionSection,
          Icons.health_and_safety_outlined,
          subtitle: _isWantedMode
              ? l.createWantedConditionSubtitle
              : l.createListingConditionSubtitle,
        ),
        _buildCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isWantedMode ? l.wantedMinimumCondition : l.condition,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.sp12,
                      vertical: AppTheme.sp8,
                    ),
                    decoration: BoxDecoration(
                      color: _conditionColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$_conditionScore/10 ${_conditionDisplayLabel(l)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: _conditionColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.sp16),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _conditionColor,
                  inactiveTrackColor: _conditionColor.withValues(alpha: 0.22),
                  thumbColor: _conditionColor,
                  overlayColor: _conditionColor.withValues(alpha: 0.1),
                  trackHeight: 8,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 12,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 24,
                  ),
                ),
                child: Slider(
                  value: _conditionScore.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  onChanged: (v) => setState(() => _conditionScore = v.round()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l.conditionPoor,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      l.conditionLikeNew,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.sp24),
              Text(
                _isWantedMode ? l.createWantedRequirementsLabel : l.defects,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: AppTheme.sp12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _defectController,
                      decoration: InputDecoration(
                        hintText: _isWantedMode
                            ? l.createWantedRequirementHint
                            : l.createListingDefectHint,
                        prefixIcon: const Icon(Icons.report_problem_outlined),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.sp16,
                          vertical: AppTheme.sp12,
                        ),
                      ),
                      onSubmitted: (_) => _addDefect(),
                    ),
                  ),
                  const SizedBox(width: AppTheme.sp12),
                  FilledButton(
                    onPressed: _addDefect,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.all(AppTheme.sp14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      ),
                    ),
                    child: const Icon(Icons.add),
                  ),
                ],
              ),
              if (_defects.isNotEmpty) ...[
                const SizedBox(height: AppTheme.sp16),
                Wrap(
                  spacing: AppTheme.sp8,
                  runSpacing: AppTheme.sp8,
                  children: _defects
                      .map(
                        (d) => Chip(
                          label: Text(d),
                          deleteIcon: const Icon(Icons.cancel, size: 18),
                          onDeleted: () => setState(() => _defects.remove(d)),
                          backgroundColor: AppTheme.error.withValues(
                            alpha: 0.10,
                          ),
                          labelStyle: const TextStyle(
                            color: AppTheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDescriptionSection() {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          _isWantedMode
              ? l.createWantedDescriptionSection
              : l.createListingDescriptionSection,
          Icons.description_outlined,
          subtitle: _isWantedMode
              ? l.createWantedDescriptionSubtitle
              : l.createListingDescriptionSubtitle,
        ),
        _buildCard(
          child: TextFormField(
            controller: _descriptionController,
            decoration: InputDecoration(
              labelText: _isWantedMode
                  ? l.createWantedDescriptionLabel
                  : l.createListingDescriptionLabel,
              hintText: _isWantedMode
                  ? l.createWantedDescriptionHint
                  : l.createListingDescriptionHint,
              alignLabelWithHint: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
            ),
            maxLines: 5,
          ),
        ),
      ],
    );
  }

  Widget _buildMobileWorkspace() {
    return ListView(
      key: const ValueKey('create-mobile-workspace'),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.sp16,
        AppTheme.sp24,
        AppTheme.sp16,
        AppTheme.sp32,
      ),
      children: [
        _buildModeSwitch(),
        const SizedBox(height: AppTheme.sp20),
        _buildAiCapturePanel(compact: true),
        const SizedBox(height: AppTheme.sp24),
        _buildBasicsSection(),
        const SizedBox(height: AppTheme.sp24),
        _buildConditionSection(),
        const SizedBox(height: AppTheme.sp24),
        _buildDescriptionSection(),
      ],
    );
  }

  Widget _buildDesktopWorkspace() {
    return SingleChildScrollView(
      key: const ValueKey('create-desktop-workspace'),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.sp24,
        AppTheme.sp32,
        AppTheme.sp24,
        AppTheme.sp32,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 380,
            child: Column(
              children: [
                _buildModeSwitch(),
                const SizedBox(height: AppTheme.sp20),
                _buildAiCapturePanel(),
                const SizedBox(height: AppTheme.sp20),
                _buildProgressCard(),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.sp24),
          Expanded(
            child: Column(
              children: [
                _buildBasicsSection(),
                const SizedBox(height: AppTheme.sp24),
                _buildConditionSection(),
                const SizedBox(height: AppTheme.sp24),
                _buildDescriptionSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickySubmitBar() {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final missingFields = _missingRequiredFields(l);
    final summary = missingFields.isEmpty
        ? l.createListingReadyHint
        : l.createListingMissingFields(missingFields.join(l.listSeparator));

    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('create-sticky-submit'),
        padding: const EdgeInsets.fromLTRB(
          AppTheme.sp16,
          AppTheme.sp12,
          AppTheme.sp16,
          AppTheme.sp14,
        ),
        decoration: BoxDecoration(
          color: theme.cardTheme.color?.withValues(alpha: 0.96),
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.7)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.32 : 0.08,
              ),
              blurRadius: 18,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: ResponsiveContent(
          maxWidth: 1180,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      missingFields.isEmpty
                          ? Icons.check_circle
                          : Icons.edit_note,
                      color: missingFields.isEmpty
                          ? AppTheme.success
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppTheme.sp8),
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.sp12),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  key: const ValueKey('create-submit-button'),
                  onPressed: _isLoading ? null : _submit,
                  icon: _isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.publish_outlined, size: 20),
                  label: Text(l.submit),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.createListing),
        backgroundColor: Theme.of(
          context,
        ).scaffoldBackgroundColor.withValues(alpha: 0.92),
        elevation: 0,
        automaticallyImplyLeading: widget.showBackButton,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Form(
                key: _formKey,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth >= 1240;
                    return ResponsiveContent(
                      maxWidth: isDesktop ? 1180 : 860,
                      child: isDesktop
                          ? _buildDesktopWorkspace()
                          : _buildMobileWorkspace(),
                    );
                  },
                ),
              ),
            ),
            _buildStickySubmitBar(),
          ],
        ),
      ),
    );
  }
}
