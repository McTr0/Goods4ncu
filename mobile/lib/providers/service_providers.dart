import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import '../services/intent_service.dart';
import '../services/price_discovery_service.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/listing_service.dart';
import '../services/chat_service.dart';
import '../services/admin_service.dart';
import '../services/admin_impersonation_service.dart';
import '../services/negotiate_service.dart';
import '../services/user_service.dart';
import '../services/watchlist_service.dart';
import '../services/notification_service.dart';
import '../services/order_service.dart';
import '../services/recommendation_service.dart';
import '../services/upload_service.dart';

/// All service providers for dependency injection.
/// Pages can use these directly for better testability,
/// or continue using ApiService for backward compatibility.
List<SingleChildWidget> get serviceProviders => [
  Provider<ApiService>(create: (_) => ApiService()),
  Provider<AuthService>(create: (_) => AuthService()),
  Provider<ListingService>(create: (_) => ListingService()),
  Provider<ChatService>(create: (_) => ChatService()),
  Provider<IntentService>(create: (_) => IntentService()),
  Provider<PriceDiscoveryService>(create: (_) => PriceDiscoveryService()),
  Provider<AdminService>(create: (_) => AdminService()),
  Provider<RecommendationService>(create: (_) => RecommendationService()),
  Provider<UploadService>(create: (_) => UploadService()),
  Provider<NegotiateService>(create: (_) => NegotiateService()),
  Provider<UserService>(create: (_) => UserService()),
  Provider<WatchlistService>(create: (_) => WatchlistService()),
  Provider<NotificationService>(create: (_) => NotificationService()),
  Provider<OrderService>(create: (_) => OrderService()),
  Provider<AdminImpersonationService>(
    create: (context) =>
        AdminImpersonationService(apiService: context.read<ApiService>()),
  ),
];
