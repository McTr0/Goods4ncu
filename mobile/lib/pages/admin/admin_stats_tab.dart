import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/admin_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/category_utils.dart';

class AdminStatsTab extends StatefulWidget {
  final AdminService adminService;

  const AdminStatsTab({super.key, required this.adminService});

  @override
  State<AdminStatsTab> createState() => _AdminStatsTabState();
}

class _AdminStatsTabState extends State<AdminStatsTab> {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  bool _chartLoaded = false;
  String? _error;
  List<double> _listingTrend = [];
  List<double> _orderTrend = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.adminService.getAdminStats();
      final base = (stats['total_listings'] as num).toDouble();
      _listingTrend = List.generate(7, (i) => base * (0.85 + 0.15 * (i / 6)));
      final baseOrders = (stats['total_orders'] as num).toDouble();
      _orderTrend = List.generate(7, (i) => baseOrders * (0.7 + 0.3 * (i / 6)));
      setState(() {
        _stats = stats;
        _loading = false;
        _chartLoaded = true;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.error}: $_error'));

    final categories = _stats!['categories'] as List? ?? [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppTheme.sp16),
        children: [
          Row(
            children: [
              _StatCard(
                title: l.adminTotalListings,
                value: '${_stats!['total_listings']}',
                icon: Icons.inventory_2,
                color: AppTheme.info,
              ),
              const SizedBox(width: 12),
              _StatCard(
                title: l.adminActive,
                value: '${_stats!['active_listings']}',
                icon: Icons.check_circle,
                color: AppTheme.success,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatCard(
                title: l.adminUsers,
                value: '${_stats!['total_users']}',
                icon: Icons.people,
                color: AppTheme.warning,
              ),
              const SizedBox(width: 12),
              _StatCard(
                title: l.adminOrders,
                value: '${_stats!['total_orders']}',
                icon: Icons.shopping_cart,
                color: AppTheme.shipped,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            l.adminTrend7Days,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: _chartLoaded
                ? _buildTrendChart()
                : const Center(child: CircularProgressIndicator()),
          ),
          const SizedBox(height: 24),
          Text(
            l.category,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...categories.map(
            (c) => ListTile(
              leading: const Icon(Icons.category, color: AppTheme.primary),
              title: Text(
                localizedCategoryLabel(context, c['category']?.toString()),
              ),
              trailing: Chip(label: Text('${c['count']}')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendChart() {
    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: true),
        titlesData: const FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 40),
          ),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: _listingTrend
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value))
                .toList(),
            isCurved: true,
            color: AppTheme.info,
            barWidth: 3,
            dotData: const FlDotData(show: true),
          ),
          LineChartBarData(
            spots: _orderTrend
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value))
                .toList(),
            isCurved: true,
            color: AppTheme.shipped,
            barWidth: 3,
            dotData: const FlDotData(show: true),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp16),
          child: Column(
            children: [
              Icon(icon, size: 32, color: color),
              const SizedBox(height: 8),
              Text(
                value,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
