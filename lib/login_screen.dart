import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hundred_version1/services/auth_service.dart';

import 'feed_screen.dart';
import 'register_screen.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'widgets/animated_infinity_splash_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

bool shouldBlockLoginForState({
  required bool isEmailVerified,
  required OnboardingStep onboardingStep,
}) {
  return !isEmailVerified ||
      onboardingStep == OnboardingStep.pendingVerification ||
      onboardingStep == OnboardingStep.pendingProfile ||
      onboardingStep == OnboardingStep.expired;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color _bgTop = Color(0xFF0B1222);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _primary = Color(0xFF7B79FF);
  static const Color _accent = Color(0xFF53D9FF);
  static const Color _textPrimary = Color(0xFFEAF0FF);
  static const Color _textSecondary = Color(0xFFAAB7E8);
  static const Color _fieldFill = Color(0xFF141D2E);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final AuthService _authService = AuthService();

  bool _showError = false;
  bool _hidePassword = true;
  bool _animateBg = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final pendingMessage = AuthService.consumePendingAuthUiMessage();
      if (pendingMessage != null && pendingMessage.trim().isNotEmpty) {
        setState(() {
          _showError = true;
          _errorMessage = pendingMessage;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(pendingMessage)),
        );
      }

      if (!mounted) return;
      setState(() {
        _animateBg = true;
      });
    });
  }

  void _toggleBgAnimation() {
    if (!mounted) return;
    setState(() {
      _animateBg = !_animateBg;
    });
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _tapHitsEditable(PointerDownEvent event) {
    final hitTestResult = HitTestResult();
    GestureBinding.instance.hitTest(hitTestResult, event.position);
    for (final entry in hitTestResult.path) {
      if (entry.target is RenderEditable) {
        return true;
      }
    }
    return false;
  }

  void _dismissKeyboardOnBackgroundTap(PointerDownEvent event) {
    if (_tapHitsEditable(event)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _routeToUnverifiedLoginGate({
    required String email,
    required String password,
    User? user,
  }) async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    User? userToVerify = user ?? FirebaseAuth.instance.currentUser;

    if (userToVerify != null) {
      try {
        await userToVerify.reload();
        userToVerify = FirebaseAuth.instance.currentUser ?? userToVerify;
      } catch (_) {
        // Ignore reload failures and continue with the signed-in user snapshot.
      }
    }

    try {
      if (userToVerify != null && !userToVerify.emailVerified) {
        await userToVerify.sendEmailVerification();
        debugPrint(
          '[LoginScreen][_routeToUnverifiedLoginGate] verification email sent to ${userToVerify.email}',
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[LoginScreen][_routeToUnverifiedLoginGate] sendEmailVerification failed: $error',
      );
      debugPrint(stackTrace.toString());
    }

    Navigator.of(context, rootNavigator: true).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EmailVerificationGateScreen(
          email: email,
          password: password,
          onExitToLogin: () {
            rootNavigator.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
            );
          },
        ),
      ),
    );
  }

  String _describeLoginFailure(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-email':
          return 'כתובת המייל או שם המשתמש שהוזנו אינם תקינים. / The email or username is invalid. Check that it matches the account exactly.';
        case 'user-not-found':
          return 'לא נמצא חשבון עם הפרטים שהוזנו. / No account was found with the provided details. Check that the account exists in the active Firebase project.';
        case 'wrong-password':
          return 'הסיסמה שהזנת שגויה. / The password is incorrect. Please try again and make sure it matches exactly.';
        case 'invalid-credential':
          return 'פרטי הכניסה לא תקינים או שהחשבון שייך לפרויקט Firebase אחר. / The login credentials are invalid or belong to a different Firebase project. Verify the environment and the same account.';
        case 'user-disabled':
          return 'החשבון מושבת או נחסם. / This account has been disabled or blocked. Please use an active account or contact support.';
        case 'too-many-requests':
          return 'ניסיונות הכניסה נעצרו לזמן קצר עקב הגנה. / Too many attempts were made. Please wait a moment and try again.';
        case 'network-request-failed':
          return 'אין חיבור אינטרנט או יש בעיית רשת. / No internet connection or network problem. Check your connection and try again.';
        case 'email-not-verified':
          return 'האימייל עדיין לא אומת. / Your email has not been verified yet. Please verify it and try again.';
        case 'registration-incomplete':
          return 'החשבון עדיין לא הושלם. / Your account is not complete yet. Please finish the registration steps and try again.';
        case 'session-expired':
          return 'הסשן פג תוקף. / Your login session has expired. Please sign in again.';
        case 'account-exists-with-different-credential':
          return 'החשבון כבר קיים בשיטת אימות אחרת. / This account already exists with a different sign-in method. Use the same method and project.';
        case 'operation-not-allowed':
          return 'כניסה עם פרטי חשבון אלה אינה מאופשרת. / Sign-in with these credentials is not allowed in this Firebase project.';
        case 'app-not-authorized':
          return 'האפליקציה אינה מאושרת לשימוש ב-Firebase Auth. / This app is not authorized to use Firebase Auth in this project.';
        case 'permission-denied':
          return 'הגישה ל-Firebase נדחתה. / Firebase access was denied. Check project permissions and configuration.';
        case 'internal-error':
          return 'שגיאת שרת פנימית של Firebase. / Internal Firebase server error. Please try again in a moment.';
        case 'unknown':
          return 'אירעה שגיאה לא ידועה בהתחברות. / An unknown login error occurred. Please verify the account and try again.';
        default:
          return 'ההתחברות נכשלה. / Login failed. Please check the login details and try again.';
      }
    }

    if (error is PlatformException) {
      final message = (error.message ?? '').trim();
      if (message.toLowerCase().contains('network')) {
        return 'אין חיבור אינטרנט או יש בעיית רשת. / No internet connection or network issue. Check your network and try again.';
      }
      return 'התחברות נכשלה עקב שגיאת מערכת. / Login failed due to a system error. Please try again in a moment.';
    }

    return 'ההתחברות נכשלה. / Login failed. Please check the account details and try again.';
  }

  Future<void> _onLoginPressed() async {
    final emailOrUsername = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (emailOrUsername.isEmpty || password.isEmpty) {
      const message =
          'נא למלא מייל / Mail או שם משתמש וסיסמה / Password. / Please enter email / mail or username and password.';
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(message)),
      );
      return;
    }

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    String resolvedEmail = emailOrUsername;
    if (!emailOrUsername.contains('@')) {
      resolvedEmail =
          await _authService.resolveEmailForUsername(emailOrUsername);
    }

    if (resolvedEmail.isEmpty) {
      resolvedEmail = emailOrUsername;
    }

    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: resolvedEmail,
        password: password,
      );

      final user = userCredential.user;
      if (user == null) {
        return;
      }

      final onboardingStep = await _authService.currentUserOnboardingStep();
      final shouldBlockLogin = shouldBlockLoginForState(
        isEmailVerified: user.emailVerified,
        onboardingStep: onboardingStep,
      );

      if (shouldBlockLogin) {
        await _routeToUnverifiedLoginGate(
          email: resolvedEmail,
          password: password,
          user: user,
        );
        return;
      }

      if (!mounted) return;
      setState(() {
        _showError = false;
        _errorMessage = null;
      });

      navigator.pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const _PostLoginSplashScreen(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      );
    } on FirebaseAuthException catch (e, stackTrace) {
      debugPrint('[LoginScreen][_onLoginPressed] FirebaseAuthException: $e');
      debugPrint('[LoginScreen][_onLoginPressed] stackTrace: $stackTrace');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'LoginScreen',
          context: ErrorDescription('FirebaseAuthException during login'),
          informationCollector: () sync* {
            yield ErrorDescription('Auth code: ${e.code}');
            yield ErrorDescription('Auth message: ${e.message ?? 'null'}');
          },
        ),
      );

      if (!mounted) return;

      final shouldOpenVerificationFlow =
          e.code == 'email-not-verified' || e.code == 'registration-incomplete';

      if (shouldOpenVerificationFlow) {
        await _routeToUnverifiedLoginGate(
          email: resolvedEmail,
          password: password,
          user: FirebaseAuth.instance.currentUser,
        );
        return;
      }

      final message = _describeLoginFailure(e);
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      if (messenger != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(message),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[LoginScreen][_onLoginPressed] error: $e');
      debugPrint('[LoginScreen][_onLoginPressed] stackTrace: $stackTrace');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'LoginScreen',
          context: ErrorDescription('Unexpected login error'),
        ),
      );
      if (!mounted) return;
      final message = _describeLoginFailure(e);
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      if (messenger != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(message),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _onForgotPasswordPressed() async {
    final seedValue = _usernameController.text.trim();
    final controller = TextEditingController(text: seedValue);
    final isLight = Theme.of(context).brightness == Brightness.light;

    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: isLight ? Colors.white : const Color(0xFF1A2435),
            title: Text(
              'איפוס סיסמה',
              style: TextStyle(color: isLight ? Colors.black : Colors.white),
            ),
            content: TextField(
              controller: controller,
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                hintText: 'אימייל או שם משתמש',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('שלח קישור איפוס'),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    final input = (value ?? '').trim();
    if (input.isEmpty || !mounted) {
      return;
    }

    try {
      await _authService.sendPasswordResetForEmailOrUsername(input);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('אם החשבון קיים, נשלח קישור לאיפוס סיסמה. בדוק גם בספאם.'),
        ),
      );
    } on FirebaseAuthException catch (e, stackTrace) {
      debugPrint(
          '[LoginScreen][_onForgotPasswordPressed] FirebaseAuthException: $e');
      debugPrint(
          '[LoginScreen][_onForgotPasswordPressed] stackTrace: $stackTrace');
      if (!mounted) return;
      if (e.code == 'invalid-email') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? 'לא הצלחנו לזהות כתובת מייל תקינה.'),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('לא הצלחנו לשלוח כרגע, נסה שוב בעוד רגע.'),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('[LoginScreen][_onForgotPasswordPressed] error: $e');
      debugPrint(
          '[LoginScreen][_onForgotPasswordPressed] stackTrace: $stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('לא הצלחנו לשלוח כרגע, נסה שוב בעוד רגע.')),
      );
    }
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      floatingLabelBehavior: FloatingLabelBehavior.never,
      label: Align(
        alignment: Alignment.centerRight,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: const TextStyle(color: _textSecondary),
        ),
      ),
      filled: true,
      fillColor: _fieldFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide:
            BorderSide(color: _accent.withValues(alpha: 0.16), width: 0.9),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide:
            BorderSide(color: _accent.withValues(alpha: 0.14), width: 0.9),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide:
            BorderSide(color: _accent.withValues(alpha: 0.66), width: 1.0),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final keyboardLift = (mediaQuery.viewInsets.bottom * 0.2).clamp(0.0, 64.0);
    final orbSizeA = (screenWidth * 0.78).clamp(220.0, 300.0);
    final orbSizeB = (screenWidth * 0.9).clamp(250.0, 350.0);
    return SwipeBackWrapper(
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: _bgBottom,
        body: SafeArea(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _dismissKeyboardOnBackgroundTap,
            child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(seconds: 8),
                  curve: Curves.easeInOut,
                  onEnd: _toggleBgAnimation,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin:
                          _animateBg ? Alignment.topLeft : Alignment.topRight,
                      end: _animateBg
                          ? Alignment.bottomRight
                          : Alignment.bottomLeft,
                      colors: const [_bgTop, Color(0xFF0E1627), _bgBottom],
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(seconds: 8),
                curve: Curves.easeInOut,
                top: _animateBg ? -130 : -95,
                left: _animateBg ? -85 : -45,
                child: Container(
                  width: orbSizeA,
                  height: orbSizeA,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x3853D9FF), Color(0x0053D9FF)],
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(seconds: 8),
                curve: Curves.easeInOut,
                bottom: _animateBg ? -145 : -110,
                right: _animateBg ? -95 : -55,
                child: Container(
                  width: orbSizeB,
                  height: orbSizeB,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x3B7B79FF), Color(0x007B79FF)],
                    ),
                  ),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child: AnimatedPadding(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          padding: EdgeInsets.only(bottom: keyboardLift),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 460),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 16),
                              child: Container(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 24, 20, 18),
                                decoration: BoxDecoration(
                                  color: const Color(0xD0121A2B),
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                      color: _accent.withValues(alpha: 0.12),
                                      width: 0.8),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.24),
                                      blurRadius: 28,
                                      offset: const Offset(0, 14),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text(
                                      'התחברות',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _textPrimary,
                                        fontSize: 30,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      'איזה כיף, חיכינו לך בחזרה',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _textSecondary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    TextField(
                                      controller: _usernameController,
                                      keyboardType: TextInputType.emailAddress,
                                      textInputAction: TextInputAction.next,
                                      textDirection: TextDirection.rtl,
                                      textAlign: TextAlign.right,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      style: const TextStyle(
                                          color: _textPrimary,
                                          fontWeight: FontWeight.w500),
                                      decoration: _inputDecoration(
                                          'מייל / Mail או שם משתמש'),
                                    ),
                                    const SizedBox(height: 14),
                                    TextField(
                                      controller: _passwordController,
                                      obscureText: _hidePassword,
                                      textDirection: TextDirection.rtl,
                                      textAlign: TextAlign.right,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      style: const TextStyle(
                                          color: _textPrimary,
                                          fontWeight: FontWeight.w500),
                                      decoration:
                                          _inputDecoration('סיסמה / Password')
                                              .copyWith(
                                        suffixIcon: IconButton(
                                          onPressed: () => setState(() =>
                                              _hidePassword = !_hidePassword),
                                          icon: Icon(
                                            _hidePassword
                                                ? Icons.visibility_off_rounded
                                                : Icons.visibility_rounded,
                                            color: _textSecondary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                        onPressed: _onForgotPasswordPressed,
                                        child: const Text(
                                          'שכחתי סיסמה',
                                          style: TextStyle(
                                            color: _accent,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const Text(
                                          'אין לך עדיין חשבון? - ',
                                          style: TextStyle(
                                              color: _textSecondary,
                                              fontSize: 13),
                                        ),
                                        InkWell(
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      const RegisterScreen()),
                                            );
                                          },
                                          child: const Text(
                                            'הרשמה',
                                            style: TextStyle(
                                              color: _accent,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 24),
                                    ElevatedButton(
                                      onPressed: _onLoginPressed,
                                      style: ElevatedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(20)),
                                        elevation: 0,
                                      ).copyWith(
                                        backgroundColor:
                                            WidgetStateProperty.resolveWith(
                                          (states) => states
                                                  .contains(WidgetState.pressed)
                                              ? _primary
                                              : const Color(0xFF6978FF),
                                        ),
                                      ),
                                      child: const Text(
                                        'כניסה',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16),
                                      ),
                                    ),
                                    AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 250),
                                      child: _showError
                                          ? Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 12),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      _errorMessage ??
                                                          'לא הצלחנו להתחבר. נסה שוב.',
                                                      style: const TextStyle(
                                                          color:
                                                              Colors.redAccent,
                                                          fontSize: 13),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                          : const SizedBox(height: 0),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

class EmailVerificationGateScreen extends StatefulWidget {
  const EmailVerificationGateScreen({
    super.key,
    required this.email,
    required this.password,
    required this.onExitToLogin,
  });

  final String email;
  final String password;
  final VoidCallback onExitToLogin;

  @override
  State<EmailVerificationGateScreen> createState() =>
      _EmailVerificationGateScreenState();
}

class _EmailVerificationGateScreenState
    extends State<EmailVerificationGateScreen> {
  bool _isBusy = false;
  bool _isResending = false;
  String? _errorMessage;
  DateTime _resendAvailableAt = DateTime.now().add(const Duration(minutes: 1));
  Timer? _resendTimer;

  int get _resendRemainingSeconds {
    final remaining = _resendAvailableAt.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  String get _resendCountdownLabel {
    final remaining = _resendRemainingSeconds;
    final minutes = (remaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (remaining % 60).toString().padLeft(2, '0');
    return 'ניתן לשלוח שוב בעוד $minutes:$seconds';
  }

  String _describeVerificationError(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'wrong-password':
          return 'הסיסמה שהזנת שגויה. נסה שוב.';
        case 'user-not-found':
          return 'לא נמצא משתמש עם הפרטים האלה.';
        case 'email-not-verified':
          return 'המייל עדיין לא אומת. אמת אותו ואז נסה שוב.';
        case 'network-request-failed':
          return 'אין חיבור לרשת. נסה שוב בעוד רגע.';
        default:
          return 'לא הצלחנו לאמת את המייל כרגע. נסה שוב בעוד רגע.';
      }
    }

    return 'לא הצלחנו לאמת את המייל כרגע. נסה שוב בעוד רגע.';
  }

  Future<void> _sendVerificationEmail() async {
    if (_isResending || DateTime.now().isBefore(_resendAvailableAt)) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _isResending = true;
      _errorMessage = null;
    });

    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: widget.email,
        password: widget.password,
      );

      final user = userCredential.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-not-found',
          message: 'לא נמצא משתמש פעיל לשליחת אימות.',
        );
      }

      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser ?? user;
      if (refreshedUser.emailVerified) {
        setState(() {
          _errorMessage = 'המייל כבר אומת. אפשר ללחוץ על "אימתתי" ולהמשיך.';
        });
      } else {
        await refreshedUser.sendEmailVerification();
      }
      if (!mounted) return;
      setState(() {
        _resendAvailableAt = DateTime.now().add(const Duration(minutes: 1));
      });
      _startResendTimer();
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _describeVerificationError(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _describeVerificationError(error);
      });
    }

    if (!mounted) return;
    setState(() {
      _isResending = false;
    });
  }

  void _startResendTimer() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {});
      if (!DateTime.now().isBefore(_resendAvailableAt)) {
        timer.cancel();
      }
    });
  }

  Future<void> _confirmVerification() async {
    if (!mounted) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: widget.email,
        password: widget.password,
      );

      final user = userCredential.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-not-found',
          message: 'לא נמצא משתמש נוכחי אחרי התחברות מחדש.',
        );
      }

      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      final isVerified = refreshedUser?.emailVerified ?? user.emailVerified;
      if (!mounted) return;

      if (isVerified) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RegisterScreen(
              initialStep: 1,
              prefilledEmail: widget.email,
              prefilledPassword: widget.password,
              onExitToLogin: widget.onExitToLogin,
            ),
          ),
        );
        return;
      }

      setState(() {
        _errorMessage =
            'עדיין לא זיהינו אימות. אנא פתח/י את המייל, אמת/י, ואז לחץ/י שוב על "אימתתי".';
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _describeVerificationError(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _describeVerificationError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _startResendTimer();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0B1222),
              Color(0xFF070B12),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101A2B).withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: const Color(0xFF53D9FF).withValues(alpha: 0.25),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF7B79FF).withValues(alpha: 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF7B79FF),
                              Color(0xFF53D9FF),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF53D9FF)
                                  .withValues(alpha: 0.35),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.mail_outline_rounded,
                          size: 36,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'אימות כתובת המייל',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFEAF0FF),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'שלחנו קישור אימות לכתובת:\n${widget.email}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: Color(0xFFAAB7E8),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '* אם המייל לא הגיע, יש לבדוק גם בתיבת הספאם.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Color(0xFF53D9FF),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isBusy ? null : _confirmVerification,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7B79FF),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: _isBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Text(
                                  'אימתתי',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: _resendRemainingSeconds > 0
                            ? Text(
                                _resendCountdownLabel,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFAAB7E8),
                                ),
                              )
                            : TextButton(
                                onPressed: _isResending
                                    ? null
                                    : _sendVerificationEmail,
                                child: _isResending
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                            Color(0xFF53D9FF),
                                          ),
                                        ),
                                      )
                                    : const Text(
                                        'שלח שוב',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF53D9FF),
                                        ),
                                      ),
                              ),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: widget.onExitToLogin,
                        child: const Text(
                          'חזור להתחברות',
                          style: TextStyle(
                            color: Color(0xFFEAF0FF),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PostLoginSplashScreen extends StatefulWidget {
  const _PostLoginSplashScreen();

  @override
  State<_PostLoginSplashScreen> createState() => _PostLoginSplashScreenState();
}

class _PostLoginSplashScreenState extends State<_PostLoginSplashScreen> {
  Timer? _overlayTimer;
  bool _showOverlay = true;

  @override
  void initState() {
    super.initState();
    _overlayTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOverlay = false;
      });
    });
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF000000)),
        const FeedScreen(
          initialSpontaneousPromptDelay: Duration(seconds: 3),
        ),
        if (_showOverlay)
          const IgnorePointer(
            child: AnimatedInfinitySplashScreen(withScaffold: false),
          ),
      ],
    );
  }
}
