import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';

class PresenceService with WidgetsBindingObserver {
  PresenceService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseDatabase? database,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _database = database ??
            FirebaseDatabase.instanceFor(
              app: Firebase.app(),
              databaseURL: 'https://hundred-6c680-default-rtdb.firebaseio.com',
            );

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseDatabase _database;

  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  DatabaseReference? _statusRef;
  bool _started = false;
  String? _activeUid;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await _bindCurrentUser();
  }

  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    await _setOffline();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _statusRef = null;
    _activeUid = null;
    _started = false;
  }

  Future<void> refresh() async {
    await _bindCurrentUser(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) {
      return;
    }

    if (state == AppLifecycleState.resumed) {
      unawaited(_setOnline());
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_setOffline());
    }
  }

  Future<void> _bindCurrentUser({bool force = false}) async {
    final uid = _auth.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      await _setOffline();
      return;
    }

    if (!force && _activeUid == uid && _statusRef != null) {
      return;
    }

    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _activeUid = uid;
    _statusRef = _database.ref('status/$uid');

    final connectedRef = _database.ref('.info/connected');
    _connectionSubscription = connectedRef.onValue.listen((event) async {
      final isConnected = event.snapshot.value as bool? ?? false;
      if (!isConnected) {
        await _setOffline();
        return;
      }

      final statusRef = _statusRef;
      if (statusRef == null) {
        return;
      }

      await statusRef.onDisconnect().update({
        'state': 'offline',
        'lastChanged': ServerValue.timestamp,
      });
      await _setOnline();
    });
  }

  Future<void> _setOnline() async {
    final uid = _activeUid;
    final statusRef = _statusRef;
    if (uid == null || uid.isEmpty || statusRef == null) {
      return;
    }

    final now = DateTime.now();
    await statusRef.set({
      'state': 'online',
      'lastChanged': ServerValue.timestamp,
    });
    await _syncFirestorePresence(
      uid: uid,
      isOnline: true,
      lastSeen: now,
    );
  }

  Future<void> _setOffline() async {
    final uid = _activeUid;
    final statusRef = _statusRef;
    if (uid == null || uid.isEmpty || statusRef == null) {
      return;
    }

    final now = DateTime.now();
    await statusRef.set({
      'state': 'offline',
      'lastChanged': ServerValue.timestamp,
    });
    await _syncFirestorePresence(
      uid: uid,
      isOnline: false,
      lastSeen: now,
    );
  }

  Future<void> _syncFirestorePresence({
    required String uid,
    required bool isOnline,
    required DateTime lastSeen,
  }) async {
    final payload = <String, dynamic>{
      'isOnline': isOnline,
      'lastSeen': Timestamp.fromDate(lastSeen.toUtc()),
      'presenceUpdatedAt': FieldValue.serverTimestamp(),
    };

    await Future.wait([
      _firestore.collection('users').doc(uid).set(payload, SetOptions(merge: true)),
      _firestore.collection('users_public').doc(uid).set(payload, SetOptions(merge: true)),
    ]);
  }
}
