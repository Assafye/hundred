import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_navigation_service.dart';
import 'notification_service.dart';

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

  late final StreamController<InAppNotificationEvent> _inAppEventsController =
      StreamController<InAppNotificationEvent>.broadcast(
    onListen: _onInAppListenerAttached,
  );

  final List<InAppNotificationEvent> _pendingInAppEvents =
      <InAppNotificationEvent>[];

  Stream<InAppNotificationEvent> get inAppEvents =>
      _inAppEventsController.stream;

  static const Set<String> _postPreviewTypes = <String>{
    NotificationTypes.postLike,
    NotificationTypes.postSave,
    NotificationTypes.postComment,
    NotificationTypes.commentReply,
    NotificationTypes.weeklyStars,
  };

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
    final rendered = _renderExternalNotificationContent(
      data: payload,
      fallbackTitle: title,
      fallbackBody: body,
    );
    final previewUrl = _resolvePostPreviewUrl(payload);
    final previewPath = await _downloadImageToTemp(
      imageUrl: previewUrl,
      filePrefix: 'bg_notif_${message.messageId ?? DateTime.now().microsecondsSinceEpoch}',
    );
    final details = _buildExternalNotificationDetails(
      body: rendered.body,
      previewImagePath: previewPath,
    );
    final notificationData = <String, dynamic>{
      ...payload,
      'title': rendered.title,
      'body': rendered.body,
    };
    await localPlugin.show(
      id.hashCode,
      rendered.title,
      rendered.body,
      details,
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

  void _onInAppListenerAttached() {
    if (_pendingInAppEvents.isNotEmpty) {
      for (final event in _pendingInAppEvents) {
        _inAppEventsController.add(event);
      }
      _pendingInAppEvents.clear();
    }
  }

  void _emitInAppEvent(InAppNotificationEvent event) {
    if (_inAppEventsController.hasListener) {
      _inAppEventsController.add(event);
      return;
    }

    _pendingInAppEvents.add(event);
    if (_pendingInAppEvents.length > 5) {
      _pendingInAppEvents.removeAt(0);
    }
  }

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
        _emitInAppEvent(
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
          _emitInAppEvent(
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
    final rendered = _renderExternalNotificationContent(
      data: data,
      fallbackTitle: title,
      fallbackBody: body,
    );
    final previewPath = await _downloadImageToTemp(
      imageUrl: _resolvePostPreviewUrl(data),
      filePrefix: id,
    );
    final details = _buildExternalNotificationDetails(
      body: rendered.body,
      previewImagePath: previewPath,
    );

    await _localNotifications.show(
      id.hashCode,
      rendered.title,
      rendered.body,
      details,
      payload: jsonEncode(data),
    );
  }

  static NotificationDetails _buildExternalNotificationDetails({
    required String body,
    required String previewImagePath,
  }) {
    final androidDetails = AndroidNotificationDetails(
      'hundred_notifications',
      'Hundred Notifications',
      channelDescription:
          'Heads-up notifications for user activity and challenges',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Hundred',
      styleInformation: previewImagePath.isNotEmpty
          ? BigPictureStyleInformation(
              FilePathAndroidBitmap(previewImagePath),
              hideExpandedLargeIcon: true,
              summaryText: body,
            )
          : BigTextStyleInformation(body),
    );

    final attachments = previewImagePath.isEmpty
        ? const <DarwinNotificationAttachment>[]
        : <DarwinNotificationAttachment>[
            DarwinNotificationAttachment(previewImagePath),
          ];

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
      attachments: attachments,
    );

    return NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );
  }

  static String _resolvePostPreviewUrl(Map<String, dynamic> data) {
    final type = (data['type'] as String? ?? '').trim();
    if (!_postPreviewTypes.contains(type)) {
      return '';
    }
    return (data['postImageUrl'] as String? ?? '').trim();
  }

  static Future<String> _downloadImageToTemp({
    required String imageUrl,
    required String filePrefix,
  }) async {
    final normalized = imageUrl.trim();
    if (normalized.isEmpty) {
      return '';
    }

    Uri? uri;
    try {
      uri = Uri.parse(normalized);
    } catch (_) {
      return '';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '';
    }

    try {
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        client.close(force: true);
        return '';
      }

      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      final bytes = chunks;
      client.close(force: true);

      if (bytes.isEmpty) {
        return '';
      }

      final safePrefix = filePrefix.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final file = File(
        '${Directory.systemTemp.path}/hundred_${safePrefix}_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  static _ExternalNotificationContent _renderExternalNotificationContent({
    required Map<String, dynamic> data,
    required String fallbackTitle,
    required String fallbackBody,
  }) {
    final type = (data['type'] as String? ?? '').trim();
    final actorName = (data['actorName'] as String? ?? '').trim();
    final normalizedActor = actorName.isEmpty ? 'משתמש' : actorName;
    final body = (data['body'] as String? ?? fallbackBody).trim();
    final title = (data['title'] as String? ?? fallbackTitle).trim();

    switch (type) {
      case NotificationTypes.postComment:
        final commentText = title.replaceAll('"', '').trim();
        return _ExternalNotificationContent(
          title: actorName.isNotEmpty
              ? '$actorName הגיב/ה: $commentText'
              : 'הגיבו: $commentText',
          body: '',
        );
      case NotificationTypes.commentReply:
        final replyText = title.replaceAll('"', '').trim();
        return _ExternalNotificationContent(
          title: actorName.isNotEmpty
              ? '$actorName הגיב לך: $replyText'
              : 'הגיבו לך: $replyText',
          body: '',
        );
      case NotificationTypes.postSave:
        return _ExternalNotificationContent(
          title: actorName.isNotEmpty
              ? '$actorName שמר את הפוסט שלך'
              : 'שמרו את הפוסט שלך',
          body: '',
        );
      case NotificationTypes.postLike:
        final likeCount = (data['likeCount'] as num?)?.toInt() ?? 1;
        final likeTitle = likeCount > 1
            ? 'יש לך $likeCount לייקים על הפוסט'
            : 'יש לך לייק חדש על הפוסט';
        final likeBody = actorName.isEmpty ? body : '$actorName אהב/ה את הפוסט שלך';
        return _ExternalNotificationContent(title: likeTitle, body: likeBody);
      case NotificationTypes.groupJoin:
        final groupName = (data['groupName'] as String? ?? '').trim();
        final normalizedGroup = groupName.isNotEmpty ? groupName : 'קבוצה';
        return _ExternalNotificationContent(
          title: '$normalizedActor הצטרף לקבוצה "$normalizedGroup"',
          body: '',
        );
      case NotificationTypes.popJoin:
        final groupName = (data['groupName'] as String? ?? '').trim();
        final normalizedGroup = groupName.isNotEmpty ? groupName : 'פופ';
        return _ExternalNotificationContent(
          title: '$normalizedActor הצטרף לפופ שלך "$normalizedGroup"!',
          body: '',
        );
      case NotificationTypes.newFollower:
        return _ExternalNotificationContent(
          title: actorName.isNotEmpty
              ? '$actorName התחיל לעקוב אחריך'
              : 'מישהו התחיל לעקוב אחריך',
          body: '',
        );
      case NotificationTypes.newFriend:
        return _ExternalNotificationContent(
          title: 'איזה כיף, $normalizedActor נהיה חבר שלך!',
          body: '',
        );
      case NotificationTypes.weeklyChallengeUpdated:
        return const _ExternalNotificationContent(
          title: 'האתגר השבועי התעדכן! ניתן לצפות במסך כוכבי השבוע',
          body: '',
        );
      case NotificationTypes.dailyChallengeUpdated:
        return const _ExternalNotificationContent(
          title: 'המשימה היומית התעדכנה! השעון התחיל לרוץ...',
          body: '',
        );
      case NotificationTypes.weeklyStars:
        return const _ExternalNotificationContent(
          title: 'הפוסט שלך נכנס למסך כוכבי השבוע!',
          body: '',
        );
      case NotificationTypes.spontaneousReminder:
        return const _ExternalNotificationContent(
          title: 'מבחן הספונטניות זמין! זה הזמן להגריל משימה לקבל ניקוד x10',
          body: '',
        );
      case NotificationTypes.spontaneousTimeWarning:
        final hours = _parseWarningHours(data, body);
        final hoursLabel = hours == 1 ? 'שעה' : '$hours שעות';
        return _ExternalNotificationContent(
          title: 'השעון מתקתק! נשאר לך עוד $hoursLabel למשימה שלך!',
          body: '',
        );
      case NotificationTypes.addedToGroup:
        final groupName = (data['groupName'] as String? ?? '').trim();
        final normalizedGroup = groupName.isNotEmpty ? groupName : 'קבוצה';
        final count = _parseAddedUsersCount(data);
        final addedUserName = _parsePrimaryAddedUserName(data);
        final addedTitle = count > 1
            ? '$normalizedActor הוסיף $count אנשים לקבוצה "$normalizedGroup"'
            : '$normalizedActor הוסיף את $addedUserName לקבוצה "$normalizedGroup"';
        return _ExternalNotificationContent(title: addedTitle, body: '');
      case NotificationTypes.newMessage:
        final isGroupChat = (data['isGroupChat'] as bool?) ?? false;
        final messageText = _parseMessagePreviewText(data, body);
        if (!isGroupChat) {
          return _ExternalNotificationContent(
            title: '$normalizedActor "$messageText"',
            body: '',
          );
        }
        final chatNameRaw = (data['chatName'] as String? ?? '').trim();
        final groupTitle = chatNameRaw.isNotEmpty
            ? chatNameRaw
            : (title.isNotEmpty ? title : 'קבוצה');
        return _ExternalNotificationContent(
          title: groupTitle,
          body: '$normalizedActor: "$messageText"',
        );
      default:
        final resolvedTitle = title.isNotEmpty ? title : fallbackTitle.trim();
        final resolvedBody = body.isNotEmpty ? body : fallbackBody.trim();
        return _ExternalNotificationContent(
          title: resolvedTitle.isEmpty ? 'Hundred' : resolvedTitle,
          body: resolvedBody,
        );
    }
  }

  static int _parseAddedUsersCount(Map<String, dynamic> data) {
    final explicitRaw = data['addedUsersCount'];
    if (explicitRaw is num && explicitRaw.toInt() > 0) {
      return explicitRaw.toInt();
    }
    if (explicitRaw is String) {
      final parsed = int.tryParse(explicitRaw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final names = (data['addedUserNames'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    return names.isEmpty ? 1 : names.length;
  }

  static String _parsePrimaryAddedUserName(Map<String, dynamic> data) {
    final singleName = (data['addedUserName'] as String? ?? '').trim();
    if (singleName.isNotEmpty) {
      return singleName;
    }

    final names = (data['addedUserNames'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (names.isNotEmpty) {
      return names.first;
    }

    return 'משתמש';
  }

  static int _parseWarningHours(Map<String, dynamic> data, String fallbackBody) {
    final raw = data['warningHoursRemaining'];
    if (raw is num && raw.toInt() > 0) {
      return raw.toInt();
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final match = RegExp(r'(\d+)').firstMatch(fallbackBody);
    if (match != null) {
      final parsed = int.tryParse((match.group(1) ?? '').trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    return 1;
  }

  static String _parseMessagePreviewText(Map<String, dynamic> data, String fallbackBody) {
    final rawBody = (data['body'] as String? ?? fallbackBody).trim();
    if (rawBody.isEmpty) {
      return 'שלח/ה הודעה חדשה';
    }
    if (rawBody.length >= 2 && rawBody.startsWith('"') && rawBody.endsWith('"')) {
      return rawBody.substring(1, rawBody.length - 1).trim();
    }
    return rawBody;
  }
}

class _ExternalNotificationContent {
  const _ExternalNotificationContent({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}
