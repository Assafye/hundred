import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hundred_version1/services/auth_service.dart';

import 'feed_screen.dart';
import 'register_screen.dart';
import 'widgets/animated_infinity_splash_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _describeLoginFailure(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-email':
          return 'כתובת המייל/שם המשתמש שהוזן אינו תקין. / The email/username entered is invalid. Make sure it matches the account exactly.';
        case 'user-not-found':
          return 'לא נמצא חשבון עם הפרטים שהוזנו. / No account was found with the provided details. Check that the user exists in the correct Firebase project.';
        case 'wrong-password':
          return 'הסיסמה שגויה. / Incorrect password. Make sure the password matches exactly, including uppercase/lowercase letters and symbols.';
        case 'invalid-credential':
          return 'פרטי הכניסה לא תקינים או שהחשבון שייך לפרויקט Firebase אחר. / The login credentials are invalid or the account belongs to a different Firebase project. Check the production environment and the same account.';
        case 'user-disabled':
          return 'החשבון הושבת. / This account has been disabled. Reactivate it in Firebase or use a working test account.';
        case 'too-many-requests':
          return 'ניסיונות הכניסה נעצרו זמנית בגלל הגנה. / Too many login attempts. Wait a moment and try again, or check if the device/account is temporarily blocked.';
        case 'network-request-failed':
          return 'התקלה נובעת מרשת/חיבור. / Network connection issue. Check the internet, VPN, firewall, or whether the app is pointing to a local/dev server instead of production.';
        case 'email-not-verified':
          return 'החשבון קיים, אבל המייל עדיין לא אומת. / The account exists, but the email is not verified yet. Please verify the email before logging in.';
        case 'registration-incomplete':
          return 'החשבון קיים אך התהליך של ההרשמה לא הושלם. / The account exists, but registration is incomplete. Please complete the profile before logging in.';
        case 'session-expired':
          return 'פג תוקף ההתחברות. / Login session expired. Close the app and try again.';
        case 'account-exists-with-different-credential':
          return 'החשבון כבר קיים עם שיטת כניסה אחרת. / This account already exists with a different sign-in method. Use the same account and method configured for this project.';
        case 'operation-not-allowed':
          return 'כניסה עם פרטי חשבון אלה לא מאופשרת בפרויקט Firebase זה. / Sign-in with these credentials is not enabled in this Firebase project. Check the Auth configuration.';
        case 'app-not-authorized':
          return 'האפליקציה לא מאושרת לשימוש ב-Firebase Auth של הפרויקט. / This app is not authorized to use Firebase Auth in this project. Check the Firebase/App configuration.';
        case 'permission-denied':
          return 'הגישה ל-Firebase נדחתה. / Firebase access denied. Check permissions, Firebase config, and whether you are using the correct production/development environment.';
        case 'internal-error':
          return 'שגיאת שרת פנימית של Firebase. / Internal Firebase server error. Try again; if this is a reviewer, verify the account exists in the correct environment.';
        case 'unknown':
          return 'שגיאת התחברות לא מזוהה. / Unknown sign-in error. Check that the details are correct and that the app is using the correct Firebase project.';
        default:
          return 'ההתחברות נכשלה. / Login failed. Make sure the account exists, the email/password is correct, and the app is using the same Firebase environment.';
      }
    }

    if (error is PlatformException) {
      final message = (error.message ?? '').trim();
      if (message.toLowerCase().contains('network')) {
        return 'הבעיה היא בחיבור רשת/שרת. / This is a network/server issue. Check VPN, firewall, or whether the app is pointing to a local/dev server instead of production.';
      }
      return 'התחברות נכשלה עקב שגיאת מערכת/רשת. / Login failed due to a system/network error. Check whether the app is connected to the correct Firebase project.';
    }

    return 'ההתחברות נכשלה. אם זה בודק חיצוני, בדוק שהאותו חשבון קיים ב-Firebase של האפליקציה, שהמייל מאומת והסיסמה נכונה. / Login failed. If this is an external reviewer, verify that the same account exists in the app Firebase project, the email is verified, and the password is correct.';
  }

  Future<void> _onLoginPressed() async {
    final emailOrUsername = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (emailOrUsername.isEmpty || password.isEmpty) {
      const message = 'נא למלא מייל / Mail או שם משתמש וסיסמה / Password. / Please enter email / mail or username and password.';
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(message)),
      );
      return;
    }

    try {
      await _authService.loginWithEmailOrUsername(
        emailOrUsername,
        password,
      );

      if (!mounted) return;
      setState(() {
        _showError = false;
        _errorMessage = null;
      });

      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const _PostLoginSplashScreen(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      );
    } on FirebaseAuthException catch (e, stackTrace) {
      print('[LoginScreen][_onLoginPressed] FirebaseAuthException: $e');
      print('[LoginScreen][_onLoginPressed] stackTrace: $stackTrace');
      if (!mounted) return;
      AuthService.clearPendingAuthUiMessage();
      final message = e.code == AuthService.emailNotVerifiedCode
          ? 'האימייל שלך עדיין לא אומת. נא לאשר את המייל ולהתחבר שוב. / Your email is not verified yet. Please verify it and sign in again.'
          : (e.code == AuthService.registrationIncompleteCode
              ? 'החשבון שלך עדיין לא הושלם. נא להשלים את הפרטים האישיים לאחר ההתחברות. / Your account is not complete yet. Please finish the profile details after logging in.'
              : _describeLoginFailure(e));
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
    } catch (e, stackTrace) {
      print('[LoginScreen][_onLoginPressed] error: $e');
      print('[LoginScreen][_onLoginPressed] stackTrace: $stackTrace');
      if (!mounted) return;
      final message = _describeLoginFailure(e);
      setState(() {
        _showError = true;
        _errorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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
                onPressed: () => Navigator.of(dialogContext)
                    .pop(controller.text.trim()),
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
      print('[LoginScreen][_onForgotPasswordPressed] FirebaseAuthException: $e');
      print('[LoginScreen][_onForgotPasswordPressed] stackTrace: $stackTrace');
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
      print('[LoginScreen][_onForgotPasswordPressed] error: $e');
      print('[LoginScreen][_onForgotPasswordPressed] stackTrace: $stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא הצלחנו לשלוח כרגע, נסה שוב בעוד רגע.')),
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
        borderSide: BorderSide(color: _accent.withValues( alpha: 0.16), width: 0.9),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: _accent.withValues( alpha: 0.14), width: 0.9),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: _accent.withValues( alpha: 0.66), width: 1.0),
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
        child: Stack(
            children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(seconds: 8),
                curve: Curves.easeInOut,
                onEnd: _toggleBgAnimation,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: _animateBg ? Alignment.topLeft : Alignment.topRight,
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
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
                    decoration: BoxDecoration(
                      color: const Color(0xD0121A2B),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                          color: _accent.withValues( alpha: 0.12), width: 0.8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues( alpha: 0.24),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                              color: _textPrimary, fontWeight: FontWeight.w500),
                          decoration: _inputDecoration('מייל / Mail או שם משתמש'),
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
                              color: _textPrimary, fontWeight: FontWeight.w500),
                          decoration: _inputDecoration('סיסמה / Password').copyWith(
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                  () => _hidePassword = !_hidePassword),
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
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'אין לך עדיין חשבון? - ',
                              style: TextStyle(
                                  color: _textSecondary, fontSize: 13),
                            ),
                            InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => const RegisterScreen()),
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
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                            elevation: 0,
                          ).copyWith(
                            backgroundColor: WidgetStateProperty.resolveWith(
                              (states) => states.contains(WidgetState.pressed)
                                  ? _primary
                                  : const Color(0xFF6978FF),
                            ),
                          ),
                          child: const Text(
                            'כניסה',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _showError
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _errorMessage ??
                                              'לא הצלחנו להתחבר. נסה שוב.',
                                            style: const TextStyle(
                                              color: Colors.redAccent,
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
