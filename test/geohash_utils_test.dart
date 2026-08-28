import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/geohash_utils.dart';

void main() {
  test('snapToCellCenter removes exact location precision', () {
    const exactLocation = GeoPoint(31.964425, 34.804531);

    final discoveryLocation = GeoHashUtils.snapToCellCenter(
      exactLocation,
      precision: 5,
    );

    expect(discoveryLocation, isNot(equals(exactLocation)));
    expect(
      GeoHashUtils.encodeGeoPoint(discoveryLocation, precision: 5),
      GeoHashUtils.encodeGeoPoint(exactLocation, precision: 5),
    );
  });
}