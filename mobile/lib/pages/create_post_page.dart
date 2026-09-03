import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/post_service.dart';
import '../services/upload_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/searchable_picker_sheet.dart';
import '../models/post_taxonomy.dart';
import '../utils/category_utils.dart';

class PickedPostImage {
  const PickedPostImage({
    required this.bytes,
    required this.extension,
    required this.contentType,
  });

  final Uint8List bytes;
  final String extension;
  final String contentType;
}

typedef PostImagePicker = Future<PickedPostImage?> Function();

const _listingCategoryKeys = [
  'electronics',
  'books',
  'digitalAccessories',
  'dailyGoods',
  'clothingShoes',
  'other',
];

class CreatePostPage extends StatefulWidget {
  const CreatePostPage({
    super.key,
    this.postService,
    this.uploadService,
    this.imagePicker,
    this.initialCategory = 'discussion',
    this.spaceId,
  });

  final PostService? postService;
  final UploadService? uploadService;
  final PostImagePicker? imagePicker;

  /// offer | wanted | discussion — preselected kind for the unified form.
  final String initialCategory;

  /// When set, the post is published into this group (member visibility).
  final String? spaceId;

  @override
  State<CreatePostPage> createState() => _CreatePostPageState();
}

class _CreatePostPageState extends State<CreatePostPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  late final PostService _postService;
  late final UploadService _uploadService;
  final ImagePicker _nativeImagePicker = ImagePicker();
  PickedPostImage? _coverImage;
  bool _submitting = false;

  late String _category = widget.initialCategory;
  final Set<String> _selectedTags = {};

  // Goods fields (offer/wanted attach a listing).
  final _goodsTitleController = TextEditingController();
  final _goodsBrandController = TextEditingController();
  double _conditionScore = 8;
  final _goodsPriceController = TextEditingController();
  String? _goodsCategory;
  DateTime? _eventStartsAt;
  final _eventPlaceController = TextEditingController();
  bool _canAnnounce = false;

  @override
  void initState() {
    super.initState();
    _postService = widget.postService ?? context.read<PostService>();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
    _probeAnnouncePermission();
  }

  Future<void> _probeAnnouncePermission() async {
    try {
      // can_read on admin capabilities == operator+ on the active campus.
      final caps = await context.read<ApiService>().getAdminCapabilities();
      if (!mounted) return;
      setState(() => _canAnnounce = caps['can_read'] == true);
    } catch (_) {
      // Announcement stays hidden without permission; never blocks publish.
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _goodsTitleController.dispose();
    _goodsBrandController.dispose();
    _goodsPriceController.dispose();
    _eventPlaceController.dispose();
    super.dispose();
  }

  bool get _needsGoods => postCategoryByKey(_category)?.isGoods ?? false;

  Future<void> _pickCategory() async {
    final selected = await showSearchablePickerSheet<String>(
      context: context,
      title: AppLocalizations.of(context)!.postCategoryLabel,
      options: [
        for (final category in kPostCategories)
          PickerOption(
            value: category.key,
            label: category.key == 'announcement' && !_canAnnounce
                ? '${category.label} · 仅运营'
                : category.label,
            keywords: [category.key],
          ),
      ],
      initiallySelected: [_category],
    );
    final next = selected?.isEmpty == false ? selected!.first : null;
    if (next == null || next == _category || !mounted) return;
    if (next == 'announcement' && !_canAnnounce) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('公告仅限运营发布')));
      return;
    }
    setState(() {
      _category = next;
      // Tags are category-agnostic now; nothing to prune on switches.
    });
  }

  static const String _locationGroupLabel = '地点';
  static const String _ttlGroupLabel = '时效';

  Future<void> _pickTags() async {
    final selected = await showSearchablePickerSheet<String>(
      context: context,
      title: AppLocalizations.of(context)!.postTagsLabel,
      options: [
        for (final tag in kPostTags)
          PickerOption(
            value: tag.key,
            // Same emoji+label rendering as the discover-page filter.
            label: postTagLabel(context, tag.key),
            subtitle: tag.group == 'location'
                ? _locationGroupLabel
                : tag.group == 'ttl'
                ? _ttlGroupLabel
                : null,
            keywords: [if (tag.group != null) tag.group!],
          ),
      ],
      initiallySelected: _selectedTags.toList(growable: false),
      multiSelect: true,
    );
    if (selected == null || !mounted) return;
    final picked = selected.toSet();
    // One pick per exclusive group; free tags are unlimited.
    final chosenGroups = <String>{};
    final result = <String>{};
    for (final tag in kPostTags) {
      if (!picked.contains(tag.key)) continue;
      if (tag.exclusive) {
        if (chosenGroups.contains(tag.group)) continue;
        chosenGroups.add(tag.group!);
      }
      result.add(tag.key);
    }
    setState(
      () => _selectedTags
        ..clear()
        ..addAll(result),
    );
  }

  Future<void> _submit() async {
    if (_submitting || _formKey.currentState?.validate() != true) return;
    setState(() => _submitting = true);
    try {
      final selectedImage = _coverImage;
      final coverImageUrl = selectedImage == null
          ? null
          : await _uploadService.uploadPostImageBytes(
              selectedImage.bytes,
              extension: selectedImage.extension,
              contentType: selectedImage.contentType,
            );

      final tags = _selectedTags.toList(growable: false);

      if (_needsGoods && _goodsCategory == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先选择商品分区')));
        setState(() => _submitting = false);
        return;
      }
      final marketplace = _needsGoods
          ? {
              'category': _goodsCategory!,
              'brand': _goodsBrandController.text.trim(),
              'condition_score': _conditionScore.round(),
              'suggested_price_cny':
                  double.tryParse(_goodsPriceController.text.trim()) ?? 0.0,
              'defects': const <String>[],
              'description': _bodyController.text.trim(),
            }
          : null;

      final post = await _postService.createPost(
        title: _titleController.text,
        body: _bodyController.text,
        category: _category,
        tags: tags,
        coverImageUrl: coverImageUrl,
        spaceId: widget.spaceId,
        marketplace: marketplace,
      );
      if (!mounted) return;
      context.go('/posts/${post.id}');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.postPublishFailed),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _pickCoverImage() async {
    if (_submitting) return;
    final picked = await (widget.imagePicker?.call() ?? _pickNativeImage());
    if (picked == null || !mounted) return;
    setState(() => _coverImage = picked);
  }

  Future<PickedPostImage?> _pickNativeImage() async {
    final image = await _nativeImagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (image == null) return null;
    final extension = image.name.split('.').last.toLowerCase();
    final normalizedExtension = switch (extension) {
      'png' => 'png',
      'webp' => 'webp',
      _ => 'jpg',
    };
    final contentType = switch (normalizedExtension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    return PickedPostImage(
      bytes: await image.readAsBytes(),
      extension: normalizedExtension,
      contentType: contentType,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.postCreateTitle)),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
              ? AppTheme.sp32
              : AppTheme.sp16,
        ),
        child: ResponsiveContent(
          maxWidth: 760,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: const ValueKey('publish-category-segment'),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  onTap: _submitting ? null : _pickCategory,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l.postCategoryLabel,
                      prefixIcon: const Icon(Icons.category_outlined),
                      suffixIcon: const Icon(Icons.expand_more_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      ),
                    ),
                    child: Text(
                      postCategoryByKey(_category)?.label ?? _category,
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.sp14),
                TextFormField(
                  key: const ValueKey('post-title-field'),
                  controller: _titleController,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.postTitleLabel,
                    hintText: l.postTitleHint,
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? l.postTitleRequired : null,
                ),
                const SizedBox(height: AppTheme.sp14),
                TextFormField(
                  key: const ValueKey('post-body-field'),
                  controller: _bodyController,
                  minLines: 6,
                  maxLines: 14,
                  maxLength: 10000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: l.postBodyLabel,
                    hintText: l.postBodyHint,
                    alignLabelWithHint: true,
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? l.postBodyRequired : null,
                ),
                const SizedBox(height: AppTheme.sp14),
                _buildTagsSection(l),
                if (_category == 'event') ...[
                  const SizedBox(height: AppTheme.sp14),
                  _buildEventAttributes(l),
                ],
                if (_needsGoods) ...[
                  const SizedBox(height: AppTheme.sp14),
                  _buildGoodsSection(l),
                ],
                const SizedBox(height: AppTheme.sp14),
                if (_coverImage == null)
                  OutlinedButton.icon(
                    key: const ValueKey('post-pick-cover-action'),
                    onPressed: _submitting ? null : _pickCoverImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(l.gallery),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  )
                else
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            _coverImage!.bytes,
                            key: const ValueKey('post-cover-preview'),
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            top: AppTheme.sp8,
                            right: AppTheme.sp8,
                            child: IconButton.filled(
                              key: const ValueKey('post-remove-cover-action'),
                              tooltip: l.delete,
                              onPressed: _submitting
                                  ? null
                                  : () => setState(() => _coverImage = null),
                              icon: const Icon(Icons.close_rounded),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: AppTheme.sp24),
                FilledButton.icon(
                  key: const ValueKey('post-publish-action'),
                  onPressed: _submitting ? null : _submit,
                  icon: const Icon(Icons.publish_rounded),
                  label: Text(l.postPublishAction),
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

  Widget _buildTagsSection(AppLocalizations l) {
    final selectedLabels = [
      for (final key in _selectedTags)
        if (kPostTags.any((t) => t.key == key))
          kPostTags.firstWhere((t) => t.key == key).label,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('publish-tags-picker'),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: _submitting ? null : _pickTags,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: l.postTagsLabel,
              helperText: '可多选；地点/时效各限一个',
              prefixIcon: const Icon(Icons.sell_outlined),
              suffixIcon: const Icon(Icons.expand_more_rounded),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
            ),
            child: selectedLabels.isEmpty
                ? Text(
                    l.postTagsLabel,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  )
                : Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final label in selectedLabels)
                        Chip(
                          label: Text(label),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickGoodsCategory() async {
    final selected = await showSearchablePickerSheet<String>(
      context: context,
      title: '选择商品分区（必填）',
      options: [
        for (final key in _listingCategoryKeys)
          PickerOption(value: key, label: localizedCategoryLabel(context, key)),
      ],
      initiallySelected: [?_goodsCategory],
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    setState(() => _goodsCategory = selected.first);
  }

  Widget _buildEventAttributes(AppLocalizations l) {
    final startsAt = _eventStartsAt;
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('活动信息', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: AppTheme.sp12),
          InkWell(
            key: const ValueKey('publish-event-starts-at'),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate:
                    startsAt ?? DateTime.now().add(const Duration(days: 1)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date == null || !mounted) return;
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(
                  startsAt ?? date.add(const Duration(hours: 10)),
                ),
              );
              if (!mounted) return;
              setState(() {
                _eventStartsAt = DateTime(
                  date.year,
                  date.month,
                  date.day,
                  time?.hour ?? 10,
                  time?.minute ?? 0,
                );
              });
            },
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '开始时间 *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: Text(
                startsAt == null
                    ? '请选择日期和时间'
                    : '开始于 ${startsAt.toLocal()}'.substring(0, 22),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _eventPlaceController,
            maxLength: 120,
            decoration: InputDecoration(labelText: '活动地点（选填）'),
          ),
        ],
      ),
    );
  }

  Widget _buildGoodsSection(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.publishGoodsSection,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: AppTheme.sp12),
          InkWell(
            key: const ValueKey('publish-goods-category-picker'),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            onTap: _submitting ? null : _pickGoodsCategory,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '${l.category} *',
                helperText: '必填：选择商品分区',
                suffixIcon: const Icon(Icons.expand_more_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: Text(
                _goodsCategory == null
                    ? '请选择分区'
                    : localizedCategoryLabel(context, _goodsCategory!),
                style: TextStyle(
                  color: _goodsCategory == null
                      ? Theme.of(context).hintColor
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _goodsBrandController,
            decoration: InputDecoration(labelText: l.publishBrandLabel),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            key: const ValueKey('publish-goods-price-field'),
            controller: _goodsPriceController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l.createListingPriceLabel),
            validator: (value) {
              final price = double.tryParse((value ?? '').trim());
              return price == null || price < 0 ? l.publishPriceRequired : null;
            },
          ),
          const SizedBox(height: AppTheme.sp8),
          Row(
            children: [
              Text(l.createListingConditionSection),
              Expanded(
                child: Slider(
                  value: _conditionScore,
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '${_conditionScore.round()}',
                  onChanged: (value) => setState(() => _conditionScore = value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
