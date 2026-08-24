import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/post.dart';
import '../services/post_service.dart';
import '../theme/app_theme.dart';

/// 我的发布 — manage every unified post the user authored
/// (offer / wanted / discussion) with edit, lock and delete actions.
class MyPostsPage extends StatefulWidget {
  const MyPostsPage({super.key, this.postService});

  final PostService? postService;

  @override
  State<MyPostsPage> createState() => _MyPostsPageState();
}

class _MyPostsPageState extends State<MyPostsPage> {
  late final PostService _postService;
  List<CampusPost> _posts = [];
  bool _loading = true;
  String? _error;
  String _statusFilter = 'all';

  static const _statusFilters = ['all', 'active', 'locked', 'deleted'];

  @override
  void initState() {
    super.initState();
    _postService = widget.postService ?? context.read<PostService>();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _postService.getUserPosts(
        status: _statusFilter,
        limit: 100,
      );
      if (!mounted) return;
      final items = data['items'] as List<dynamic>? ?? [];
      setState(() {
        _posts = items
            .map(
              (e) => CampusPost.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _deletePost(CampusPost post) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.myPostsDeleteConfirmTitle),
        content: Text(l.myPostsDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _postServiceDelete(post.id);
      if (!mounted) return;
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _postServiceDelete(String id) => _postService.deletePost(id);

  void _openPost(CampusPost post) {
    if (post.category != 'discussion' && post.listingId != null) {
      context.push('/listing/${Uri.encodeComponent(post.listingId!)}');
    } else {
      context.push('/posts/${Uri.encodeComponent(post.id)}');
    }
  }

  String _statusLabel(AppLocalizations l, String status) => switch (status) {
    'locked' => l.postStatusLocked,
    'archived' => l.postStatusArchived,
    'deleted' => l.postStatusDeleted,
    _ => l.postStatusActive,
  };

  Color _statusColor(String status) => switch (status) {
    'active' => AppTheme.primary,
    'locked' => AppTheme.info,
    _ => AppTheme.error,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.myPosts)),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('my-posts-create'),
        onPressed: () => context.push('/publish'),
        icon: const Icon(Icons.add_rounded),
        label: Text(l.postCreateTitle),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final status in _statusFilters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_statusLabel(l, status)),
                      selected: _statusFilter == status,
                      onSelected: (_) {
                        setState(() => _statusFilter = status);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildBody(l)),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: Text(l.retry)),
          ],
        ),
      );
    }
    if (_posts.isEmpty) {
      return Center(child: Text(l.myPostsEmpty));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _posts.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final post = _posts[index];
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: Key('my-post-${post.id}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              onTap: () => _openPost(post),
              title: Text(
                post.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Chip(
                      key: ValueKey('my-post-status-${post.id}'),
                      label: Text(_statusLabel(l, post.status)),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide.none,
                      backgroundColor: _statusColor(
                        post.status,
                      ).withValues(alpha: 0.12),
                      labelStyle: TextStyle(
                        fontSize: 11,
                        color: _statusColor(post.status),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      switch (post.category) {
                        'offer' => l.publishCategoryOffer,
                        'wanted' => l.publishCategoryWanted,
                        _ => l.publishCategoryDiscussion,
                      },
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (post.isErrand) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.directions_run_rounded, size: 14),
                    ],
                  ],
                ),
              ),
              trailing: IconButton(
                key: Key('my-post-delete-${post.id}'),
                tooltip: l.delete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _deletePost(post),
              ),
            ),
          );
        },
      ),
    );
  }
}
