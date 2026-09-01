import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'firebase_options.dart';
import 'feed_screen.dart';
import 'login_screen.dart';
import 'services/auth_service.dart';
import 'services/share_flow_log_service.dart';
import 'services/theme_mode_service.dart';
import 'services/location_service.dart';
import 'services/notification_runtime_service.dart';
import 'services/presence_service.dart';
import 'services/app_navigator.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'services/challenge_notifications_orchestrator.dart';
import 'widgets/adaptive_viewport.dart';
import 'widgets/animated_infinity_splash_screen.dart';
import 'widgets/in_app_notification_overlay.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationRuntimeService.handleBackgroundMessage(message);
}

const bool _useAuthEmulator = bool.fromEnvironment(
  'USE_AUTH_EMULATOR',
  defaultValue: false,
);

bool _isMissingAndroidFirebaseOptionsError(PlatformException e) {
  final message = (e.message ?? '').toLowerCase();
  return message.contains('failed to load firebaseoptions from resource');
}

Future<void> _configureAuthConnection() async {
  if (kIsWeb || !_useAuthEmulator) {
    return;
  }

  final auth = FirebaseAuth.instanceFor(app: Firebase.app());
  final emulatorHost = defaultTargetPlatform == TargetPlatform.android
      ? '10.0.2.2'
      : '127.0.0.1';
  auth.useAuthEmulator(emulatorHost, 9099);
}

class AppColors {
  static const Color background = Color(0xFF070B12);
  static const Color backgroundElevated = Color(0xFF101827);
  static const Color primaryPurple = Color(0xFF9E7CFF);
  static const Color secondaryBlue = Color(0xFF53C1F9);
  static const Color warningOrange = Color(0xFFF87B4F);
  static const Color tertiaryContainer = Color(0xFF151E2D);
  static const Color textPrimary = Color(0xFFF5F7FA);
  static const Color textSecondary = Color(0xFFB6C0CF);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ShareFlowLogService.installGlobalHandlers();
  await ShareFlowLogService.log('APP_MAIN_START');

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await ShareFlowLogService.log('FIREBASE_INITIALIZED');
    if (!kIsWeb) {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
    }
    await ShareFlowLogService.log('APP_CHECK_ACTIVATED');

    FirebaseFirestore.instance.settings =
        const Settings(persistenceEnabled: true);
    await ShareFlowLogService.log('FIRESTORE_PERSISTENCE_ENABLED');

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _configureAuthConnection();
    await ShareFlowLogService.log('AUTH_CONNECTION_CONFIGURED');
    await NotificationRuntimeService.instance.initialize();
    await ShareFlowLogService.log('NOTIFICATION_RUNTIME_INITIALIZED');
    await ThemeModeService.instance.load();
    await ShareFlowLogService.log('THEME_MODE_LOADED');
    runApp(const MyApp());
    await ShareFlowLogService.log('RUN_APP_CALLED');
  } on PlatformException catch (e) {
    await ShareFlowLogService.log(
      'APP_INIT_PLATFORM_EXCEPTION',
      data: <String, Object?>{
        'code': e.code,
        'message': e.message,
        'details': e.details,
      },
    );
    final isMissingAndroidFirebaseOptions =
        _isMissingAndroidFirebaseOptionsError(e);
    runApp(
      BootstrapErrorApp(
        message: isMissingAndroidFirebaseOptions
            ? 'Firebase �� ����� ���������. �� ������ google-services.json ����� android/app ������� Google Services �-Gradle.\n\n${e.message ?? e.code}'
            : '����� ����� ��������: ${e.message ?? e.code}',
      ),
    );
  } catch (e) {
    await ShareFlowLogService.log(
      'APP_INIT_EXCEPTION',
      data: <String, Object?>{'error': e},
    );
    runApp(
      BootstrapErrorApp(
        message: '����� �����: $e',
      ),
    );
  }
}

class BootstrapErrorApp extends StatelessWidget {
  const BootstrapErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF070B12),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF101827),
                  borderRadius: BorderRadius.circular(18),
                  border:
                      Border.all(color: const Color(0xFF53C1F9), width: 0.8),
                ),
                child: Text(
                  message,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style:
                      const TextStyle(color: Color(0xFFF5F7FA), fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final ThemeModeService _themeModeService;

  bool _isTapInsideFocusedInputZone(PointerDownEvent event) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) {
      return false;
    }

    final focusedWidget = focus.context?.widget;
    if (focusedWidget is! EditableText) {
      return false;
    }

    final renderObject = focus.context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }

    final inputTopLeft = renderObject.localToGlobal(Offset.zero);
    final inputRect = inputTopLeft & renderObject.size;

    // Expand around the active field to include typical composer controls
    // such as send/media buttons next to the text input.
    final safeZone = Rect.fromLTRB(
      inputRect.left - 180,
      inputRect.top - 24,
      inputRect.right + 180,
      inputRect.bottom + 28,
    );
    return safeZone.contains(event.position);
  }

  @override
  void initState() {
    super.initState();
    _themeModeService = ThemeModeService.instance;
  }

  ThemeData _buildDarkTheme() {
    const colorScheme = ColorScheme.dark(
      primary: AppColors.primaryPurple,
      secondary: AppColors.secondaryBlue,
      error: AppColors.warningOrange,
      surface: AppColors.backgroundElevated,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: AppColors.textPrimary,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      primaryColor: AppColors.primaryPurple,
      colorScheme: colorScheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 34,
            height: 1.1),
        headlineMedium: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 28,
            height: 1.12),
        headlineSmall: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 24,
            height: 1.15),
        titleLarge: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            height: 1.2),
        titleMedium: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 17,
            height: 1.24),
        titleSmall: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 15,
            height: 1.24),
        bodyLarge: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w500,
            height: 1.4),
        bodyMedium: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w400,
            height: 1.4),
        bodySmall: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w400,
            height: 1.35),
        labelLarge: TextStyle(
            color: AppColors.textPrimary, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(
            color: AppColors.textPrimary, fontWeight: FontWeight.w500),
        labelSmall: TextStyle(
            color: AppColors.textSecondary, fontWeight: FontWeight.w400),
      ),
      cardTheme: CardThemeData(
        color: AppColors.backgroundElevated.withValues(alpha: 0.9),
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: Colors.black.withValues(alpha: 0.22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryPurple,
          foregroundColor: Colors.white,
          minimumSize: const Size(132, 52),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.35),
              width: 0.9),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.secondaryBlue,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.tertiaryContainer.withValues(alpha: 0.72),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.7),
              width: 1.0),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.backgroundElevated,
        selectedItemColor: AppColors.primaryPurple,
        unselectedItemColor: AppColors.textSecondary.withValues(alpha: 0.72),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.backgroundElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.textSecondary.withValues(alpha: 0.14),
        thickness: 0.7,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.tertiaryContainer.withValues(alpha: 0.8),
        selectedColor: AppColors.primaryPurple,
        disabledColor: AppColors.background,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.3),
              width: 0.8),
        ),
        labelStyle: const TextStyle(
            color: AppColors.textPrimary, fontWeight: FontWeight.w600),
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        brightness: Brightness.dark,
      ),
    );
  }

  ThemeData _buildLightTheme() {
    const lightBg = Color(0xFFF4F7FC);
    const lightSurface = Color(0xFFFFFFFF);
    const lightText = Color(0xFF1D2742);
    const lightTextSecondary = Color(0xFF5B6883);

    const colorScheme = ColorScheme.light(
      primary: AppColors.primaryPurple,
      secondary: AppColors.secondaryBlue,
      error: AppColors.warningOrange,
      surface: lightSurface,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: lightText,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBg,
      canvasColor: lightBg,
      primaryColor: AppColors.primaryPurple,
      colorScheme: colorScheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: lightBg,
        foregroundColor: lightText,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w800,
            fontSize: 34,
            height: 1.1),
        headlineMedium: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w800,
            fontSize: 28,
            height: 1.12),
        headlineSmall: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w700,
            fontSize: 24,
            height: 1.15),
        titleLarge: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            height: 1.2),
        titleMedium: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w600,
            fontSize: 17,
            height: 1.24),
        titleSmall: TextStyle(
            color: lightText,
            fontWeight: FontWeight.w600,
            fontSize: 15,
            height: 1.24),
        bodyLarge: TextStyle(
            color: lightText, fontWeight: FontWeight.w500, height: 1.4),
        bodyMedium: TextStyle(
            color: lightText, fontWeight: FontWeight.w400, height: 1.4),
        bodySmall: TextStyle(
            color: lightTextSecondary,
            fontWeight: FontWeight.w400,
            height: 1.35),
        labelLarge: TextStyle(color: lightText, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: lightText, fontWeight: FontWeight.w500),
        labelSmall:
            TextStyle(color: lightTextSecondary, fontWeight: FontWeight.w400),
      ),
      cardTheme: CardThemeData(
        color: lightSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: const Color(0xFF26345A).withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryPurple,
          foregroundColor: Colors.white,
          minimumSize: const Size(132, 52),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: lightText,
          side: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.35),
              width: 0.9),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.secondaryBlue,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFE8EDF7),
        labelStyle: const TextStyle(color: lightTextSecondary),
        hintStyle: const TextStyle(color: lightTextSecondary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.6),
              width: 1.0),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: lightSurface,
        selectedItemColor: AppColors.primaryPurple,
        unselectedItemColor: lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0x1F1D2742),
        thickness: 0.7,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFE7EDF8),
        selectedColor: AppColors.primaryPurple,
        disabledColor: const Color(0xFFE4EAF5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
              color: AppColors.secondaryBlue.withValues(alpha: 0.26),
              width: 0.8),
        ),
        labelStyle:
            const TextStyle(color: lightText, fontWeight: FontWeight.w600),
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        brightness: Brightness.light,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _themeModeService,
      builder: (context, _) {
        return MaterialApp(
          title: 'Pastel App',
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          builder: (context, child) {
            return AdaptiveViewport(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (KeyboardDismissController.suspendGlobalDismiss) {
                    return;
                  }
                  if (_isTapInsideFocusedInputZone(event)) {
                    return;
                  }
                  final focus = FocusManager.instance.primaryFocus;
                  if (focus == null) {
                    return;
                  }
                  focus.unfocus();
                },
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: InAppNotificationOverlay(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          },
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          themeMode: _themeModeService.themeMode,
          home: const StartupGate(),
        );
      },
    );
  }
}

class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

bool shouldShowDynamicStartupSplash({
  required bool hasResolvedAuth,
  required User? user,
  required OnboardingStep onboardingStep,
}) {
  return hasResolvedAuth &&
      user != null &&
      onboardingStep == OnboardingStep.active;
}

class _StartupGateState extends State<StartupGate> {
  Timer? _authResolveTimeoutTimer;
  bool _authResolveTimedOut = false;

  @override
  void initState() {
    super.initState();
    _authResolveTimeoutTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) {
        return;
      }
      _authResolveTimedOut = true;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _authResolveTimeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.registrationFlowInProgress,
      builder: (context, isRegistrationFlowInProgress, _) {
        if (isRegistrationFlowInProgress) {
          // Keep the app in a neutral state while registration is mid-flow.
          // This prevents background routing to authenticated screens.
          return const AnimatedInfinitySplashScreen();
        }

        return StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          initialData: FirebaseAuth.instance.currentUser,
          builder: (context, authSnapshot) {
            final hasResolvedAuth =
                authSnapshot.connectionState != ConnectionState.waiting ||
                    _authResolveTimedOut;
            final user = authSnapshot.data;

            if (authSnapshot.connectionState != ConnectionState.waiting) {
              _authResolveTimeoutTimer?.cancel();
              _authResolveTimeoutTimer = null;
            }

            if (!hasResolvedAuth) {
              return const AnimatedInfinitySplashScreen();
            }

            if (user != null) {
              return KeyedSubtree(
                key: ValueKey(user.uid),
                child: const VerifiedSessionGate(),
              );
            }

            return const LoginScreen();
          },
        );
      },
    );
  }
}

class AuthenticatedAppShell extends StatefulWidget {
  const AuthenticatedAppShell({super.key});

  @override
  State<AuthenticatedAppShell> createState() => _AuthenticatedAppShellState();
}

class _AuthenticatedAppShellState extends State<AuthenticatedAppShell> {
  final PresenceService _presenceService = PresenceService();
  final LocationService _locationService = LocationService();

  @override
  void initState() {
    super.initState();
    _presenceService.start();
    _locationService.start();
    ChallengeNotificationsOrchestrator.instance.start();
  }

  @override
  void dispose() {
    _presenceService.stop();
    _locationService.stop();
    ChallengeNotificationsOrchestrator.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const FeedScreen(
      allowSpontaneousPrompt: true,
      initialSpontaneousPromptDelay: Duration(seconds: 1),
    );
  }
}

class VerifiedSessionGate extends StatefulWidget {
  const VerifiedSessionGate({super.key});

  @override
  State<VerifiedSessionGate> createState() => _VerifiedSessionGateState();
}

class _VerifiedSessionGateState extends State<VerifiedSessionGate> {
  final AuthService _authService = AuthService();
  late final Future<OnboardingStep> _verificationCheck;

  @override
  void initState() {
    super.initState();
    _verificationCheck = _ensureVerifiedSession();
  }

  Future<OnboardingStep> _ensureVerifiedSession() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return OnboardingStep.pendingVerification;
    }

    if (await _authService.canCurrentUserAccessApp()) {
      return OnboardingStep.active;
    }

    return await _authService.currentUserOnboardingStep();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OnboardingStep>(
      future: _verificationCheck,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AnimatedInfinitySplashScreen();
        }

        final onboardingStep =
            snapshot.data ?? OnboardingStep.pendingVerification;
        final currentUser = FirebaseAuth.instance.currentUser;
        final isReady =
            onboardingStep == OnboardingStep.active && currentUser != null;

        if (isReady) {
          return const AuthenticatedAppShell();
        }

        return const LoginScreen();
      },
    );
  }
}
