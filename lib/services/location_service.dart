import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

class LocationService with WidgetsBindingObserver {
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
      final secondsSinceLastSync = DateTime.now().difference(lastSyncAt).inSeconds;
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

      final payload = <String, dynamic>{
        'geo': GeoPoint(position.latitude, position.longitude),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'locationUpdatedAt': FieldValue.serverTimestamp(),
      };

      await Future.wait([
        _firestore.collection('users').doc(uid).set(payload, SetOptions(merge: true)),
        _firestore.collection('users_public').doc(uid).set(payload, SetOptions(merge: true)),
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
