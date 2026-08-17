import 'campus_location_platform_stub.dart'
    if (dart.library.html) 'campus_location_platform_web.dart'
    as platform;

class CoarseCampusPosition {
  const CoarseCampusPosition({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

enum CampusLocationFailure {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  unavailable,
}

class CampusLocationException implements Exception {
  const CampusLocationException(this.failure);

  final CampusLocationFailure failure;
}

/// Reads one low-accuracy position and immediately rounds it before returning.
/// Callers send only this coarse value and never persist it locally.
class CampusLocationService {
  Future<CoarseCampusPosition> determineCoarsePosition() async {
    try {
      final position = await platform.readCurrentPosition();
      return CoarseCampusPosition(
        latitude: _roundToThreeDecimals(position.latitude),
        longitude: _roundToThreeDecimals(position.longitude),
      );
    } on platform.PlatformLocationFailure catch (error) {
      throw CampusLocationException(_mapFailure(error.code));
    } catch (_) {
      throw const CampusLocationException(CampusLocationFailure.unavailable);
    }
  }

  double _roundToThreeDecimals(double value) =>
      (value * 1000).roundToDouble() / 1000;

  CampusLocationFailure _mapFailure(String code) {
    switch (code) {
      case 'service_disabled':
        return CampusLocationFailure.serviceDisabled;
      case 'permission_denied_forever':
        return CampusLocationFailure.permissionDeniedForever;
      case 'permission_denied':
        return CampusLocationFailure.permissionDenied;
      default:
        return CampusLocationFailure.unavailable;
    }
  }
}
