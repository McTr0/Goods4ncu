import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../components/user_avatar.dart';
import '../models/models.dart';
import '../services/admin_role_cache.dart';
import '../services/token_storage.dart';
import '../theme/app_theme.dart';
import '../utils/category_utils.dart';
import 'login_page.dart';

class UserCenterPage extends StatefulWidget {
  final UserService? userService;

  const UserCenterPage({super.key, this.userService});

  @override
  State<UserCenterPage> createState() => _UserCenterPageState();
}

class _UserCenterPageState extends State<UserCenterPage> {
  late final UserService _userService;
  String _username = '';
  String _createdAt = '';
  SocialPersona? _persona;
  List<dynamic> _listings = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _userService = widget.userService ?? context.read<UserService>();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final profile = await _userService.getUserProfile();
      final listings = await _userService.getUserListings();
      SocialPersona? persona;
      try {
        persona = await _userService.getSocialPersona();
      } catch (_) {
        // The default system Avatar remains available if persona loading fails.
      }

      if (mounted) {
        setState(() {
          _username = profile['username'] ?? '';
          _createdAt = profile['created_at'] ?? '';
          _persona = persona;
          _listings = listings['items'] ?? [];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        // If 401, the BaseService interceptor handles redirect
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load data: $e')));
      }
    }
  }

  Future<void> _logout() async {
    AdminRoleCache.instance.invalidate();
    await TokenStorage.instance.clearTokens();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Center'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: EdgeInsets.all(AppTheme.sp16),
                children: [
                  // Profile Card
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          UserAvatar(
                            name: _username,
                            persona: _persona,
                            size: 64,
                            semanticLabel: _username,
                          ),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _username,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Joined: $_createdAt',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp32),

                  // My Listings Header
                  Row(
                    children: [
                      const Icon(
                        Icons.inventory_2_outlined,
                        size: AppTheme.sp20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'My Listings (${_listings.length})',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Listings
                  if (_listings.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Icon(
                              Icons.inbox_outlined,
                              size: 48,
                              color: AppTheme.textSecondary,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'No listings yet',
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Use the chat to post your first item!',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._listings.map(
                      (item) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const Icon(
                            Icons.shopping_bag_outlined,
                            color: AppTheme.primary,
                          ),
                          title: Text(item['title'] ?? 'Untitled'),
                          subtitle: Text(
                            '${localizedCategoryLabel(context, item['category']?.toString())} · ${item['brand']} · ¥${item['suggested_price_cny']}',
                          ),
                          trailing: Chip(
                            label: Text(
                              item['status'] ?? 'active',
                              style: const TextStyle(fontSize: 11),
                            ),
                            backgroundColor: AppTheme.success.withValues(
                              alpha: 0.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
