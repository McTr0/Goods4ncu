import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../services/listing_service.dart';
import '../services/post_service.dart';
import '../services/upload_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../utils/category_utils.dart';
import '../utils/mutual_aid_utils.dart';

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

/// Curated tag catalog — mirrors migrations/0100_post_taxonomy.sql.
const _tagCatalog = <String, ({String label, List<String> categories})>{
  'question': (label: '提问', categories: []),
  'share': (label: '分享', categories: []),
  'help': (label: '求助', categories: []),
  'urgent': (label: '急', categories: []),
  'longterm': (label: '长期有效', categories: []),
  'event': (label: '活动', categories: []),
  'negotiable': (label: '可议价', categories: ['offer']),
  'freeShipping': (label: '包邮', categories: ['offer']),
  'pickupOnly': (label: '仅自提', categories: ['offer']),
  'brandNew': (label: '全新', categories: ['offer']),
  'likeNew': (label: '九成新', categories: ['offer']),
  'sellFast': (label: '急出', categories: ['offer']),
  'budgetFlexible': (label: '预算可议', categories: ['wanted']),
  'topPrice': (label: '高价收', categories: ['wanted']),
  'usedOk': (label: '接受二手', categories: ['wanted']),
  // Special: unlocks the structured errand payload on offer/wanted posts.
  'errand': (label: '跑腿互助', categories: ['offer', 'wanted']),
};

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
    this.listingService,
    this.imagePicker,
    this.initialCategory = 'discussion',
    this.spaceId,
  });

  final PostService? postService;
  final UploadService? uploadService;
  final ListingService? listingService;
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
  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  final _timeController = TextEditingController();
  final _rewardController = TextEditingController();
  final _notesController = TextEditingController();
  late final PostService _postService;
  late final UploadService _uploadService;
  late final ListingService _listingService;
  final ImagePicker _nativeImagePicker = ImagePicker();
  PickedPostImage? _coverImage;
  bool _submitting = false;

  late String _category = widget.initialCategory;
  final Set<String> _selectedTags = {};
  bool _errand = false;
  String _serviceMode = 'other';
  int _validForDays = 1;

  // Goods fields (offer/wanted without errand).
  final _goodsTitleController = TextEditingController();
  final _goodsBrandController = TextEditingController();
  double _conditionScore = 8;
  final _goodsPriceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _postService = widget.postService ?? context.read<PostService>();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
    _listingService = widget.listingService ?? ListingService();
    if (_category != 'discussion') _errand = true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _pickupController.dispose();
    _dropoffController.dispose();
    _timeController.dispose();
    _rewardController.dispose();
    _notesController.dispose();
    _goodsTitleController.dispose();
    _goodsBrandController.dispose();
    _goodsPriceController.dispose();
    super.dispose();
  }

  bool get _needsGoods =>
      (_category == 'offer' || _category == 'wanted') && !_errand;

  void _toggleTag(String key) {
    setState(() {
      if (_selectedTags.contains(key)) {
        _selectedTags.remove(key);
        if (key == 'errand') {
          _errand = false;
        }
      } else {
        if (_selectedTags.length >= 5) return;
        _selectedTags.add(key);
        if (key == 'errand') {
          _errand = true;
        }
      }
    });
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
      String? listingId;
      if (_needsGoods) {
        listingId = await _listingService.createListing(
          title: _titleController.text.trim(),
          category: 'other',
          brand: _goodsBrandController.text.trim(),
          conditionScore: _conditionScore.round(),
          suggestedPriceCny:
              double.tryParse(_goodsPriceController.text.trim()) ?? 0,
          defects: const [],
          description: _bodyController.text.trim(),
          direction: _category,
          idempotencyKey: const Uuid().v4(),
        );
      }

      final Map<String, dynamic> errandMetadata = _errand
          ? {
              'service_mode': _serviceMode,
              if (_pickupController.text.trim().isNotEmpty)
                'pickup_place': _pickupController.text.trim(),
              if (_dropoffController.text.trim().isNotEmpty)
                'dropoff_place': _dropoffController.text.trim(),
              if (_timeController.text.trim().isNotEmpty)
                'time_hint': _timeController.text.trim(),
              if (int.tryParse(_rewardController.text.trim()) != null)
                'reward_cents': int.parse(_rewardController.text.trim()) * 100,
              if (_notesController.text.trim().isNotEmpty)
                'notes': _notesController.text.trim(),
              'valid_until': DateTime.now()
                  .toUtc()
                  .add(Duration(days: _validForDays))
                  .toIso8601String(),
            }
          : const {};

      final post = await _postService.createPost(
        title: _titleController.text,
        body: _bodyController.text,
        category: _category,
        tags: tags,
        coverImageUrl: coverImageUrl,
        listingId: listingId,
        spaceId: widget.spaceId,
        errandMetadata: errandMetadata,
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
                SegmentedButton<String>(
                  key: const ValueKey('publish-category-segment'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: 'offer',
                      label: Text(l.publishCategoryOffer),
                    ),
                    ButtonSegment(
                      value: 'wanted',
                      label: Text(l.publishCategoryWanted),
                    ),
                    ButtonSegment(
                      value: 'discussion',
                      label: Text(l.publishCategoryDiscussion),
                    ),
                  ],
                  selected: {_category},
                  onSelectionChanged: _submitting
                      ? null
                      : (values) => setState(() {
                          _category = values.first;
                          if (_category == 'discussion') {
                            _selectedTags.remove('errand');
                            _errand = false;
                          }
                        }),
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
                if (_needsGoods) ...[
                  const SizedBox(height: AppTheme.sp14),
                  _buildGoodsSection(l),
                ],
                if (_category != 'discussion') ...[
                  const SizedBox(height: AppTheme.sp14),
                  _buildErrandFields(l),
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
    final visibleTags = _tagCatalog.entries
        .where(
          (entry) =>
              entry.value.categories.isEmpty ||
              entry.value.categories.contains(_category),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.postTagsLabel,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).hintColor,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in visibleTags)
              FilterChip(
                key: ValueKey('publish-tag-${entry.key}'),
                label: Text(entry.value.label),
                selected: _selectedTags.contains(entry.key),
                onSelected: _submitting ? (_) {} : (_) => _toggleTag(entry.key),
              ),
          ],
        ),
      ],
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
          DropdownButtonFormField<String>(
            initialValue: 'other',
            decoration: InputDecoration(labelText: '${l.category} *'),
            items: [
              for (final key in _listingCategoryKeys)
                DropdownMenuItem(
                  value: key,
                  child: Text(localizedCategoryLabel(context, key)),
                ),
            ],
            onChanged: (_) {},
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

  Widget _buildErrandFields(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('publish-errand-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l.publishErrandSwitch),
            value: _errand,
            onChanged: (value) => setState(() {
              _errand = value;
              value
                  ? _selectedTags.add('errand')
                  : _selectedTags.remove('errand');
            }),
          ),
          DropdownButtonFormField<String>(
            initialValue: _serviceMode,
            decoration: InputDecoration(labelText: l.postMutualAidMode),
            items: [
              for (final mode in [
                'pickup',
                'buy',
                'queue',
                'print',
                'return',
                'other',
              ])
                DropdownMenuItem(
                  value: mode,
                  child: Text(mutualAidModeLabel(l, mode)),
                ),
            ],
            onChanged: (value) =>
                setState(() => _serviceMode = value ?? 'other'),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _pickupController,
            maxLength: 120,
            decoration: InputDecoration(labelText: l.postMutualAidPickup),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _dropoffController,
            maxLength: 120,
            decoration: InputDecoration(labelText: l.postMutualAidDropoff),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _timeController,
            maxLength: 120,
            decoration: InputDecoration(labelText: l.postMutualAidTime),
          ),
          const SizedBox(height: AppTheme.sp12),
          TextFormField(
            controller: _rewardController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l.postMutualAidReward),
            validator: (value) {
              final raw = (value ?? '').trim();
              if (raw.isEmpty) return null;
              final yuan = int.tryParse(raw);
              return yuan == null || yuan < 0 || yuan > 100000
                  ? l.postMutualAidRewardInvalid
                  : null;
            },
          ),
          const SizedBox(height: AppTheme.sp12),
          DropdownButtonFormField<int>(
            initialValue: _validForDays,
            decoration: InputDecoration(labelText: l.postMutualAidValidity),
            items: [
              DropdownMenuItem(value: 1, child: Text(l.postMutualAidOneDay)),
              DropdownMenuItem(value: 3, child: Text(l.postMutualAidThreeDays)),
              DropdownMenuItem(value: 7, child: Text(l.postMutualAidSevenDays)),
            ],
            onChanged: (value) => setState(() => _validForDays = value ?? 1),
          ),
        ],
      ),
    );
  }
}
