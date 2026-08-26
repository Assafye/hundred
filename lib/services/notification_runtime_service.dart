import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_navigation_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!Firebase.apps.isNotEmpty) {
    await Firebase.initializeApp();
  }

  await NotificationRuntimeService.handleBackgroundMessage(message);
}

class InAppNotificationEvent {
  final String id;
  final String title;
  final String body;
  final Map<String, dynamic> data;

  const InAppNotificationEvent({
    required this.id,
    required this.title,
    required this.body,
    required this.data,
  });
}

class NotificationRuntimeService with WidgetsBindingObserver {
  NotificationRuntimeService._();

  static final NotificationRuntimeService instance =
      NotificationRuntimeService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  final StreamController<InAppNotificationEvent> _inAppEventsController =
      StreamController<InAppNotificationEvent>.broadcast();

  Stream<InAppNotificationEvent> get inAppEvents =>
      _inAppEventsController.stream;

  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    final title = (message.notification?.title ?? '').trim();
    final body = (message.notification?.body ?? '').trim();
    final payload = Map<String, dynamic>.from(message.data);

    if (title.isEmpty && body.isEmpty) {
      return;
    }

    final localPlugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentSound: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await localPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) async {
        final payloadStr = response.payload;
        if (payloadStr == null || payloadStr.trim().isEmpty) {
          return;
        }
        try {
          final decoded = jsonDecode(payloadStr) as Map<String, dynamic>;
          await NotificationNavigationService.openFromData(decoded);
        } catch (_) {
          // Swallow malformed payloads.
        }
      },
    );

    await localPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'hundred_notifications',
            'Hundred Notifications',
            description: 'Heads-up notifications for user activity and challenges',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );

    final id = 'background_${message.messageId ?? DateTime.now().microsecondsSinceEpoch}';
    final notificationData = <String, dynamic>{...payload, 'title': title, 'body': body};
    await localPlugin.show(
      id.hashCode,
      title.isEmpty ? 'Hundred' : title,
      body.isEmpty ? 'You have a new update' : body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'hundred_notifications',
          'Hundred Notifications',
          channelDescription: 'Heads-up notifications for user activity and challenges',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'Hundred',
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: jsonEncode(notificationData),
    );
  }

  StreamSubscription<User?>? _authSub;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onMessageOpenedAppSub;
  StreamSubscription<String>? _onTokenRefreshSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _notificationsSub;
  String _activeUid = '';
  final Set<String> _knownDocIds = <String>{};
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentSound: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) async {
        final payload = response.payload;
        if (payload == null || payload.trim().isEmpty) {
          return;
        }

        try {
          final decoded = jsonDecode(payload) as Map<String, dynamic>;
          await NotificationNavigationService.openFromData(decoded);
        } catch (_) {
          // Swallow malformed payloads.
        }
      },
    );

    const channel = AndroidNotificationChannel(
      'hundred_notifications',
      'Hundred Notifications',
      description: 'Heads-up notifications for user activity and challenges',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    final permission = await _messaging.requestPermission(alert: true, badge: true, sound: true);
    debugPrint('FCM permission status: ${permission.authorizationStatus.name}');
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    _onMessageSub = FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      final title = (notification?.title ?? '').trim();
      final body = (notification?.body ?? '').trim();
      final payload = Map<String, dynamic>.from(message.data);
      if (title.isEmpty && body.isEmpty) {
        return;
      }

      if (_lifecycleState == AppLifecycleState.resumed) {
        _inAppEventsController.add(
          InAppNotificationEvent(
            id: 'remote_${DateTime.now().microsecondsSinceEpoch}',
            title: title,
            body: body,
            data: payload,
          ),
        );
      } else {
        unawaited(
          _showLocalNotification(
            id: 'remote_${DateTime.now().microsecondsSinceEpoch}',
            title: title,
            body: body,
            data: payload,
          ),
        );
      }
    });

    _onMessageOpenedAppSub = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) {
        final payload = Map<String, dynamic>.from(message.data);
        unawaited(NotificationNavigationService.openFromData(payload));
      },
    );

    _onTokenRefreshSub = _messaging.onTokenRefresh.listen((token) {
      final uid = (_auth.currentUser?.uid ?? '').trim();
      if (uid.isEmpty) {
        return;
      }
      unawaited(_saveMessagingToken(uid, forcedToken: token));
    });

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      unawaited(
        NotificationNavigationService.openFromData(
          Map<String, dynamic>.from(initialMessage.data),
        ),
      );
    }

    _authSub = _auth.authStateChanges().listen((user) {
      final uid = (user?.uid ?? '').trim();
      unawaited(_bindUser(uid));
    });

    final initialUid = (_auth.currentUser?.uid ?? '').trim();
    await _bindUser(initialUid);
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _authSub?.cancel();
    await _onMessageSub?.cancel();
    await _onMessageOpenedAppSub?.cancel();
    await _onTokenRefreshSub?.cancel();
    await _notificationsSub?.cancel();
    await _inAppEventsController.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  Future<void> _bindUser(String uid) async {
    if (_activeUid == uid) {
      return;
    }

    _activeUid = uid;
    _knownDocIds.clear();
    await _notificationsSub?.cancel();
    _notificationsSub = null;

    if (uid.isEmpty) {
      return;
    }

    await _saveMessagingToken(uid);

    final query = _db
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(40);

    final initialSnapshot = await query.get();
    for (final doc in initialSnapshot.docs) {
      _knownDocIds.add(doc.id);
    }

    _notificationsSub = query.snapshots().listen((snapshot) {
      for (final change in snapshot.docChanges) {
        final doc = change.doc;
        final docId = doc.id;
        final data = doc.data() ?? <String, dynamic>{};

        if (change.type != DocumentChangeType.added) {
          _knownDocIds.add(docId);
          continue;
        }

        if (_knownDocIds.contains(docId)) {
          continue;
        }
        _knownDocIds.add(docId);

        final isRead = (data['isRead'] as bool?) ?? false;
        if (isRead) {
          continue;
        }

        final title = (data['title'] as String? ?? '').trim();
        final body = (data['body'] as String? ?? '').trim();
        if (title.isEmpty && body.isEmpty) {
          continue;
        }

        final payload = <String, dynamic>{'id': docId, ...data};
        if (_lifecycleState == AppLifecycleState.resumed) {
          _inAppEventsController.add(
            InAppNotificationEvent(
              id: docId,
              title: title,
              body: body,
              data: payload,
            ),
          );
        } else {
          unawaited(_showLocalNotification(
            id: docId,
            title: title,
            body: body,
            data: payload,
          ));
        }
      }
    });
  }

  Future<void> _saveMessagingToken(String uid, {String? forcedToken}) async {
    try {
      final token = forcedToken ?? await _messaging.getToken();
      final normalizedToken = (token ?? '').trim();
      debugPrint('FCM token generated for uid=$uid: ${normalizedToken.isEmpty ? 'EMPTY' : normalizedToken.substring(0, 20)}...');
      if (normalizedToken.isEmpty) {
        return;
      }

      await _db.collection('users').doc(uid).set(
        <String, dynamic>{
          'fcmTokens.$normalizedToken': true,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> showDeviceNotification({
    required String id,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    await _showLocalNotification(id: id, title: title, body: body, data: data);
  }

  Future<void> _showLocalNotification({
    required String id,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'hundred_notifications',
      'Hundred Notifications',
      channelDescription:
          'Heads-up notifications for user activity and challenges',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Hundred',
      styleInformation: BigTextStyleInformation(body),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _localNotifications.show(
      id.hashCode,
      title,
      body,
      details,
      payload: jsonEncode(data),
    );
  }
}
