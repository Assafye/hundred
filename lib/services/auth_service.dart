import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../age_restrictions.dart';

import 'notification_service.dart';

enum OnboardingStep {
  pendingVerification,
  pendingProfile,
  active,
  expired;

  static OnboardingStep fromFirestore(String? value) {
    switch (value) {
      case 'pending_profile':
        return OnboardingStep.pendingProfile;
      case 'active':
        return OnboardingStep.active;
      case 'expired':
        return OnboardingStep.expired;
      case 'pending_verification':
      default:
        return OnboardingStep.pendingVerification;
    }
  }

  String get firestoreValue {
    switch (this) {
      case OnboardingStep.pendingVerification:
        return 'pending_verification';
      case OnboardingStep.pendingProfile:
        return 'pending_profile';
      case OnboardingStep.active:
        return 'active';
      case OnboardingStep.expired:
        return 'expired';
    }
  }
}

class PendingRegistrationState {
  const PendingRegistrationState({
    required this.email,
    required this.isVerified,
    required this.didSendVerificationEmail,
  });

  final String email;
  final bool isVerified;
  final bool didSendVerificationEmail;
}

enum LoginPreflightGate {
  allow,
  ageRestricted,
  pendingVerification,
  pendingProfile,
  expired,
}

class AuthService {
  static final ValueNotifier<bool> registrationFlowInProgress =
      ValueNotifier<bool>(false);
  static final ValueNotifier<String?> pendingAuthUiMessage =
      ValueNotifier<String?>(null);
  static const String onboardingStepField = 'onboardingStep';
  static const String onboardingExpirationField = 'onboardingExpiresAt';
  static const String onboardingStepPendingVerification =
      'pending_verification';
  static const String onboardingStepPendingProfile = 'pending_profile';
  static const String onboardingStepActive = 'active';
  static const String onboardingStepExpired = 'expired';
  static const String emailNotVerifiedCode = 'email-not-verified';
  static const String registrationIncompleteCode = 'registration-incomplete';
  static const String ageRestrictedCode = 'age-restricted';
  static const String phoneAuthDomain = 'hundred.com';
  static const String onboardingStageField = 'onboardingStage';
  static const String privacyAcceptedAtField = 'privacyAcceptedAt';
  static const String privacyPolicyVersionField = 'privacyPolicyVersion';

  final NotificationService _notificationService = NotificationService();

  static void setPendingAuthUiMessage(String? message) {
    pendingAuthUiMessage.value = message;
  }

  static String? consumePendingAuthUiMessage() {
    final message = pendingAuthUiMessage.value;
    pendingAuthUiMessage.value = null;
    return message;
  }

  static void clearPendingAuthUiMessage() {
    pendingAuthUiMessage.value = null;
  }

  Future<void> savePendingRegistrationDraft({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw FirebaseAuthException(
        code: 'session-expired',
        message: 'אין חשבון פעיל לשמירת פרטי ההרשמה.',
      );
    }

    final payload = {
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'phone': phone.trim(),
      'pendingRegistrationDraft': <String, dynamic>{
        'firstName': firstName.trim(),
        'lastName': lastName.trim(),
        'phone': phone.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
    };

    await _db.collection('users').doc(currentUser.uid).set(
          payload,
          SetOptions(merge: true),
        );
  }

  Future<Map<String, dynamic>> loadPendingRegistrationDraftByEmail(
    String email,
  ) async {
    final normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      return const <String, dynamic>{};
    }

    final snapshot = await _db
        .collection('users')
        .where('email', isEqualTo: normalizedEmail)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) {
      return const <String, dynamic>{};
    }

    final data = snapshot.docs.first.data();
    final draft = data['pendingRegistrationDraft'];
    if (draft is! Map) {
      return const <String, dynamic>{};
    }

    return Map<String, dynamic>.from(draft);
  }

  FirebaseApp _defaultApp() {
    if (Firebase.apps.isEmpty) {
      throw StateError(
        'Firebase is not initialized. Call Firebase.initializeApp() before using AuthService.',
      );
    }
    return Firebase.app();
  }

  FirebaseAuth get _auth => FirebaseAuth.instanceFor(app: _defaultApp());

  FirebaseFirestore get _db =>
      FirebaseFirestore.instanceFor(app: _defaultApp());

  FirebaseStorage get _storage =>
      FirebaseStorage.instanceFor(app: _defaultApp());

  void _assertAuthBoundToDefaultApp(String source) {
    final defaultAppName = _defaultApp().name;
    final authAppName = _auth.app.name;
    if (authAppName != defaultAppName) {
      throw StateError(
        'FirebaseAuth app mismatch at $source: authApp=$authAppName, defaultApp=$defaultAppName',
      );
    }
  }

  Map<String, dynamic> _publicProfilePayload({
    required String uid,
    required String username,
    required String firstName,
    required String lastName,
    required String profilePictureUrl,
    bool isPrivate = false,
    String displayName = '',
    String lifeMotto = '',
    List<String> profileImageUrls = const <String>[],
    String bio = '',
    int followersCount = 0,
    int followingCount = 0,
    int friendsCount = 0,
  }) {
    return {
      'uid': uid,
      'username': username,
      'usernameLowercase': _normalizeUsername(username),
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'displayName': displayName.trim(),
      'lifeMotto': lifeMotto.trim(),
      'bio': bio.trim(),
      'profilePictureUrl': profilePictureUrl.trim(),
      'profileImageUrls': profileImageUrls,
      'isPrivate': isPrivate,
      'followersCount': followersCount,
      'followingCount': followingCount,
      'friendsCount': friendsCount,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Future<void> ensureCurrentUserPublicProfile() async {
    final currentUser = _auth.currentUser;
    final uid = currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return;
    }

    Map<String, dynamic> privateProfile = <String, dynamic>{};
    try {
      final snapshot = await _db.collection('users').doc(uid).get();
      privateProfile = snapshot.data() ?? <String, dynamic>{};
    } catch (_) {
      privateProfile = <String, dynamic>{};
    }

    final firstName = (privateProfile['firstName'] as String? ?? '').trim();
    final lastName = (privateProfile['lastName'] as String? ?? '').trim();
    final username = (privateProfile['username'] as String? ?? '').trim();
    final profilePictureUrl =
        (privateProfile['profilePictureUrl'] as String? ?? '').trim();
    final profileImageUrls =
        ((privateProfile['profileImageUrls'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .map((url) => url.trim())
            .where((url) => url.isNotEmpty)
            .toList(growable: false);
    final displayName = (privateProfile['displayName'] as String? ?? '').trim();
    final lifeMotto = (privateProfile['lifeMotto'] as String? ?? '').trim();
    final bio = (privateProfile['bio'] as String? ?? '').trim();
    final isPrivate = (privateProfile['isPrivate'] as bool?) ?? false;
    final followersCount =
        (privateProfile['followersCount'] as num?)?.toInt() ?? 0;
    final followingCount =
        (privateProfile['followingCount'] as num?)?.toInt() ?? 0;
    final friendsCount = (privateProfile['friendsCount'] as num?)?.toInt() ?? 0;

    await _db.collection('users_public').doc(uid).set({
      ..._publicProfilePayload(
        uid: uid,
        username: username,
        firstName: firstName,
        lastName: lastName,
        displayName: displayName,
        lifeMotto: lifeMotto,
        profilePictureUrl: profilePictureUrl,
        profileImageUrls: profileImageUrls,
        bio: bio,
        isPrivate: isPrivate,
        followersCount: followersCount,
        followingCount: followingCount,
        friendsCount: friendsCount,
      ),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  String _normalizeUsername(String username) {
    final trimmed = username.trim();
    if (trimmed.isEmpty) return '';
    final withAt = trimmed.startsWith('@') ? trimmed : '@$trimmed';
    return withAt.toLowerCase();
  }

  String _normalizeEmail(String email) => email.trim().toLowerCase();

  String normalizePhoneNumber(String phone) {
    final trimmed = phone.trim();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (trimmed.startsWith('+')) {
      return '+$digits';
    }
    // The app currently targets Israeli numbers; accept the common local form
    // while always sending Firebase an E.164 number.
    if (digits.startsWith('0') && digits.length >= 9) {
      return '+972${digits.substring(1)}';
    }
    if (digits.startsWith('972')) {
      return '+$digits';
    }
    return digits;
  }

  String phoneAuthEmail(String phone) {
    final normalized = normalizePhoneNumber(phone);
    if (normalized.isEmpty) return '';
    final localPart = normalized.replaceAll(RegExp(r'\D'), '');
    return '$localPart@$phoneAuthDomain';
  }

  bool isPhoneLoginInput(String input) {
    final trimmed = input.trim();
    return trimmed.isNotEmpty && !trimmed.contains('@');
  }

  Future<bool> isRegisteredPhone(String phone) async {
    final normalizedPhone = normalizePhoneNumber(phone);
    if (normalizedPhone.isEmpty) return false;
    final snapshot = await _db
        .collection('users')
        .where('phone', isEqualTo: normalizedPhone)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  void logAuthFailure(String source, Object error, [StackTrace? stackTrace]) {
    final details = <String>[
      '[AuthService][$source] FirebaseAuth failure',
      'type=${error.runtimeType}',
    ];

    if (error is FirebaseAuthException) {
      details.add('code=${error.code}');
      details.add('message=${error.message ?? 'no-message'}');
    }

    details.add('error=$error');
    final message = details.join(' | ');
    debugPrint(message);
    if (stackTrace != null) {
      debugPrint('[AuthService][$source] stackTrace: $stackTrace');
    }

    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'AuthService',
        context: ErrorDescription('FirebaseAuth failure during $source'),
        informationCollector: () sync* {
          yield ErrorDescription('FirebaseAuth failure source: $source');
          if (error is FirebaseAuthException) {
            yield ErrorDescription('FirebaseAuthException code: ${error.code}');
            yield ErrorDescription(
                'FirebaseAuthException message: ${error.message ?? 'null'}');
          }
        },
      ),
    );
  }

  Future<void> _logUserAuthSnapshot(String source, User? user) async {
    if (user == null) {
      debugPrint('[AuthService][$source] user snapshot: user=null');
      return;
    }

    try {
      final tokenResult = await user.getIdTokenResult(true);
      final currentUser = _auth.currentUser;
      debugPrint(
        '[AuthService][$source] user snapshot: '
        'uid=${user.uid}, '
        'email=${user.email}, '
        'verified=${user.emailVerified}, '
        'isAnonymous=${user.isAnonymous}, '
        'providers=${user.providerData.map((p) => p.providerId).join(',')}, '
        'currentUserUid=${currentUser?.uid}, '
        'creationTime=${user.metadata.creationTime}, '
        'lastSignInTime=${user.metadata.lastSignInTime}, '
        'tokenIssuedAt=${tokenResult.issuedAtTime}, '
        'tokenExpiration=${tokenResult.expirationTime}, '
        'claims=${tokenResult.claims?.keys.toList() ?? const <String>[]}',
      );
    } on FirebaseAuthException catch (e, st) {
      debugPrint(
        '[AuthService][$source] failed to read user token snapshot: '
        'type=${e.runtimeType}, code=${e.code}, message=${e.message}, error=$e',
      );
      debugPrint('[AuthService][$source] token snapshot stackTrace: $st');
    } catch (e, st) {
      debugPrint(
        '[AuthService][$source] failed to read user token snapshot: '
        'type=${e.runtimeType}, error=$e',
      );
      debugPrint('[AuthService][$source] token snapshot stackTrace: $st');
    }
  }

  Future<String> resolveEmailForUsername(String username) async {
    final normalizedUsername = _normalizeUsername(username);
    if (normalizedUsername.isEmpty) {
      return '';
    }

    try {
      final snapshot = await _db
          .collection('users')
          .where('usernameLowercase', isEqualTo: normalizedUsername)
          .limit(1)
          .get();

      final docs = snapshot.docs.isNotEmpty
          ? snapshot.docs
          : (await _db
                  .collection('users')
                  .where('username', isEqualTo: normalizedUsername)
                  .limit(1)
                  .get())
              .docs;

      if (docs.isEmpty) {
        return '';
      }

      final email = (docs.first.data()['email'] as String? ?? '').trim();
      return email;
    } catch (_) {
      return '';
    }
  }

  Future<OnboardingStep> onboardingStepForEmail(String email) async {
    final normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      return OnboardingStep.pendingVerification;
    }

    try {
      final snapshot = await _db
          .collection('users')
          .where('email', isEqualTo: normalizedEmail)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) {
        return OnboardingStep.pendingVerification;
      }
      return OnboardingStep.fromFirestore(
        snapshot.docs.first.data()['onboardingStep'] as String?,
      );
    } catch (_) {
      return OnboardingStep.pendingVerification;
    }
  }

  Future<OnboardingStep> currentUserOnboardingStep() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return OnboardingStep.pendingVerification;
    }
    return _resolveOnboardingStepForUid(currentUser.uid);
  }

  Future<LoginPreflightGate> preflightLoginGate(String emailOrUsername) async {
    final input = emailOrUsername.trim();
    if (input.isEmpty) {
      return LoginPreflightGate.allow;
    }

    final isEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(input);
    final email = isEmail ? input : phoneAuthEmail(input);

    final normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      return LoginPreflightGate.allow;
    }

    try {
      final snapshot = await _db
          .collection('users')
          .where(
            isEmail ? 'email' : 'phoneAuthEmail',
            isEqualTo: normalizedEmail,
          )
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        return LoginPreflightGate.allow;
      }

      final data = snapshot.docs.first.data();
      if (_isAgeRestrictedUserData(data)) {
        return LoginPreflightGate.ageRestricted;
      }
      final step = OnboardingStep.fromFirestore(
        data[onboardingStepField] as String?,
      );

      switch (step) {
        case OnboardingStep.pendingVerification:
          return LoginPreflightGate.pendingProfile;
        case OnboardingStep.pendingProfile:
          return LoginPreflightGate.pendingProfile;
        case OnboardingStep.expired:
          return LoginPreflightGate.pendingProfile;
        case OnboardingStep.active:
          return LoginPreflightGate.allow;
      }
    } catch (_) {
      return LoginPreflightGate.allow;
    }
  }

  Future<OnboardingStep> _resolveOnboardingStepForUid(String uid) async {
    final snapshot = await _db.collection('users').doc(uid).get();
    if (!snapshot.exists) {
      return OnboardingStep.pendingVerification;
    }

    final rawValue = snapshot.data()?['onboardingStep'] as String?;
    return OnboardingStep.fromFirestore(rawValue);
  }

  Future<void> _setOnboardingStepForUid(
    String uid, {
    required OnboardingStep step,
  }) async {
    final docRef = _db.collection('users').doc(uid);
    final expiration = step == OnboardingStep.active
        ? null
        : Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24)));

    await docRef.set(
      {
        onboardingStepField: step.firestoreValue,
        if (expiration != null) onboardingExpirationField: expiration,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  bool isOnboardingExpired(Map<String, dynamic> data) {
    final step = OnboardingStep.fromFirestore(
      data[onboardingStepField] as String?,
    );
    if (step == OnboardingStep.active || step == OnboardingStep.expired) {
      return step == OnboardingStep.expired;
    }

    final expiresAtRaw = data[onboardingExpirationField];
    final expiresAt = expiresAtRaw is Timestamp ? expiresAtRaw.toDate() : null;
    if (expiresAt == null) {
      return false;
    }

    return DateTime.now().isAfter(expiresAt);
  }

  Future<void> _ensureUserOnboardingState(
    User user, {
    required OnboardingStep step,
  }) async {
    final uid = user.uid;
    final snapshot = await _db.collection('users').doc(uid).get();
    if (!snapshot.exists) {
      await _db.collection('users').doc(uid).set(
        {
          'uid': uid,
          'email': (user.email ?? '').trim(),
          onboardingStepField: step.firestoreValue,
          onboardingExpirationField: Timestamp.fromDate(
            DateTime.now().add(const Duration(hours: 24)),
          ),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      return;
    }

    final currentStep = OnboardingStep.fromFirestore(
      snapshot.data()?[onboardingStepField] as String?,
    );
    if (currentStep == OnboardingStep.active && step != OnboardingStep.active) {
      return;
    }

    await _setOnboardingStepForUid(uid, step: step);
  }

  bool _isFreshPendingRegistration(
    Map<String, dynamic> userData, {
    Duration maxAge = const Duration(minutes: 1),
  }) {
    final step = OnboardingStep.fromFirestore(
      userData[onboardingStepField] as String?,
    );

    if (step == OnboardingStep.active) {
      return false;
    }

    final createdAtRaw = userData['createdAt'];
    final createdAt = createdAtRaw is Timestamp ? createdAtRaw.toDate() : null;
    if (createdAt == null) {
      return true;
    }

    return DateTime.now().difference(createdAt) <= maxAge;
  }

  Future<bool> _hasCompletedPrivateProfile(String uid) async {
    final snapshot = await _db.collection('users').doc(uid).get();
    if (!snapshot.exists) {
      return false;
    }

    final data = snapshot.data() ?? <String, dynamic>{};
    final username = (data['username'] as String? ?? '').trim();
    final firstName = (data['firstName'] as String? ?? '').trim();
    final lastName = (data['lastName'] as String? ?? '').trim();
    final birthDate = (data['birthDate'] as String? ?? '').trim();
    final phone = (data['phone'] as String? ?? '').trim();
    final profilePictureUrl =
        (data['profilePictureUrl'] as String? ?? '').trim();
    final profileImages =
        ((data['profileImageUrls'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .map((url) => url.trim())
            .where((url) => url.isNotEmpty)
            .toList(growable: false);

    return username.isNotEmpty &&
        firstName.isNotEmpty &&
        lastName.isNotEmpty &&
        birthDate.isNotEmpty &&
        phone.isNotEmpty &&
        profilePictureUrl.isNotEmpty &&
        profileImages.isNotEmpty;
  }

  bool _isAgeRestrictedUserData(Map<String, dynamic> data) {
    if (data['isAgeRestricted'] == true) {
      return true;
    }

    final birthDate = parseStoredBirthDate(
      (data['birthDate'] as String? ?? '').trim(),
    );
    return birthDate != null && !isAtLeastMinimumAge(birthDate);
  }

  Future<User?> _createOrResumeRegistrationUser({
    required String email,
    required String password,
  }) async {
    debugPrint(
      '[AuthService][_createOrResumeRegistrationUser] starting for email=$email, currentUser=${_auth.currentUser?.uid}',
    );
    try {
      final result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      debugPrint(
        '[AuthService][_createOrResumeRegistrationUser] createUserWithEmailAndPassword completed: additionalUserInfo.isNewUser=${result.additionalUserInfo?.isNewUser}',
      );
      await _ensureUserOnboardingState(
        result.user!,
        step: OnboardingStep.pendingVerification,
      );
      await _logUserAuthSnapshot(
        '_createOrResumeRegistrationUser.createUserWithEmailAndPassword',
        result.user,
      );
      return result.user;
    } on FirebaseAuthException catch (e, st) {
      debugPrint(
        '[AuthService][_createOrResumeRegistrationUser] createUserWithEmailAndPassword failed: '
        'type=${e.runtimeType}, code=${e.code}, message=${e.message}, error=$e',
      );
      debugPrint(
        '[AuthService][_createOrResumeRegistrationUser] createUserWithEmailAndPassword stackTrace: $st',
      );
      if (e.code != 'email-already-in-use') {
        rethrow;
      }

      final userDoc = await _db
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (userDoc.docs.isEmpty) {
        rethrow;
      }

      final userDocData = userDoc.docs.first.data();
      final onboardingStep = OnboardingStep.fromFirestore(
        userDocData[onboardingStepField] as String?,
      );
      final isFreshPendingRegistration =
          _isFreshPendingRegistration(userDocData);
      final isExpiredPendingRegistration = isOnboardingExpired(userDocData);
      final shouldResumePendingFlow = onboardingStep != OnboardingStep.active &&
          (isFreshPendingRegistration || isExpiredPendingRegistration);

      if (!shouldResumePendingFlow) {
        throw FirebaseAuthException(
          code: 'email-already-in-use',
          message:
              'כתובת המייל כבר רשומה למשתמש פעיל או בתהליך סיום הרשמה. אם אתה רוצה להמשיך, יש לאמת את המייל או להתחבר.',
        );
      }

      try {
        final result = await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        debugPrint(
          '[AuthService][_createOrResumeRegistrationUser] signInWithEmailAndPassword reused existing auth user',
        );
        final user = result.user;
        if (user == null) {
          rethrow;
        }

        final nextStep = onboardingStep == OnboardingStep.pendingProfile
            ? OnboardingStep.pendingProfile
            : OnboardingStep.pendingVerification;
        if (isExpiredPendingRegistration) {
          await _setOnboardingStepForUid(user.uid, step: nextStep);
        } else {
          await _ensureUserOnboardingState(user, step: nextStep);
        }
        if (!user.emailVerified) {
          await _sendEmailVerificationWithLogging(
            user,
            source: '_createOrResumeRegistrationUser.resumePendingFlow',
          );
        }
        await _logUserAuthSnapshot(
          '_createOrResumeRegistrationUser.signInWithEmailAndPassword',
          result.user,
        );
        return result.user;
      } on FirebaseAuthException catch (signInError) {
        if (signInError.code == 'wrong-password') {
          throw FirebaseAuthException(
            code: 'email-already-in-use',
            message:
                'יש כבר חשבון עם מייל זה, אך הסיסמה אינה תואמת. אם אתה מכיר את החשבון, התחבר עם הסיסמה הנכונה. אם לא, יש לאפס/לחדש תהליך הרשמה.',
          );
        }
        rethrow;
      }
    }
  }

  Future<bool> isUsernameTaken(String username, {String? excludeUid}) async {
    final normalized = _normalizeUsername(username);
    if (normalized.isEmpty) return false;

    try {
      final lowercaseSnapshot = await _db
          .collection('users_public')
          .where('usernameLowercase', isEqualTo: normalized)
          .limit(1)
          .get();

      final snapshot = lowercaseSnapshot.docs.isNotEmpty
          ? lowercaseSnapshot
          : await _db
              .collection('users_public')
              .where('username', isEqualTo: normalized)
              .limit(1)
              .get();

      if (snapshot.docs.isEmpty) return false;
      if (excludeUid == null) return true;
      return snapshot.docs.first.id != excludeUid;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        if (_auth.currentUser == null) {
          throw FirebaseAuthException(
            code: 'session-expired',
            message: 'פג תוקף תהליך האימות. יש להתחיל שוב.',
          );
        }

        throw FirebaseAuthException(
          code: 'permission-denied',
          message: 'אין הרשאה לבדוק זמינות שם משתמש כרגע.',
        );
      }
      rethrow;
    }
  }

  Future<bool> isPhoneTaken(String phone, {String? excludeUid}) async {
    final normalized = phone.trim();
    if (normalized.isEmpty) return false;

    try {
      final snapshot = await _db
          .collection('users')
          .where('phone', isEqualTo: normalized)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return false;
      if (excludeUid == null) return true;
      return snapshot.docs.first.id != excludeUid;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return false;
      }
      rethrow;
    }
  }

  Future<bool> isEmailTaken(String email, {String? excludeUid}) async {
    final normalized = _normalizeEmail(email);
    if (normalized.isEmpty) return false;

    try {
      final snapshot = await _db
          .collection('users')
          .where('email', isEqualTo: normalized)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return false;
      if (excludeUid == null) return true;
      return snapshot.docs.first.id != excludeUid;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return false;
      }
      rethrow;
    }
  }

  Future<void> _sendEmailVerificationWithLogging(
    User user, {
    required String source,
  }) async {
    _assertAuthBoundToDefaultApp('$source.sendEmailVerification');
    final email = (user.email ?? '').trim();
    await _logUserAuthSnapshot('$source.beforeSendEmailVerification', user);
    debugPrint(
      '[AuthService][$source] sendEmailVerification starting for uid=${user.uid}, email=$email, verified=${user.emailVerified}, app=${_auth.app.name}',
    );

    try {
      await user.sendEmailVerification();
      debugPrint(
        '[AuthService][$source] sendEmailVerification completed successfully for uid=${user.uid}, email=$email',
      );
      await _logUserAuthSnapshot('$source.afterSendEmailVerification', user);
    } on FirebaseAuthException catch (e, st) {
      debugPrint(
        '[AuthService][$source] sendEmailVerification failed with FirebaseAuthException: '
        'type=${e.runtimeType}, code=${e.code}, message=${e.message}, error=$e',
      );
      debugPrint(
          '[AuthService][$source] sendEmailVerification stackTrace: $st');
      rethrow;
    } catch (e, st) {
      debugPrint(
        '[AuthService][$source] sendEmailVerification failed with unexpected error: '
        'type=${e.runtimeType}, error=$e',
      );
      debugPrint(
          '[AuthService][$source] sendEmailVerification stackTrace: $st');
      rethrow;
    }
  }

  Future<User> finishPhoneVerificationAndCreateAuthAccount({
    required AuthCredential phoneCredential,
    required String phone,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    final normalizedPhone = normalizePhoneNumber(phone);
    final internalEmail = phoneAuthEmail(normalizedPhone);
    if (normalizedPhone.isEmpty || internalEmail.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-phone-number',
        message: 'מספר הטלפון אינו תקין.',
      );
    }

    User? user = _auth.currentUser;
    if (user == null) {
      final phoneResult = await _auth.signInWithCredential(phoneCredential);
      user = phoneResult.user;
    }
    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'לא הצלחנו ליצור חשבון למספר הטלפון הזה.',
      );
    }

    final hasPasswordProvider = user.providerData.any(
      (provider) => provider.providerId == 'password',
    );
    if (!hasPasswordProvider) {
      final credential = EmailAuthProvider.credential(
        email: internalEmail,
        password: password,
      );
      final linked = await user.linkWithCredential(credential);
      user = linked.user ?? user;
    }

    await _db.collection('users').doc(user.uid).set(
      {
        'uid': user.uid,
        'phone': normalizedPhone,
        'email': internalEmail,
        'phoneAuthEmail': internalEmail,
        'displayName': '${firstName.trim()} ${lastName.trim()}'.trim(),
        'firstName': firstName.trim(),
        'lastName': lastName.trim(),
        'pendingRegistrationDraft': {
          'firstName': firstName.trim(),
          'lastName': lastName.trim(),
          'phone': normalizedPhone,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        onboardingStepField: OnboardingStep.pendingProfile.firestoreValue,
        onboardingStageField: 'credentials',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    return user;
  }

  Future<void> saveOnboardingCheckpoint(
    String uid, {
    required String stage,
    Map<String, dynamic> data = const <String, dynamic>{},
  }) async {
    await _db.collection('users').doc(uid).set(
      {
        ...data,
        onboardingStepField: OnboardingStep.pendingProfile.firestoreValue,
        onboardingStageField: stage,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<String> currentUserOnboardingStage() async {
    final user = _auth.currentUser;
    if (user == null) return 'credentials';
    final snapshot = await _db.collection('users').doc(user.uid).get();
    return (snapshot.data()?[onboardingStageField] as String?) ?? 'credentials';
  }

  Future<void> linkBackupEmailCredential({
    required String email,
    required String password,
  }) async {
    final user = _auth.currentUser;
    final normalizedEmail = _normalizeEmail(email);
    if (user == null) {
      throw FirebaseAuthException(
        code: 'session-expired',
        message: 'יש להתחבר מחדש כדי להוסיף מייל.',
      );
    }
    if (normalizedEmail.isEmpty ||
        normalizedEmail.endsWith('@$phoneAuthDomain')) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'יש להזין מייל אמיתי.',
      );
    }

    final hasPasswordProvider = user.providerData.any(
      (provider) => provider.providerId == 'password',
    );
    if (hasPasswordProvider &&
        !_normalizeEmail(user.email ?? '').endsWith('@$phoneAuthDomain')) {
      throw FirebaseAuthException(
        code: 'email-already-in-use',
        message: 'כבר קיים מייל מקושר לחשבון.',
      );
    }

    final credential = EmailAuthProvider.credential(
      email: normalizedEmail,
      password: password,
    );
    final linkedUser = (await user.linkWithCredential(credential)).user ?? user;
    await linkedUser.sendEmailVerification();
    await _db.collection('users').doc(linkedUser.uid).set(
      {
        'pendingBackupEmail': normalizedEmail,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<bool> confirmBackupEmail() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    await user.reload();
    final refreshedUser = _auth.currentUser ?? user;
    final email = _normalizeEmail(refreshedUser.email ?? '');
    if (!refreshedUser.emailVerified ||
        email.isEmpty ||
        email.endsWith('@$phoneAuthDomain')) {
      return false;
    }
    await _db.collection('users').doc(refreshedUser.uid).set(
      {
        'email': email,
        'backupEmail': email,
        'backupEmailVerified': true,
        'pendingBackupEmail': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    return true;
  }

  Future<PendingRegistrationState> beginEmailVerificationRegistration({
    required String email,
    required String password,
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    registrationFlowInProgress.value = true;
    try {
      final normalizedEmail = _normalizeEmail(email);
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] starting for email=$normalizedEmail, isWeb=$kIsWeb, currentHost=${kIsWeb ? Uri.base.host : 'n/a'}, currentOrigin=${kIsWeb ? Uri.base.origin : 'n/a'}',
      );
      User? user = _auth.currentUser;

      if (user != null) {
        await user.reload();
        user = _auth.currentUser ?? user;
        await _logUserAuthSnapshot(
          'beginEmailVerificationRegistration.existingCurrentUser',
          user,
        );

        final currentEmail = _normalizeEmail(user.email ?? '');
        if (currentEmail != normalizedEmail) {
          debugPrint(
            '[AuthService][beginEmailVerificationRegistration] current signed-in auth user email does not match requested email, signing out current user',
          );
          await _auth.signOut();
          user = null;
        }
      }

      user ??= await _createOrResumeRegistrationUser(
        email: normalizedEmail,
        password: password,
      );

      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-not-found',
          message: 'לא הצלחנו לפתוח תהליך אימות למייל הזה.',
        );
      }

      await user.reload();
      final refreshedUser = _auth.currentUser ?? user;
      await _logUserAuthSnapshot(
        'beginEmailVerificationRegistration.refreshedUser',
        refreshedUser,
      );
      final hasCompletedProfile =
          await _hasCompletedPrivateProfile(refreshedUser.uid);
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] hasCompletedPrivateProfile=$hasCompletedProfile for uid=${refreshedUser.uid}',
      );

      final onboardingStep =
          await _resolveOnboardingStepForUid(refreshedUser.uid);
      final userData =
          (await _db.collection('users').doc(refreshedUser.uid).get()).data() ??
              <String, dynamic>{};
      if (_isAgeRestrictedUserData(userData)) {
        await _auth.signOut();
        throw FirebaseAuthException(
          code: ageRestrictedCode,
          message: 'האפליקציה מיועדת לגילאי $minimumUserAge ומעלה בלבד.',
        );
      }
      if (hasCompletedProfile && onboardingStep == OnboardingStep.active) {
        throw FirebaseAuthException(
          code: 'email-already-in-use',
          message: refreshedUser.emailVerified
              ? 'קיים כבר חשבון מלא עם כתובת המייל הזו. אפשר להתחבר.'
              : 'קיים כבר חשבון עם כתובת המייל הזו, אך הוא עדיין לא אומת.',
        );
      }

      await _ensureUserOnboardingState(
        refreshedUser,
        step: OnboardingStep.pendingVerification,
      );

      final normalizedFirstName = firstName?.trim() ?? '';
      final normalizedLastName = lastName?.trim() ?? '';
      final normalizedPhone = phone?.trim() ?? '';
      if (normalizedFirstName.isNotEmpty &&
          normalizedLastName.isNotEmpty &&
          normalizedPhone.isNotEmpty) {
        await savePendingRegistrationDraft(
          firstName: normalizedFirstName,
          lastName: normalizedLastName,
          phone: normalizedPhone,
        );
      }

      var didSendVerificationEmail = false;
      if (!refreshedUser.emailVerified) {
        await _sendEmailVerificationWithLogging(
          refreshedUser,
          source: 'beginEmailVerificationRegistration',
        );
        didSendVerificationEmail = true;
      }

      return PendingRegistrationState(
        email: (refreshedUser.email ?? normalizedEmail).trim(),
        isVerified: refreshedUser.emailVerified,
        didSendVerificationEmail: didSendVerificationEmail,
      );
    } on FirebaseAuthException catch (e, st) {
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] failed: '
        'type=${e.runtimeType}, code=${e.code}, message=${e.message}, error=$e',
      );
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] stackTrace: $st',
      );
      registrationFlowInProgress.value = false;
      rethrow;
    } catch (e, st) {
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] failed with unexpected error: '
        'type=${e.runtimeType}, error=$e',
      );
      debugPrint(
        '[AuthService][beginEmailVerificationRegistration] stackTrace: $st',
      );
      registrationFlowInProgress.value = false;
      rethrow;
    } finally {
      registrationFlowInProgress.value = false;
    }
  }

  Future<bool> refreshPendingEmailVerificationStatus() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw FirebaseAuthException(
        code: 'session-expired',
        message: 'פג תוקף תהליך האימות. יש להתחיל שוב.',
      );
    }

    await currentUser.reload();
    final refreshedUser = _auth.currentUser ?? currentUser;
    await _logUserAuthSnapshot(
      'refreshPendingEmailVerificationStatus.refreshedUser',
      refreshedUser,
    );
    return refreshedUser.emailVerified;
  }

  Future<void> resendPendingEmailVerification() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw FirebaseAuthException(
        code: 'session-expired',
        message: 'פג תוקף תהליך האימות. יש להתחיל שוב.',
      );
    }

    await currentUser.reload();
    final refreshedUser = _auth.currentUser ?? currentUser;
    if (!refreshedUser.emailVerified) {
      await _sendEmailVerificationWithLogging(
        refreshedUser,
        source: 'resendPendingEmailVerification',
      );
    }
  }

  Future<void> endPendingRegistrationFlow({bool signOut = true}) async {
    try {
      if (signOut && _auth.currentUser != null) {
        await _auth.signOut();
      }
    } finally {
      registrationFlowInProgress.value = false;
    }
  }

  Future<User> requireCompletedRegistration(
    User user, {
    bool queueUiMessageOnFailure = true,
  }) async {
    await user.reload();
    final refreshedUser = _auth.currentUser ?? user;
    final onboardingStep =
        await _resolveOnboardingStepForUid(refreshedUser.uid);
    if (onboardingStep == OnboardingStep.active) {
      final snapshot =
          await _db.collection('users').doc(refreshedUser.uid).get();
      final data = snapshot.data() ?? <String, dynamic>{};
      if (!_isAgeRestrictedUserData(data)) {
        return refreshedUser;
      }

      if (queueUiMessageOnFailure) {
        setPendingAuthUiMessage(
          'הכניסה לאפליקציה זמינה מגיל $minimumUserAge ומעלה בלבד.',
        );
      }
      await _auth.signOut();
      throw FirebaseAuthException(
        code: ageRestrictedCode,
        message: 'הכניסה לאפליקציה זמינה מגיל $minimumUserAge ומעלה בלבד.',
      );
    }

    if (queueUiMessageOnFailure) {
      setPendingAuthUiMessage(
        'החשבון שלך עדיין לא הושלם. נא להשלים את הפרטים האישיים לאחר ההתחברות.',
      );
    }
    await _auth.signOut();
    throw FirebaseAuthException(
      code: registrationIncompleteCode,
      message: 'יש להשלים את שלב ההרשמה לאחר אימות המייל לפני הכניסה.',
    );
  }

  Future<bool> canCurrentUserAccessApp() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return false;
    }

    if (registrationFlowInProgress.value) {
      return true;
    }

    try {
      final onboardingStep =
          await _resolveOnboardingStepForUid(currentUser.uid);
      switch (onboardingStep) {
        case OnboardingStep.pendingVerification:
          setPendingAuthUiMessage(
            'האימייל עדיין לא אומת. נא לאמת את המייל כדי להמשיך.',
          );
          return false;
        case OnboardingStep.pendingProfile:
          setPendingAuthUiMessage(
            'ההרשמה לא הושלמה. נא להשלים את פרטי הפרופיל.',
          );
          return false;
        case OnboardingStep.expired:
          setPendingAuthUiMessage(
            'תהליך ההרשמה פג תוקפו. נא להתחיל מחדש.',
          );
          return false;
        case OnboardingStep.active:
          await requireCompletedRegistration(
            currentUser,
            queueUiMessageOnFailure: false,
          ).timeout(const Duration(seconds: 8));
          return true;
      }
    } on TimeoutException {
      return _auth.currentUser != null;
    } on FirebaseAuthException {
      return false;
    }
  }

  // משלים את פרטי המשתמש לאחר שאומת המייל.
  Future<User?> completeVerifiedRegistration({
    required String password,
    required String username,
    required String firstName,
    required String lastName,
    required String displayName,
    required String phone,
    required String birthDate,
    required String lifeMotto,
    required String bio,
    required List<XFile> profileImages,
    bool privacyAccepted = false,
  }) async {
    registrationFlowInProgress.value = true;
    try {
      _validateBirthDate(birthDate, required: true);

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw FirebaseAuthException(
          code: 'session-expired',
          message: 'פג תוקף תהליך האימות. יש להתחיל שוב.',
        );
      }

      await currentUser.reload();
      final user = _auth.currentUser ?? currentUser;
      final hasCompletedProfile = await _hasCompletedPrivateProfile(user.uid);
      if (hasCompletedProfile &&
          (await _resolveOnboardingStepForUid(user.uid)) ==
              OnboardingStep.active) {
        throw FirebaseAuthException(
          code: 'email-already-in-use',
          message: 'ההרשמה כבר הושלמה עבור כתובת המייל הזו.',
        );
      }

      await _ensureUserOnboardingState(
        user,
        step: OnboardingStep.pendingProfile,
      );

      final normalizedUsername = _normalizeUsername(username);
      if (normalizedUsername.isEmpty) {
        throw FirebaseAuthException(
          code: 'invalid-username',
          message: 'שם משתמש לא תקין.',
        );
      }

      final usernameAlreadyTaken = await isUsernameTaken(normalizedUsername);
      if (usernameAlreadyTaken) {
        throw FirebaseAuthException(
          code: 'username-already-in-use',
          message: 'שם המשתמש כבר תפוס.',
        );
      }

      if (profileImages.isEmpty) {
        throw FirebaseAuthException(
          code: 'profile-images-required',
          message: 'יש לבחור לפחות תמונת פרופיל אחת.',
        );
      }

      final uploadedProfileImageUrls = await _uploadRegistrationProfileImages(
        uid: user.uid,
        images: profileImages,
      );
      final defaultProfilePictureUrl = uploadedProfileImageUrls.first;
      final normalizedDisplayName = displayName.trim();
      final normalizedBio = bio.trim();
      final normalizedFirstName = firstName.trim();
      final normalizedLastName = lastName.trim();
      final normalizedLifeMotto = lifeMotto.trim();
      final normalizedPhone = phone.trim();
      final normalizedBirthDate = birthDate.trim();
      final parsedBirthDate = parseStoredBirthDate(normalizedBirthDate)!;
      final isAgeRestricted = !isAtLeastMinimumAge(parsedBirthDate);

      final userRef = _db.collection('users').doc(user.uid);
      final userPublicRef = _db.collection('users_public').doc(user.uid);
      final batch = _db.batch();

      batch.set(userRef, {
        'uid': user.uid,
        'email': (user.email ?? '').trim(),
        'phoneAuthEmail': phoneAuthEmail(normalizedPhone),
        'username': normalizedUsername,
        'usernameLowercase': normalizedUsername,
        'firstName': normalizedFirstName,
        'lastName': normalizedLastName,
        'displayName': normalizedDisplayName,
        'phone': normalizedPhone,
        'birthDate': normalizedBirthDate,
        'isAgeRestricted': isAgeRestricted,
        'lifeMotto': normalizedLifeMotto,
        'bio': normalizedBio,
        'profilePictureUrl': defaultProfilePictureUrl,
        'profileImageUrls': uploadedProfileImageUrls,
        'followers': <String>[],
        'following': <String>[],
        'friends': <String>[],
        'followersCount': 0,
        'followingCount': 0,
        'friendsCount': 0,
        'isPrivate': false,
        'score': 0,
        if (privacyAccepted) ...{
          privacyAcceptedAtField: FieldValue.serverTimestamp(),
          privacyPolicyVersionField: '2026-08-06',
        },
        'createdAt': FieldValue.serverTimestamp(),
      });

      batch.set(userPublicRef, {
        ..._publicProfilePayload(
          uid: user.uid,
          username: normalizedUsername,
          firstName: normalizedFirstName,
          lastName: normalizedLastName,
          displayName: normalizedDisplayName,
          lifeMotto: normalizedLifeMotto,
          profilePictureUrl: defaultProfilePictureUrl,
          profileImageUrls: uploadedProfileImageUrls,
          bio: normalizedBio,
          isPrivate: false,
          friendsCount: 0,
        ),
        'createdAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();
      await _setOnboardingStepForUid(user.uid, step: OnboardingStep.active);

      await _notificationService.initializeCurrentUserNotificationSettings();
      return user;
    } catch (e) {
      debugPrint("Error in registration: ${e.toString()}");
      rethrow;
    } finally {
      registrationFlowInProgress.value = false;
    }
  }

  Future<List<String>> _uploadRegistrationProfileImages({
    required String uid,
    required List<XFile> images,
  }) async {
    final limitedImages = images.take(6).toList(growable: false);
    final urls = <String>[];

    for (var i = 0; i < limitedImages.length; i++) {
      final imageFile = limitedImages[i];
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Selected profile image is empty.');
      }

      final lowered = imageFile.name.toLowerCase();
      String ext = 'jpg';
      String contentType = 'image/jpeg';
      if (lowered.endsWith('.png')) {
        ext = 'png';
        contentType = 'image/png';
      } else if (lowered.endsWith('.webp')) {
        ext = 'webp';
        contentType = 'image/webp';
      }

      final ref = _storage
          .ref()
          .child('users/$uid/profile_images/profile_${i + 1}.$ext');

      await ref.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );

      urls.add(await ref.getDownloadURL());
    }

    if (urls.isEmpty) {
      throw StateError('At least one profile image is required.');
    }

    return urls;
  }

  // פונקציית התחברות (Login)
  Future<User?> loginWithEmailAndPassword(String email, String password) async {
    final resolvedEmail = _normalizeEmail(email);
    final isRealEmailLogin = resolvedEmail.isNotEmpty &&
        !resolvedEmail.endsWith('@$phoneAuthDomain');
    if (resolvedEmail.isNotEmpty) {
      final preflight = await preflightLoginGate(resolvedEmail);
      if (preflight == LoginPreflightGate.ageRestricted) {
        if (_auth.currentUser != null) {
          await _auth.signOut();
        }
        throw FirebaseAuthException(
          code: ageRestrictedCode,
          message: 'האפליקציה מיועדת לגילאי $minimumUserAge ומעלה בלבד.',
        );
      }
      if (preflight == LoginPreflightGate.pendingVerification) {
        if (_auth.currentUser != null) {
          await _auth.signOut();
        }
        throw FirebaseAuthException(
          code: emailNotVerifiedCode,
          message: 'האימייל שלך עדיין לא אומת. שלחנו קישור/קוד אימות שוב.',
        );
      }
      if (preflight == LoginPreflightGate.pendingProfile) {
        if (_auth.currentUser != null) {
          await _auth.signOut();
        }
        throw FirebaseAuthException(
          code: registrationIncompleteCode,
          message: 'המשתמש קיים אבל תהליך ההרשמה לא הושלם.',
        );
      }
      if (preflight == LoginPreflightGate.expired) {
        if (_auth.currentUser != null) {
          await _auth.signOut();
        }
        throw FirebaseAuthException(
          code: emailNotVerifiedCode,
          message: 'תהליך ההרשמה פג תוקפו. שלחנו מייל אימות חדש כדי להמשיך.',
        );
      }
    }

    try {
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = result.user;
      if (user == null) {
        return null;
      }

      if (isRealEmailLogin && !user.emailVerified) {
        await _auth.signOut();
        throw FirebaseAuthException(
          code: emailNotVerifiedCode,
          message: 'יש לאמת את מייל הגיבוי לפני התחברות באמצעותו.',
        );
      }

      final onboardingStep = await _resolveOnboardingStepForUid(user.uid);
      if (onboardingStep == OnboardingStep.expired ||
          isOnboardingExpired(
              (await _db.collection('users').doc(user.uid).get()).data() ??
                  <String, dynamic>{})) {
        await _setOnboardingStepForUid(
          user.uid,
          step: OnboardingStep.pendingVerification,
        );
        throw FirebaseAuthException(
          code: registrationIncompleteCode,
          message: 'תהליך ההרשמה פג תוקפו. יש להמשיך את השלמת הפרופיל.',
        );
      }

      if (onboardingStep != OnboardingStep.active) {
        await _ensureUserOnboardingState(
          user,
          step: onboardingStep == OnboardingStep.pendingProfile
              ? OnboardingStep.pendingProfile
              : OnboardingStep.pendingVerification,
        );
        throw FirebaseAuthException(
          code: registrationIncompleteCode,
          message: 'המשתמש קיים אבל תהליך ההרשמה לא הושלם.',
        );
      }

      final verifiedUser = await requireCompletedRegistration(user);
      // Do not block login flow on best-effort profile/settings sync.
      unawaited(ensureCurrentUserPublicProfile());
      unawaited(
          _notificationService.initializeCurrentUserNotificationSettings());
      return verifiedUser;
    } on FirebaseAuthException catch (error, stackTrace) {
      logAuthFailure('loginWithEmailAndPassword', error, stackTrace);
      rethrow;
    } catch (error, stackTrace) {
      logAuthFailure('loginWithEmailAndPassword', error, stackTrace);
      rethrow;
    }
  }

  Future<User?> loginWithEmailOrUsername(
      String emailOrUsername, String password) async {
    final input = emailOrUsername.trim();
    if (input.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'יש להזין אימייל או שם משתמש.',
      );
    }

    final isEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(input);
    final email = isEmail ? input : phoneAuthEmail(input);
    final isRealEmailLogin =
        isEmail && !_normalizeEmail(email).endsWith('@$phoneAuthDomain');
    if (email.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-phone-number',
        message: 'יש להזין מספר טלפון או כתובת מייל תקינים.',
      );
    }

    final preflight = await preflightLoginGate(email);
    if (preflight == LoginPreflightGate.ageRestricted) {
      if (_auth.currentUser != null) {
        await _auth.signOut();
      }
      throw FirebaseAuthException(
        code: ageRestrictedCode,
        message: 'האפליקציה מיועדת לגילאי $minimumUserAge ומעלה בלבד.',
      );
    }
    if (preflight == LoginPreflightGate.pendingVerification) {
      if (_auth.currentUser != null) {
        await _auth.signOut();
      }
      throw FirebaseAuthException(
        code: emailNotVerifiedCode,
        message: 'האימייל שלך עדיין לא אומת. שלחנו קישור/קוד אימות שוב.',
      );
    }
    if (preflight == LoginPreflightGate.pendingProfile) {
      if (_auth.currentUser != null) {
        await _auth.signOut();
      }
      throw FirebaseAuthException(
        code: registrationIncompleteCode,
        message: 'המשתמש קיים אבל תהליך ההרשמה לא הושלם.',
      );
    }
    if (preflight == LoginPreflightGate.expired) {
      if (_auth.currentUser != null) {
        await _auth.signOut();
      }
      throw FirebaseAuthException(
        code: emailNotVerifiedCode,
        message: 'תהליך ההרשמה פג תוקפו. שלחנו מייל אימות חדש כדי להמשיך.',
      );
    }

    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = result.user;
      if (user == null) {
        return null;
      }

      if (isRealEmailLogin && !user.emailVerified) {
        await _auth.signOut();
        throw FirebaseAuthException(
          code: emailNotVerifiedCode,
          message: 'יש לאמת את מייל הגיבוי לפני התחברות באמצעותו.',
        );
      }

      final onboardingStep = await _resolveOnboardingStepForUid(user.uid);
      if (onboardingStep == OnboardingStep.expired ||
          isOnboardingExpired(
              (await _db.collection('users').doc(user.uid).get()).data() ??
                  <String, dynamic>{})) {
        await _setOnboardingStepForUid(
          user.uid,
          step: OnboardingStep.pendingVerification,
        );
        throw FirebaseAuthException(
          code: registrationIncompleteCode,
          message: 'תהליך ההרשמה פג תוקפו. יש להמשיך את השלמת הפרופיל.',
        );
      }

      if (onboardingStep != OnboardingStep.active) {
        await _ensureUserOnboardingState(
          user,
          step: onboardingStep == OnboardingStep.pendingProfile
              ? OnboardingStep.pendingProfile
              : OnboardingStep.pendingVerification,
        );
        throw FirebaseAuthException(
          code: registrationIncompleteCode,
          message: 'המשתמש קיים אך תהליך ההרשמה לא הושלם.',
        );
      }

      final verifiedUser = await requireCompletedRegistration(user);
      // Do not block login flow on best-effort profile/settings sync.
      unawaited(ensureCurrentUserPublicProfile());
      unawaited(
          _notificationService.initializeCurrentUserNotificationSettings());
      return verifiedUser;
    } on FirebaseAuthException catch (error, stackTrace) {
      logAuthFailure('loginWithEmailOrUsername', error, stackTrace);
      rethrow;
    } catch (error, stackTrace) {
      logAuthFailure('loginWithEmailOrUsername', error, stackTrace);
      rethrow;
    }
  }

  Future<void> sendPasswordResetForEmailOrUsername(
      String emailOrUsername) async {
    _assertAuthBoundToDefaultApp('sendPasswordResetForEmailOrUsername');
    final input = emailOrUsername.trim();
    if (input.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'יש להזין אימייל או שם משתמש.',
      );
    }

    final isEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(input);
    if (!isEmail) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'איפוס סיסמה באמצעות טלפון מתבצע בקוד SMS.',
      );
    }
    final email = _normalizeEmail(input);

    try {
      debugPrint(
        '[AuthService][sendPasswordResetForEmailOrUsername] sendPasswordResetEmail starting for email=$email, app=${_auth.app.name}',
      );
      await _auth.sendPasswordResetEmail(email: email);
      debugPrint(
        '[AuthService][sendPasswordResetForEmailOrUsername] sendPasswordResetEmail completed for email=$email, app=${_auth.app.name}',
      );
    } on FirebaseAuthException catch (error, stackTrace) {
      logAuthFailure('sendPasswordResetForEmailOrUsername', error, stackTrace);
      if (error.code == 'user-not-found') {
        return;
      }
      rethrow;
    } catch (error, stackTrace) {
      logAuthFailure('sendPasswordResetForEmailOrUsername', error, stackTrace);
      rethrow;
    }
  }

  Future<void> updateUsername(String uid, String username) async {
    final normalizedUsername = _normalizeUsername(username);
    if (normalizedUsername.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-username',
        message: 'שם משתמש לא תקין.',
      );
    }

    final usernameAlreadyTaken = await isUsernameTaken(
      normalizedUsername,
      excludeUid: uid,
    );

    if (usernameAlreadyTaken) {
      throw FirebaseAuthException(
        code: 'username-already-in-use',
        message: 'שם המשתמש כבר תפוס.',
      );
    }

    final userRef = _db.collection('users').doc(uid);
    final userPublicRef = _db.collection('users_public').doc(uid);
    final batch = _db.batch();
    batch.update(userRef, {
      'username': normalizedUsername,
      'usernameLowercase': normalizedUsername,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(
      userPublicRef,
      {
        'username': normalizedUsername,
        'usernameLowercase': normalizedUsername,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  List<String> _normalizeProfileImageUrls(Iterable<String> rawUrls) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final raw in rawUrls) {
      final url = raw.trim();
      if (url.isEmpty) continue;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) {
        continue;
      }
      if (!seen.add(url)) continue;
      normalized.add(url);
      if (normalized.length >= 6) break;
    }
    return normalized;
  }

  Future<List<String>> _uploadAdditionalProfileImages({
    required String uid,
    required List<XFile> images,
  }) async {
    if (images.isEmpty) {
      return const <String>[];
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final uploadedUrls = <String>[];

    for (var i = 0; i < images.length; i++) {
      final imageFile = images[i];
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Selected profile image is empty.');
      }

      final lowered = imageFile.name.toLowerCase();
      String ext = 'jpg';
      String contentType = 'image/jpeg';
      if (lowered.endsWith('.png')) {
        ext = 'png';
        contentType = 'image/png';
      } else if (lowered.endsWith('.webp')) {
        ext = 'webp';
        contentType = 'image/webp';
      }

      final ref = _storage
          .ref()
          .child('users/$uid/profile_images/edit_${now}_${i + 1}.$ext');
      await ref.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );
      uploadedUrls.add(await ref.getDownloadURL());
    }

    return uploadedUrls;
  }

  Future<void> updateUserProfile({
    required String uid,
    required String displayName,
    required String username,
    required String bio,
    required bool allowGroupInvite,
    bool? isPrivate,
    List<String> existingProfileImageUrls = const <String>[],
    List<XFile> newProfileImageFiles = const <XFile>[],
    int? primaryImageIndexInCombined,
  }) async {
    final normalizedUsername = _normalizeUsername(username);
    if (normalizedUsername.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-username',
        message: 'שם משתמש לא תקין.',
      );
    }

    final usernameAlreadyTaken = await isUsernameTaken(
      normalizedUsername,
      excludeUid: uid,
    );
    if (usernameAlreadyTaken) {
      throw FirebaseAuthException(
        code: 'username-already-in-use',
        message: 'שם המשתמש כבר תפוס.',
      );
    }

    final nameParts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final firstName = nameParts.isNotEmpty ? nameParts.first : '';
    final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    final currentProfile = await _db.collection('users').doc(uid).get();
    final currentData = currentProfile.data() ?? const <String, dynamic>{};
    final currentPrivateValue = (currentData['isPrivate'] as bool?) ?? false;
    final resolvedIsPrivate = isPrivate ?? currentPrivateValue;

    final currentStoredProfileImageUrls =
        ((currentData['profileImageUrls'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .toList(growable: false);
    final currentProfilePictureUrl =
        (currentData['profilePictureUrl'] as String? ?? '').trim();

    final normalizedExistingUrls = _normalizeProfileImageUrls(
      existingProfileImageUrls.isNotEmpty
          ? existingProfileImageUrls
          : <String>[
              if (currentProfilePictureUrl.isNotEmpty) currentProfilePictureUrl,
              ...currentStoredProfileImageUrls,
            ],
    );

    final remainingSlots = 6 - normalizedExistingUrls.length;
    final limitedNewFiles = remainingSlots <= 0
        ? const <XFile>[]
        : newProfileImageFiles.take(remainingSlots).toList(growable: false);
    final uploadedNewUrls = await _uploadAdditionalProfileImages(
      uid: uid,
      images: limitedNewFiles,
    );

    final combinedProfileImageUrls = <String>[
      ...normalizedExistingUrls,
      ...uploadedNewUrls,
    ];

    if (combinedProfileImageUrls.length > 1) {
      final preferredIndex = primaryImageIndexInCombined ?? 0;
      final clampedIndex = preferredIndex.clamp(
        0,
        combinedProfileImageUrls.length - 1,
      );
      final preferredUrl = combinedProfileImageUrls.removeAt(clampedIndex);
      combinedProfileImageUrls.insert(0, preferredUrl);
    }

    final profilePictureUrl = combinedProfileImageUrls.isNotEmpty
        ? combinedProfileImageUrls.first
        : '';

    final normalizedDisplayName = displayName.trim();
    final normalizedBio = bio.trim();

    final payload = <String, dynamic>{
      'firstName': firstName,
      'lastName': lastName,
      'displayName': normalizedDisplayName,
      'bio': normalizedBio,
      'username': normalizedUsername,
      'usernameLowercase': normalizedUsername,
      'allowGroupInvite': allowGroupInvite,
      'isPrivate': resolvedIsPrivate,
      'profilePictureUrl': profilePictureUrl,
      'profileImageUrls': combinedProfileImageUrls,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final userRef = _db.collection('users').doc(uid);
    final userPublicRef = _db.collection('users_public').doc(uid);
    final batch = _db.batch();
    batch.set(userRef, payload, SetOptions(merge: true));
    batch.set(
      userPublicRef,
      _publicProfilePayload(
        uid: uid,
        username: normalizedUsername,
        firstName: firstName,
        lastName: lastName,
        displayName: normalizedDisplayName,
        profilePictureUrl: profilePictureUrl,
        profileImageUrls: combinedProfileImageUrls,
        bio: normalizedBio,
        isPrivate: resolvedIsPrivate,
      ),
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  Future<void> updatePrivateProfile({
    required String uid,
    required bool isPrivate,
  }) async {
    await _db.collection('users').doc(uid).set(
      {'isPrivate': isPrivate, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
    await _db.collection('users_public').doc(uid).set(
      {'isPrivate': isPrivate, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<void> updateContactDetails({
    required String uid,
    String? phone,
    String? email,
    String? birthDate,
  }) async {
    if (birthDate != null) {
      _validateBirthDate(birthDate, required: false);
    }

    final payload = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp()
    };
    if (phone != null) {
      payload['phone'] = phone.trim();
    }
    if (email != null) {
      payload['email'] = email.trim();
    }
    if (birthDate != null) {
      payload['birthDate'] = birthDate.trim();
    }

    await _db
        .collection('users')
        .doc(uid)
        .set(payload, SetOptions(merge: true));
  }

  void _validateBirthDate(String value, {required bool required}) {
    final normalized = value.trim();
    if (normalized.isEmpty && !required) return;

    final birthDate = parseStoredBirthDate(normalized);
    if (birthDate == null) {
      throw FirebaseAuthException(
        code: 'invalid-birth-date',
        message: 'תאריך הלידה אינו תקין.',
      );
    }
  }

  Future<void> deleteCurrentAccount({String deletionReason = ''}) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to delete account.',
      );
    }

    final uid = user.uid;
    final normalizedReason = deletionReason.trim();
    final userRef = _db.collection('users').doc(uid);
    final userPublicRef = _db.collection('users_public').doc(uid);

    // Snapshot current profile docs so we can roll back if auth deletion fails.
    final userBeforeDelete = await userRef.get();
    final userPublicBeforeDelete = await userPublicRef.get();

    if (normalizedReason.isNotEmpty) {
      await _db.collection('account_deletion_feedback').add({
        'uid': uid,
        'reason': normalizedReason,
        'email': (user.email ?? '').trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    final payload = <String, dynamic>{
      'isDeleted': true,
      'displayName': 'משתמש מחוק',
      'username': '',
      'bio': '',
      'profilePictureUrl': '',
      'profileImageUrls': <String>[],
      'phone': '',
      'email': '',
      'birthDate': '',
      'allowGroupInvite': false,
      'updatedAt': FieldValue.serverTimestamp(),
      'deletedAt': FieldValue.serverTimestamp(),
    };

    await userRef.set(payload, SetOptions(merge: true));
    await userPublicRef.set(
      {
        'isDeleted': true,
        'displayName': 'משתמש מחוק',
        'username': '',
        'bio': '',
        'profilePictureUrl': '',
        'profileImageUrls': <String>[],
        'updatedAt': FieldValue.serverTimestamp(),
        'deletedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    try {
      // Remove the Firebase Authentication account as well,
      // otherwise the email remains reserved by Auth.
      await user.delete();
    } on FirebaseAuthException catch (e) {
      // Avoid partial state: if auth deletion fails, restore profile docs.
      if (userBeforeDelete.exists) {
        await userRef.set(userBeforeDelete.data()!);
      } else {
        await userRef.delete();
      }

      if (userPublicBeforeDelete.exists) {
        await userPublicRef.set(userPublicBeforeDelete.data()!);
      } else {
        await userPublicRef.delete();
      }

      if (e.code == 'requires-recent-login') {
        throw FirebaseAuthException(
          code: 'requires-recent-login',
          message: 'נדרש להתחבר מחדש כדי למחוק את החשבון.',
        );
      }
      rethrow;
    }

    await _auth.signOut();
  }

  // התנתקות מהמערכת
  Future<void> signOut() async {
    await _auth.signOut();
  }
}
