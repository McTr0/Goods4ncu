import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/post_service.dart';
import '../services/upload_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

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

class CreatePostPage extends StatefulWidget {
  const CreatePostPage({
    super.key,
    this.postService,
    this.uploadService,
    this.imagePicker,
  });

  final PostService? postService;
  final UploadService? uploadService;
  final PostImagePicker? imagePicker;

  @override
  State<CreatePostPage> createState() => _CreatePostPageState();
}

class _CreatePostPageState extends State<CreatePostPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _categoryController = TextEditingController();
  final _tagsController = TextEditingController();
  late final PostService _postService;
  late final UploadService _uploadService;
  final ImagePicker _nativeImagePicker = ImagePicker();
  PickedPostImage? _coverImage;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _postService = widget.postService ?? context.read<PostService>();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _categoryController.dispose();
    _tagsController.dispose();
    super.dispose();
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
      final post = await _postService.createPost(
        title: _titleController.text,
        body: _bodyController.text,
        category: _categoryController.text,
        tags: _tagsController.text
            .split(RegExp(r'[,，\s]+'))
            .map((tag) => tag.replaceFirst(RegExp(r'^#'), '').trim())
            .where((tag) => tag.isNotEmpty)
            .toSet()
            .take(5)
            .toList(growable: false),
        coverImageUrl: coverImageUrl,
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
    final scheme = Theme.of(context).colorScheme;
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
                Container(
                  padding: const EdgeInsets.all(AppTheme.sp16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.forum_outlined, color: scheme.primary),
                      const SizedBox(width: AppTheme.sp12),
                      Expanded(
                        child: Text(
                          l.postCreateIntro,
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.sp20),
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
                          Positioned(
                            left: AppTheme.sp12,
                            bottom: AppTheme.sp12,
                            child: FilledButton.tonalIcon(
                              onPressed: _submitting ? null : _pickCoverImage,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: Text(l.createListingChangeImage),
                            ),
                          ),
                        ],
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
                  minLines: 8,
                  maxLines: 18,
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
                TextFormField(
                  key: const ValueKey('post-category-field'),
                  controller: _categoryController,
                  maxLength: 50,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.postCategoryLabel,
                    hintText: l.postCategoryHint,
                  ),
                ),
                const SizedBox(height: AppTheme.sp14),
                TextFormField(
                  key: const ValueKey('post-tags-field'),
                  controller: _tagsController,
                  maxLength: 100,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: l.postTagsLabel,
                    hintText: l.postTagsHint,
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
}
