import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/watchlist_page.dart';
import 'package:goods4ncu_mobile/services/watchlist_service.dart';

class _StubWatchlistService extends WatchlistService {
  _StubWatchlistService({required this.onGetWatchlist, this.onRemove});

  final Future<WatchlistResponse> Function(int limit, int offset)
  onGetWatchlist;
  final Future<void> Function(String listingId)? onRemove;
  final List<int> requestedOffsets = [];
  final List<String> addedIds = [];
  final List<String> removedIds = [];

  @override
  Future<WatchlistResponse> getWatchlist({int limit = 20, int offset = 0}) {
    requestedOffsets.add(offset);
    return onGetWatchlist(limit, offset);
  }

  @override
  Future<void> addToWatchlist(String listingId) async {
    addedIds.add(listingId);
  }

  @override
  Future<void> removeFromWatchlist(String listingId) async {
    removedIds.add(listingId);
    if (onRemove != null) {
      await onRemove!(listingId);
    }
  }
}

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('WatchlistPage', () {
    testWidgets('shows watchlist items after successful load', (tester) async {
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async => WatchlistResponse(
          items: const [
            WatchlistItem(
              listingId: 'listing-1',
              title: 'MacBook Air',
              category: 'electronics',
              brand: 'Apple',
              conditionScore: 8,
              suggestedPriceCny: 5999,
              status: 'active',
              ownerId: 'owner-1',
              createdAt: '2026-03-01T08:00:00Z',
            ),
          ],
          total: 1,
          limit: 20,
          offset: 0,
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text('MacBook Air'), findsOneWidget);
      expect(find.text(l.watchlistEmpty), findsNothing);
    });

    testWidgets('shows retry on initial load error', (tester) async {
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async {
          throw Exception('network down');
        },
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text(l.retry), findsOneWidget);
    });

    testWidgets('loads next page when tapping Load more', (tester) async {
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async {
          if (offset == 0) {
            return const WatchlistResponse(
              items: [
                WatchlistItem(
                  listingId: 'listing-1',
                  title: 'MacBook Air',
                  category: 'electronics',
                  brand: 'Apple',
                  conditionScore: 8,
                  suggestedPriceCny: 5999,
                  status: 'active',
                  ownerId: 'owner-1',
                  createdAt: '2026-03-01T08:00:00Z',
                ),
              ],
              total: 2,
              limit: 20,
              offset: 0,
            );
          }
          return const WatchlistResponse(
            items: [
              WatchlistItem(
                listingId: 'listing-2',
                title: 'Kindle',
                category: 'electronics',
                brand: 'Amazon',
                conditionScore: 7,
                suggestedPriceCny: 499,
                status: 'active',
                ownerId: 'owner-2',
                createdAt: '2026-03-02T08:00:00Z',
              ),
            ],
            total: 2,
            limit: 20,
            offset: 1,
          );
        },
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text('MacBook Air'), findsOneWidget);
      expect(find.text(l.loadMore), findsOneWidget);

      await tester.tap(find.text(l.loadMore));
      await tester.pumpAndSettle();

      expect(service.requestedOffsets, [0, 1]);
      expect(find.text('Kindle'), findsOneWidget);
    });

    testWidgets('shows retry footer after pagination error', (tester) async {
      int nextPageAttempts = 0;
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async {
          if (offset == 0) {
            return const WatchlistResponse(
              items: [
                WatchlistItem(
                  listingId: 'listing-1',
                  title: 'MacBook Air',
                  category: 'electronics',
                  brand: 'Apple',
                  conditionScore: 8,
                  suggestedPriceCny: 5999,
                  status: 'active',
                  ownerId: 'owner-1',
                  createdAt: '2026-03-01T08:00:00Z',
                ),
              ],
              total: 2,
              limit: 20,
              offset: 0,
            );
          }

          nextPageAttempts += 1;
          if (nextPageAttempts == 1) {
            throw Exception('next page failed');
          }

          return const WatchlistResponse(
            items: [
              WatchlistItem(
                listingId: 'listing-2',
                title: 'Kindle',
                category: 'electronics',
                brand: 'Amazon',
                conditionScore: 7,
                suggestedPriceCny: 499,
                status: 'active',
                ownerId: 'owner-2',
                createdAt: '2026-03-02T08:00:00Z',
              ),
            ],
            total: 2,
            limit: 20,
            offset: 1,
          );
        },
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.text(l.loadMore));
      await tester.pumpAndSettle();

      expect(find.text(l.retry), findsOneWidget);

      await tester.tap(find.text(l.retry).last);
      await tester.pumpAndSettle();

      expect(find.text('Kindle'), findsOneWidget);
    });

    testWidgets('canceling remove dialog keeps item untouched', (tester) async {
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async => const WatchlistResponse(
          items: [
            WatchlistItem(
              listingId: 'listing-1',
              title: 'MacBook Air',
              category: 'electronics',
              brand: 'Apple',
              conditionScore: 8,
              suggestedPriceCny: 5999,
              status: 'active',
              ownerId: 'owner-1',
              createdAt: '2026-03-01T08:00:00Z',
            ),
          ],
          total: 1,
          limit: 20,
          offset: 0,
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pumpAndSettle();

      expect(find.text(l.removeFavoriteConfirm), findsOneWidget);

      await tester.tap(find.text(l.cancel));
      await tester.pumpAndSettle();

      expect(service.removedIds, isEmpty);
      expect(find.text('MacBook Air'), findsOneWidget);
    });

    testWidgets('remove with undo restores item', (tester) async {
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async => const WatchlistResponse(
          items: [
            WatchlistItem(
              listingId: 'listing-1',
              title: 'MacBook Air',
              category: 'electronics',
              brand: 'Apple',
              conditionScore: 8,
              suggestedPriceCny: 5999,
              status: 'active',
              ownerId: 'owner-1',
              createdAt: '2026-03-01T08:00:00Z',
            ),
          ],
          total: 1,
          limit: 20,
          offset: 0,
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(ElevatedButton, l.delete),
        ),
      );
      await tester.pumpAndSettle();

      expect(service.removedIds, ['listing-1']);
      expect(find.text('MacBook Air'), findsNothing);
      expect(find.text(l.undo), findsOneWidget);

      await tester.tap(find.text(l.undo));
      await tester.pumpAndSettle();

      expect(service.addedIds, ['listing-1']);
      expect(find.text('MacBook Air'), findsOneWidget);
    });

    testWidgets('remove completion after dispose does not throw', (
      tester,
    ) async {
      final removeCompleter = Completer<void>();
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async => const WatchlistResponse(
          items: [
            WatchlistItem(
              listingId: 'listing-1',
              title: 'MacBook Air',
              category: 'electronics',
              brand: 'Apple',
              conditionScore: 8,
              suggestedPriceCny: 5999,
              status: 'active',
              ownerId: 'owner-1',
              createdAt: '2026-03-01T08:00:00Z',
            ),
          ],
          total: 1,
          limit: 20,
          offset: 0,
        ),
        onRemove: (_) => removeCompleter.future,
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(ElevatedButton, l.delete),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      removeCompleter.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores duplicate remove while request is pending', (
      tester,
    ) async {
      final removeCompleter = Completer<void>();
      final service = _StubWatchlistService(
        onGetWatchlist: (limit, offset) async => const WatchlistResponse(
          items: [
            WatchlistItem(
              listingId: 'listing-1',
              title: 'MacBook Air',
              category: 'electronics',
              brand: 'Apple',
              conditionScore: 8,
              suggestedPriceCny: 5999,
              status: 'active',
              ownerId: 'owner-1',
              createdAt: '2026-03-01T08:00:00Z',
            ),
          ],
          total: 1,
          limit: 20,
          offset: 0,
        ),
        onRemove: (_) => removeCompleter.future,
      );

      await tester.pumpWidget(
        _buildTestApp(WatchlistPage(watchlistService: service)),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(ElevatedButton, l.delete),
        ),
      );
      await tester.pump();

      expect(service.removedIds, ['listing-1']);

      final iconButton = tester.widget<IconButton>(
        find.byType(IconButton).first,
      );
      expect(iconButton.onPressed, isNull);

      removeCompleter.complete();
      await tester.pumpAndSettle();

      expect(service.removedIds, ['listing-1']);
    });
  });
}
