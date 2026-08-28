import 'package:cloud_firestore/cloud_firestore.dart';

class GeoHashUtils {
  static const int defaultPrecision = 9;
  static const String _alphabet = '0123456789bcdefghjkmnpqrstuvwxyz';

  static String encode({
    required double latitude,
    required double longitude,
    int precision = defaultPrecision,
  }) {
    var minLatitude = -90.0;
    var maxLatitude = 90.0;
    var minLongitude = -180.0;
    var maxLongitude = 180.0;
    var isLongitudeTurn = true;
    var bit = 0;
    var charIndex = 0;
    final buffer = StringBuffer();

    while (buffer.length < precision) {
      if (isLongitudeTurn) {
        final midpoint = (minLongitude + maxLongitude) / 2;
        if (longitude >= midpoint) {
          charIndex = (charIndex << 1) | 1;
          minLongitude = midpoint;
        } else {
          charIndex <<= 1;
          maxLongitude = midpoint;
        }
      } else {
        final midpoint = (minLatitude + maxLatitude) / 2;
        if (latitude >= midpoint) {
          charIndex = (charIndex << 1) | 1;
          minLatitude = midpoint;
        } else {
          charIndex <<= 1;
          maxLatitude = midpoint;
        }
      }

      isLongitudeTurn = !isLongitudeTurn;
      bit++;
      if (bit == 5) {
        buffer.write(_alphabet[charIndex]);
        bit = 0;
        charIndex = 0;
      }
    }

    return buffer.toString();
  }

  static String? encodeGeoPoint(
    GeoPoint? point, {
    int precision = defaultPrecision,
  }) {
    if (point == null) {
      return null;
    }

    return encode(
      latitude: point.latitude,
      longitude: point.longitude,
      precision: precision,
    );
  }

  static GeoPoint snapToCellCenter(
    GeoPoint point, {
    required int precision,
  }) {
    final latitudeStep = _latitudeSpanForPrecision(precision);
    final longitudeStep = _longitudeSpanForPrecision(precision);
    final latitudeIndex = ((point.latitude + 90) / latitudeStep).floor();
    final longitudeIndex = ((point.longitude + 180) / longitudeStep).floor();
    return GeoPoint(
      _clampLatitude(-90 + ((latitudeIndex + 0.5) * latitudeStep)),
      _normalizeLongitude(-180 + ((longitudeIndex + 0.5) * longitudeStep)),
    );
  }

  static Set<String> nearbyPrefixes({
    required GeoPoint center,
    required int precision,
  }) {
    final latitudeStep = _latitudeSpanForPrecision(precision) * 1.01;
    final longitudeStep = _longitudeSpanForPrecision(precision) * 1.01;
    final prefixes = <String>{};

    for (var latitudeOffset = -1; latitudeOffset <= 1; latitudeOffset++) {
      for (var longitudeOffset = -1;
          longitudeOffset <= 1;
          longitudeOffset++) {
        prefixes.add(
          encode(
            latitude: _clampLatitude(
              center.latitude + (latitudeStep * latitudeOffset),
            ),
            longitude: _normalizeLongitude(
              center.longitude + (longitudeStep * longitudeOffset),
            ),
            precision: precision,
          ),
        );
      }
    }

    return prefixes;
  }

  static double _latitudeSpanForPrecision(int precision) {
    final totalBits = precision * 5;
    final latitudeBits = totalBits ~/ 2;
    return 180.0 / (1 << latitudeBits);
  }

  static double _longitudeSpanForPrecision(int precision) {
    final totalBits = precision * 5;
    final longitudeBits = (totalBits + 1) ~/ 2;
    return 360.0 / (1 << longitudeBits);
  }

  static double _clampLatitude(double latitude) {
    return latitude.clamp(-89.999999, 89.999999).toDouble();
  }

  static double _normalizeLongitude(double longitude) {
    var normalized = longitude;
    while (normalized < -180.0) {
      normalized += 360.0;
    }
    while (normalized > 180.0) {
      normalized -= 360.0;
    }
    return normalized;
  }
}