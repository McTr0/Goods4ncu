import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/campus_location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('goods4ncu/location');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('returns only a coarse three-decimal position', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCurrentPosition');
      return <String, double>{'latitude': 28.662234, 'longitude': 115.801876};
    });

    final position = await CampusLocationService().determineCoarsePosition();

    expect(position.latitude, 28.662);
    expect(position.longitude, 115.802);
  });

  test('maps a permanently denied platform permission', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'permission_denied_forever');
    });

    expect(
      CampusLocationService().determineCoarsePosition(),
      throwsA(
        isA<CampusLocationException>().having(
          (error) => error.failure,
          'failure',
          CampusLocationFailure.permissionDeniedForever,
        ),
      ),
    );
  });
}
