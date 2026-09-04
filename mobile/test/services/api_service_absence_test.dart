import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:goods4ncu_mobile/providers/service_providers.dart';
import 'package:goods4ncu_mobile/services/admin_impersonation_service.dart';
import 'package:goods4ncu_mobile/services/admin_service.dart';
import 'package:goods4ncu_mobile/services/agreement_service.dart';
import 'package:goods4ncu_mobile/services/auth_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/content_report_service.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:goods4ncu_mobile/services/negotiate_service.dart';
import 'package:goods4ncu_mobile/services/notification_service.dart';
import 'package:goods4ncu_mobile/services/order_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/price_discovery_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/services/reputation_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:goods4ncu_mobile/services/watchlist_service.dart';

void main() {
  group('ApiService Absence & Domain Service Decoupling', () {
    testWidgets(
      'provides modular domain services directly without legacy ApiService',
      (tester) async {
        late BuildContext capturedContext;

        await tester.pumpWidget(
          MultiProvider(
            providers: serviceProviders,
            child: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        // Verify all domain services are directly accessible via DI
        expect(capturedContext.read<AuthService>(), isA<AuthService>());
        expect(capturedContext.read<ListingService>(), isA<ListingService>());
        expect(capturedContext.read<ChatService>(), isA<ChatService>());
        expect(capturedContext.read<IntentService>(), isA<IntentService>());
        expect(
          capturedContext.read<PriceDiscoveryService>(),
          isA<PriceDiscoveryService>(),
        );
        expect(
          capturedContext.read<AgreementService>(),
          isA<AgreementService>(),
        );
        expect(
          capturedContext.read<ReputationService>(),
          isA<ReputationService>(),
        );
        expect(capturedContext.read<AdminService>(), isA<AdminService>());
        expect(
          capturedContext.read<RecommendationService>(),
          isA<RecommendationService>(),
        );
        expect(capturedContext.read<UploadService>(), isA<UploadService>());
        expect(
          capturedContext.read<NegotiateService>(),
          isA<NegotiateService>(),
        );
        expect(capturedContext.read<UserService>(), isA<UserService>());
        expect(
          capturedContext.read<WatchlistService>(),
          isA<WatchlistService>(),
        );
        expect(
          capturedContext.read<NotificationService>(),
          isA<NotificationService>(),
        );
        expect(capturedContext.read<OrderService>(), isA<OrderService>());
        expect(
          capturedContext.read<ContentReportService>(),
          isA<ContentReportService>(),
        );
        expect(
          capturedContext.read<FeedFeedbackService>(),
          isA<FeedFeedbackService>(),
        );
        expect(capturedContext.read<PostService>(), isA<PostService>());
        expect(
          capturedContext.read<AdminImpersonationService>(),
          isA<AdminImpersonationService>(),
        );

        // Verify provider list contains exactly the expected domain providers
        final providerTypes = serviceProviders
            .map((p) => p.runtimeType.toString())
            .toList();
        expect(
          providerTypes.any((t) => t.contains('ApiService')),
          isFalse,
          reason: 'ApiService must not be present in serviceProviders',
        );
      },
    );
  });
}
