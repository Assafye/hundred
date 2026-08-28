import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import 'geohash_utils.dart';

class LocationService with WidgetsBindingObserver {
  static const Duration _activeMeetNowPostLifetime = Duration(hours: 24);
  static const int _meetNowDiscoveryPrecision = 5;

  LocationService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Position? _lastPosition;
  DateTime? _lastSyncAt;
  bool _started = false;
  bool _syncInFlight = false;

  Future<void> _syncActiveMeetNowPostsLocation({
    required String uid,
    required GeoPoint geoPoint,
  }) async {
    final authoredPosts =
        await _firestore.collection('meet_now_posts').where('authorUid', isEqualTo: uid).get();
    if (authoredPosts.docs.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final discoveryGeo = GeoHashUtils.snapToCellCenter(
      geoPoint,
      precision: _meetNowDiscoveryPrecision,
    );
    final geohash = GeoHashUtils.encodeGeoPoint(
      discoveryGeo,
      precision: _meetNowDiscoveryPrecision,
    );
    WriteBatch? batch;
    var writesInBatch = 0;

    Future<void> commitBatchIfNeeded({bool force = false}) async {
      if (batch == null || writesInBatch == 0) {
        return;
      }
      if (!force && writesInBatch < 450) {
        return;
      }

      final batchToCommit = batch!;
      batch = null;
      writesInBatch = 0;
      await batchToCommit.commit();
    }

    for (final doc in authoredPosts.docs) {
      final data = doc.data();
      final status = (data['status'] as String? ?? 'active').trim().toLowerCase();
      if (status != 'active') {
        continue;
      }

      final createdAt = data['createdAt'];
      final createdAtDate = createdAt is Timestamp
          ? createdAt.toDate()
          : createdAt is DateTime
              ? createdAt
              : null;
      if (createdAtDate != null &&
          now.difference(createdAtDate) > _activeMeetNowPostLifetime) {
        continue;
      }

      batch ??= _firestore.batch();
      batch!.set(doc.reference, {
        'geo': FieldValue.delete(),
        'latitude': FieldValue.delete(),
        'longitude': FieldValue.delete(),
        'discoveryGeo': discoveryGeo,
        'geohash': geohash,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      writesInBatch += 1;
      await commitBatchIfNeeded();
    }

    await commitBatchIfNeeded(force: true);
  }

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await syncCurrentLocation(force: true);
  }

  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(syncCurrentLocation());
    }
  }

  Future<void> syncCurrentLocation({bool force = false}) async {
    if (_syncInFlight) {
      return;
    }

    final uid = _auth.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      return;
    }

    final lastSyncAt = _lastSyncAt;
    if (!force && lastSyncAt != null) {
      final secondsSinceLastSync =
          DateTime.now().difference(lastSyncAt).inSeconds;
      if (secondsSinceLastSync < 90) {
        return;
      }
    }

    _syncInFlight = true;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 25,
        ),
      );

      if (!force && _lastPosition != null) {
        final distance = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        if (distance < 20) {
          _lastSyncAt = DateTime.now();
          return;
        }
      }

      _lastPosition = position;
      _lastSyncAt = DateTime.now();
      final geoPoint = GeoPoint(position.latitude, position.longitude);

      final exactLocationPayload = <String, dynamic>{
        'geo': geoPoint,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'locationUpdatedAt': FieldValue.serverTimestamp(),
      };

      await Future.wait([
        _firestore
            .collection('users')
            .doc(uid)
            .set({
          'geo': FieldValue.delete(),
          'latitude': FieldValue.delete(),
          'longitude': FieldValue.delete(),
          'locationUpdatedAt': FieldValue.delete(),
        }, SetOptions(merge: true)),
        _firestore
            .collection('users')
            .doc(uid)
            .collection('private')
            .doc('location')
            .set(exactLocationPayload, SetOptions(merge: true)),
        _firestore.collection('users_public').doc(uid).set(
          {
            'geo': FieldValue.delete(),
            'latitude': FieldValue.delete(),
            'longitude': FieldValue.delete(),
            'locationUpdatedAt': FieldValue.delete(),
          },
          SetOptions(merge: true),
        ),
        _syncActiveMeetNowPostsLocation(uid: uid, geoPoint: geoPoint),
      ]);
    } catch (error) {
      debugPrint('[LocationService] sync failed: $error');
    } finally {
      _syncInFlight = false;
    }
  }

  double? distanceInMeters({
    required GeoPoint? from,
    required GeoPoint? to,
  }) {
    if (from == null || to == null) {
      return null;
    }
    return Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
  }
}
