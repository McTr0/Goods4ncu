import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class PlatformLocationFailure implements Exception {
  const PlatformLocationFailure(this.code);

  final String code;
}

Future<({double latitude, double longitude})> readCurrentPosition() async {
  final completer = Completer<({double latitude, double longitude})>();
  try {
    web.window.navigator.geolocation.getCurrentPosition(
      ((web.GeolocationPosition position) {
        if (completer.isCompleted) return;
        completer.complete((
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        ));
      }).toJS,
      ((web.GeolocationPositionError error) {
        if (completer.isCompleted) return;
        completer.completeError(
          PlatformLocationFailure(
            error.code == web.GeolocationPositionError.PERMISSION_DENIED
                ? 'permission_denied'
                : 'unavailable',
          ),
        );
      }).toJS,
      web.PositionOptions(
        enableHighAccuracy: false,
        timeout: 12000,
        maximumAge: 0,
      ),
    );
    return await completer.future;
  } catch (error) {
    if (error is PlatformLocationFailure) rethrow;
    throw const PlatformLocationFailure('unavailable');
  }
}
