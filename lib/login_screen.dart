import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hundred_version1/services/auth_service.dart';

import 'feed_screen.dart';
import 'phone_registration_screen.dart';
import 'register_screen.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'widgets/animated_infinity_splash_screen.dart';
import 'widgets/forgot_password_sheet.dart';
import 'widgets/swipe_back_wrapper.dart';

bool shouldBlockLoginForState({
  required bool isEmailVerified,
  required OnboardingStep onboardingStep,
}) {
  return onboardingStep != OnboardingStep.active;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  static const Color _bgTop = Color(0xFF0B1222);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _primary = Color(0xFF7B79FF);
  static const Color _accent = Color(0xFF53D9FF);
  static const Color _textPrimary = Color(0xFFEAF0FF);
  static const Color _textSecondary = Color(0xFFAAB7E8);
  static const Color _fieldFill = Color(0xFF141D2E);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _usernameFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final AuthService _authService = AuthService();

  bool _showError = false;
  bool _hidePassword = true;
  bool _animateBg = false;
  bool _isLoggingIn = false;
  String? _errorMessage;
  double? _minObservedKeyboardInset;
  double? _maxObservedKeyboardInset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _usernameFocusNode.addListener(_handleLoginFieldFocusChange);
    _passwordFocusNode.addListener(_handleLoginFieldFocusChange);
    KeyboardDismissController.suspend();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final pendingMessage = AuthService.consumePendingAuthUiMessage();
      if (pendingMessage != null && pendingMessage.trim().isNotEmpty) {
        setState(() {
          _showError = true;
          _errorMessage = pendingMessage;
        });
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

  bool get _isEditingLoginFields =>
      _usernameFocusNode.hasFocus || _passwordFocusNode.hasFocus;

  void _clearKeyboardInsetTracking() {
    _minObservedKeyboardInset = null;
    _maxObservedKeyboardInset = null;
  }

  void _handleLoginFieldFocusChange() {
    if (!mounted || _isEditingLoginFields) {
      return;
    }

    setState(_clearKeyboardInsetTracking);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null || !mounted) {
      return;
    }

    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    if (keyboardInset <= 0) {
      if (_minObservedKeyboardInset != null ||
          _maxObservedKeyboardInset != null) {
        setState(() {
          _minObservedKeyboardInset = null;
          _maxObservedKeyboardInset = null;
        });
      }
      return;
    }

    final nextMin = _minObservedKeyboardInset == null
        ? keyboardInset
        : (_minObservedKeyboardInset! < keyboardInset
            ? _minObservedKeyboardInset!
            : keyboardInset);
    final nextMax = _maxObservedKeyboardInset == null
        ? keyboardInset
        : (_maxObservedKeyboardInset! > keyboardInset
            ? _maxObservedKeyboardInset!
            : keyboardInset);

    if (nextMin != _minObservedKeyboardInset ||
        nextMax != _maxObservedKeyboardInset) {
      setState(() {
        _minObservedKeyboardInset = nextMin;
        _maxObservedKeyboardInset = nextMax;
      });
    }
  }

  double _stableKeyboardInset(double currentKeyboardInset) {
    if (currentKeyboardInset <= 0) {
      return 0;
    }

    final maxInset = _maxObservedKeyboardInset;
    if (maxInset == null) {
      return currentKeyboardInset;
    }

    return maxInset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usernameFocusNode.removeListener(_handleLoginFieldFocusChange);
    _passwordFocusNode.removeListener(_handleLoginFieldFocusChange);
    KeyboardDismissController.resume();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
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

  String _describeLoginFailure(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-email':
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'שם המשתמש או הסיסמה שגויים.';
        case 'user-disabled':
          return 'החשבון הזה הושבת.';
        case 'too-many-requests':
          return 'יותר מדי ניסיונות התחברות. נסה שוב בעוד כמה דקות.';
        case 'network-request-failed':
          return 'אין חיבור לאינטרנט. בדוק את החיבור ונסה שוב.';
        case 'email-not-verified':
        case 'registration-incomplete':
          return 'יש להשלים את תהליך ההרשמה כדי להתחבר.';
        case AuthService.ageRestrictedCode:
          return 'האפליקציה מיועדת לגילאי 13 ומעלה בלבד.';
        case 'session-expired':
          return 'החיבור פג תוקף. יש להתחבר מחדש.';
        case 'account-exists-with-different-credential':
          return 'החשבון כבר קיים בשיטת התחברות אחרת.';
        default:
          return 'ההתחברות נכשלה. נסה שוב.';
      }
    }

    if (error is PlatformException) {
      final message = (error.message ?? '').trim();
      if (message.toLowerCase().contains('network')) {
        return 'אין חיבור לאינטרנט. בדוק את החיבור ונסה שוב.';
      }
      return 'ההתחברות נכשלה. נסה שוב.';
    }

    return 'ההתחברות נכשלה. נסה שוב.';
  }

  Future<void> _onLoginPressed() async {
    if (_isLoggingIn) return;
    final emailOrUsername = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (emailOrUsername.isEmpty || password.isEmpty) {
      const message = 'יש למלא טלפון  או מייל וסיסמה.';
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      return;
    }

    final navigator = Navigator.of(context);

    setState(() {
      _isLoggingIn = true;
    });

    try {
      final user = await _authService.loginWithEmailOrUsername(
        emailOrUsername,
        password,
      );
      if (user == null) {
        return;
      }

      final onboardingStep = await _authService.currentUserOnboardingStep();
      final shouldBlockLogin = shouldBlockLoginForState(
        isEmailVerified: user.emailVerified,
        onboardingStep: onboardingStep,
      );

      if (shouldBlockLogin) {
        if (!mounted) return;
        AuthService.registrationFlowInProgress.value = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RegisterScreen(
              initialStep: 1,
              prefilledEmail: user.email,
              prefilledPassword: password,
            ),
          ),
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

      final shouldOpenVerificationFlow = e.code == 'registration-incomplete';

      if (shouldOpenVerificationFlow) {
        final currentEmail = FirebaseAuth.instance.currentUser?.email;
        final isInputEmail =
            RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(emailOrUsername);
        final resolvedEmail = currentEmail != null && currentEmail.isNotEmpty
            ? currentEmail
            : (isInputEmail
                ? emailOrUsername
                : _authService.phoneAuthEmail(emailOrUsername));
        AuthService.registrationFlowInProgress.value = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RegisterScreen(
              initialStep: 1,
              prefilledEmail: resolvedEmail,
              prefilledPassword: password,
            ),
          ),
        );
        return;
      }

      final message = _describeLoginFailure(e);
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
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
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  Future<void> _onForgotPasswordPressed() async {
    final seedEmail = _usernameController.text.trim();
    final user = await showForgotPasswordSheet(
      context,
      authService: _authService,
      initialEmail: RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(seedEmail)
          ? seedEmail
          : null,
    );
    if (user == null || !mounted) return;

    try {
      final canAccess = await _authService.canCurrentUserAccessApp();
      if (!mounted) return;
      if (canAccess) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => const FeedScreen(
              allowSpontaneousPrompt: true,
              initialSpontaneousPromptDelay: Duration(seconds: 1),
            ),
          ),
          (route) => false,
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RegisterScreen(
              initialStep: 1,
              prefilledEmail: user.email,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _showError = true;
          _errorMessage = 'לא הצלחנו להתחבר לחשבון כרגע. נסה שוב.';
        });
      }
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
                    final keyboardInset = mediaQuery.viewInsets.bottom;
                    final activeKeyboardInset =
                        _isEditingLoginFields ? keyboardInset : 0.0;
                    final targetKeyboardInset =
                        _stableKeyboardInset(activeKeyboardInset);

                    return TweenAnimationBuilder<double>(
                      duration: Duration(
                        milliseconds: _isEditingLoginFields ? 120 : 280,
                      ),
                      curve: Curves.easeOutCubic,
                      tween: Tween<double>(end: targetKeyboardInset),
                      builder: (context, animatedKeyboardInset, child) {
                        final visibleHeight =
                            (constraints.maxHeight - animatedKeyboardInset)
                                .clamp(0.0, constraints.maxHeight);

                        return SingleChildScrollView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: EdgeInsets.fromLTRB(
                            0,
                            16,
                            0,
                            animatedKeyboardInset + 16,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: visibleHeight,
                            ),
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.zero,
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 460),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 24, vertical: 16),
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          20, 24, 20, 18),
                                      decoration: BoxDecoration(
                                        color: const Color(0xD0121A2B),
                                        borderRadius: BorderRadius.circular(30),
                                        border: Border.all(
                                            color:
                                                _accent.withValues(alpha: 0.12),
                                            width: 0.8),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.24),
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
                                            focusNode: _usernameFocusNode,
                                            keyboardType:
                                                TextInputType.emailAddress,
                                            textInputAction:
                                                TextInputAction.next,
                                            textDirection: TextDirection.rtl,
                                            textAlign: TextAlign.right,
                                            autocorrect: false,
                                            enableSuggestions: false,
                                            style: const TextStyle(
                                                color: _textPrimary,
                                                fontWeight: FontWeight.w500),
                                            decoration: _inputDecoration(
                                                'טלפון / אימייל Phone / Email'),
                                          ),
                                          const SizedBox(height: 14),
                                          TextField(
                                            controller: _passwordController,
                                            focusNode: _passwordFocusNode,
                                            obscureText: _hidePassword,
                                            textDirection: TextDirection.rtl,
                                            textAlign: TextAlign.right,
                                            autocorrect: false,
                                            enableSuggestions: false,
                                            style: const TextStyle(
                                                color: _textPrimary,
                                                fontWeight: FontWeight.w500),
                                            decoration: _inputDecoration(
                                                    'סיסמה / Password')
                                                .copyWith(
                                              suffixIcon: IconButton(
                                                onPressed: () => setState(() =>
                                                    _hidePassword =
                                                        !_hidePassword),
                                                icon: Icon(
                                                  _hidePassword
                                                      ? Icons
                                                          .visibility_off_rounded
                                                      : Icons
                                                          .visibility_rounded,
                                                  color: _textSecondary,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: TextButton(
                                              onPressed:
                                                  _onForgotPasswordPressed,
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
                                                            const PhoneRegistrationScreen()),
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
                                            onPressed: _isLoggingIn
                                                ? null
                                                : _onLoginPressed,
                                            style: ElevatedButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 16),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          20)),
                                              elevation: 0,
                                            ).copyWith(
                                              backgroundColor:
                                                  WidgetStateProperty
                                                      .resolveWith(
                                                (states) => states.contains(
                                                        WidgetState.pressed)
                                                    ? _primary
                                                    : const Color(0xFF6978FF),
                                              ),
                                            ),
                                            child: _isLoggingIn
                                                ? const SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2.4,
                                                      color: Colors.white,
                                                    ),
                                                  )
                                                : const Text(
                                                    'כניסה',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 16),
                                                  ),
                                          ),
                                          AnimatedSwitcher(
                                            duration: const Duration(
                                                milliseconds: 250),
                                            child: _showError
                                                ? Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 12),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            _errorMessage ??
                                                                'לא הצלחנו להתחבר. נסה שוב.',
                                                            style: const TextStyle(
                                                                color: Colors
                                                                    .redAccent,
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
          allowSpontaneousPrompt: true,
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
