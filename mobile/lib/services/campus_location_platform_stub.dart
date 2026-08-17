import 'package:flutter/services.dart';

class PlatformLocationFailure implements Exception {
  const PlatformLocationFailure(this.code);

  final String code;
}

Future<({double latitude, double longitude})> readCurrentPosition() async {
  try {
    final raw = await const MethodChannel(
      'goods4ncu/location',
    ).invokeMethod<Map<Object?, Object?>>('getCurrentPosition');
    if (raw == null) throw const PlatformLocationFailure('unavailable');
    final latitude = (raw['latitude'] as num?)?.toDouble();
    final longitude = (raw['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) {
      throw const PlatformLocationFailure('unavailable');
    }
    return (latitude: latitude, longitude: longitude);
  } on PlatformException catch (error) {
    throw PlatformLocationFailure(error.code);
  }
}
