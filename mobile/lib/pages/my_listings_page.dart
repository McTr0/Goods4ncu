import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../components/price_tag.dart';
import '../components/shimmer_grid.dart';

class MyListingsPage extends StatefulWidget {
  final ApiService? apiService;

  const MyListingsPage({super.key, this.apiService});

  @override
  State<MyListingsPage> createState() => _MyListingsPageState();
}

class _MyListingsPageState extends State<MyListingsPage> {
  late final ApiService _apiService;

  List<Listing> _listings = [];
  bool _loading = true;
  String? _error;
  String _directionFilter = 'all';

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _apiService.getUserListings();
      final items = data['items'] as List<dynamic>?;
      if (mounted) {
        setState(() {
          _listings = items?.map((e) => Listing.fromJson(e)).toList() ?? [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.myListings)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const ShimmerGrid();

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: Text(l.retry)),
          ],
        ),
      );
    }

    if (_listings.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 64,
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l.noProducts,
              style: const TextStyle(
                fontSize: 16,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.go('/create'),
              icon: const Icon(Icons.add),
              label: Text(l.createListing),
            ),
          ],
        ),
      );
    }

    final visibleListings = _listings.where((listing) {
      if (_directionFilter == 'all') return true;
      return listing.direction == _directionFilter;
    }).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.sp16,
                AppTheme.sp16,
                AppTheme.sp16,
                0,
              ),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'all',
                    label: Text(l.listingDirectionAll),
                  ),
                  ButtonSegment(
                    value: 'offer',
                    label: Text(l.listingDirectionOffer),
                  ),
                  ButtonSegment(
                    value: 'wanted',
                    label: Text(l.listingDirectionWanted),
                  ),
                ],
                selected: {_directionFilter},
                onSelectionChanged: (values) =>
                    setState(() => _directionFilter = values.first),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(AppTheme.sp16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.72,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: visibleListings.length,
              itemBuilder: (context, i) {
                final listing = visibleListings[i];
                return ListingCard(
                  listing: listing,
                  onTap: () => context.push('/listing/${listing.id}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
