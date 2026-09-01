import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'register_screen.dart';
import 'services/auth_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'services/share_flow_log_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class PhoneRegistrationScreen extends StatefulWidget {
  const PhoneRegistrationScreen({super.key});

  @override
  State<PhoneRegistrationScreen> createState() =>
      _PhoneRegistrationScreenState();
}

class _PhoneRegistrationScreenState extends State<PhoneRegistrationScreen> {
  static const _background = Color(0xFF070B12);
  static const _panel = Color(0xD0121A2B);
  static const _primary = Color(0xFF7B79FF);
  static const _accent = Color(0xFF53D9FF);
  static const _text = Color(0xFFEAF0FF);
  static const _muted = Color(0xFFAAB7E8);

  final AuthService _authService = AuthService();
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String? _verificationId;
  AuthCredential? _phoneCredential;
  int? _resendToken;
  int _step = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _phoneController.dispose();
    _codeController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: _muted),
        filled: true,
        fillColor: const Color(0xFF141D2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _accent.withValues(alpha: .16)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _accent.withValues(alpha: .16)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _accent.withValues(alpha: .66)),
        ),
      );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'שדה חובה' : null;

  String? _password(String? value) {
    final password = value?.trim() ?? '';
    if (password.length < 7 ||
        !RegExp(r'[A-Z]').hasMatch(password) ||
        !RegExp(r'[a-z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password) ||
        !RegExp(r'[^A-Za-z0-9]').hasMatch(password)) {
      return 'לפחות 7 תווים, אות גדולה, אות קטנה, מספר וסימן מיוחד';
    }
    return null;
  }

  Future<void> _sendCode() async {
    if (_phoneController.text.trim().isEmpty) {
      setState(() => _error = 'יש להזין מספר טלפון.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final phone = _authService.normalizePhoneNumber(_phoneController.text);
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      setState(() {
        _busy = false;
        _error = 'יש להזין מספר טלפון תקין, לדוגמה 052-7466673.';
      });
      return;
    }

    try {
      final isTaken = await _authService.isRegisteredPhone(phone);
      if (isTaken) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'מספר הטלפון הזה כבר רשום במערכת. יש לעבור למסך ההתחברות.';
        });
        return;
      }
    } catch (e) {
      debugPrint('[PhoneRegistrationScreen] isRegisteredPhone check error: $e');
    }

    try {
      await ShareFlowLogService.log('PHONE_VERIFY_START | phone=$phone');
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        forceResendingToken: _resendToken,
        verificationCompleted: (credential) async {
          await ShareFlowLogService.log('PHONE_VERIFY_AUTO_COMPLETED');
          if (!mounted) return;
          await _verifyCredential(credential);
        },
        verificationFailed: (error) {
          ShareFlowLogService.log(
            'PHONE_VERIFY_FAILED | code=${error.code} | message=${error.message}',
          );
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = error.message ?? 'לא הצלחנו לשלוח קוד אימות.';
          });
        },
        codeSent: (verificationId, resendToken) {
          ShareFlowLogService.log('PHONE_VERIFY_CODE_SENT');
          if (!mounted) return;
          setState(() {
            _verificationId = verificationId;
            _resendToken = resendToken;
            _step = 1;
            _busy = false;
          });
        },
        codeAutoRetrievalTimeout: (verificationId) {
          ShareFlowLogService.log('PHONE_VERIFY_AUTO_RETRIEVAL_TIMEOUT');
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (error) {
      await ShareFlowLogService.log(
        'PHONE_VERIFY_EXCEPTION | code=${error.code} | message=${error.message}',
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message ?? 'לא הצלחנו לשלוח קוד אימות.';
        });
      }
    }
  }

  Future<void> _verifyCode() async {
    final verificationId = _verificationId;
    final code = _codeController.text.trim();
    if (verificationId == null || code.length != 6) {
      setState(() => _error = 'יש להזין קוד אימות בן 6 ספרות.');
      return;
    }
    await _verifyCredential(
      PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      ),
    );
  }

  Future<void> _verifyCredential(AuthCredential credential) async {
    if (_busy && _step == 1) {
      setState(() => _busy = true);
    } else {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await FirebaseAuth.instance.signInWithCredential(credential);
      _phoneCredential = credential;
      if (!mounted) return;
      setState(() {
        _step = 2;
        _busy = false;
        _error = null;
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? 'קוד האימות אינו תקין.';
      });
    }
  }

  Future<void> _createAccount() async {
    if (!_formKey.currentState!.validate()) return;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      setState(() => _error = 'פג תוקף האימות. יש להתחיל מחדש.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user =
          await _authService.finishPhoneVerificationAndCreateAuthAccount(
        phoneCredential: _phoneCredential!,
        phone: _phoneController.text,
        password: _passwordController.text.trim(),
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
      );
      if (!mounted) return;
      AuthService.registrationFlowInProgress.value = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => RegisterScreen(
            initialStep: 1,
            prefilledEmail: user.email,
            prefilledPassword: _passwordController.text.trim(),
          ),
        ),
      );
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message ?? 'לא הצלחנו ליצור את החשבון.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'אירעה שגיאה ביצירת החשבון. נסה שוב.';
        });
      }
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? Function(String?)? validator,
    bool obscureText = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        style: const TextStyle(color: _text),
        decoration: _decoration(label),
      ),
    );
  }

  Widget _content() {
    if (_step == 0) {
      return Column(children: [
        _field(
          controller: _phoneController,
          label: 'מספר טלפון',
          keyboardType: TextInputType.phone,
          validator: (value) {
            final normalized = _authService.normalizePhoneNumber(value ?? '');
            return normalized.length < 8 ? 'מספר טלפון לא תקין' : null;
          },
        ),
        _button('שליחת קוד', _sendCode),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'כבר יש לך חשבון? ',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
            InkWell(
              onTap: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                } else {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                }
              },
              child: const Text(
                'התחברות',
                style: TextStyle(
                  color: _accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ]);
    }
    if (_step == 1) {
      return Column(children: [
        Text('שלחנו קוד למספר ${_phoneController.text.trim()}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, height: 1.5)),
        const SizedBox(height: 16),
        _field(
          controller: _codeController,
          label: 'קוד אימות',
          keyboardType: TextInputType.number,
          validator: (value) =>
              (value?.trim().length ?? 0) == 6 ? null : 'יש להזין 6 ספרות',
        ),
        _button('אימות מספר הטלפון', _verifyCode),
        TextButton(
          onPressed: _busy ? null : _sendCode,
          child: const Text('שלח קוד מחדש', style: TextStyle(color: _accent)),
        ),
      ]);
    }
    return Form(
      key: _formKey,
      child: Column(children: [
        _field(
            controller: _firstNameController,
            label: 'שם פרטי',
            validator: _required),
        _field(
            controller: _lastNameController,
            label: 'שם משפחה',
            validator: _required),
        _field(
            controller: _passwordController,
            label: 'סיסמה',
            obscureText: true,
            validator: _password),
        _field(
          controller: _confirmPasswordController,
          label: 'אימות סיסמה',
          obscureText: true,
          validator: (value) => value?.trim() == _passwordController.text.trim()
              ? null
              : 'הסיסמאות אינן תואמות',
        ),
        _button('המשך ליצירת הפרופיל', _createAccount),
      ]),
    );
  }

  Widget _button(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: _background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: _text,
          title: const Text('הרשמה'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: _accent.withValues(alpha: .12)),
                ),
                child: Column(children: [
                  const Text('יצירת חשבון',
                      style: TextStyle(
                          color: _text,
                          fontSize: 28,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 22),
                  _content(),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                    if (_error!.contains('רשום במערכת')) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () {
                          if (Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          } else {
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) => const LoginScreen(),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.login, color: _accent, size: 18),
                        label: const Text(
                          'מעבר למסך ההתחברות',
                          style: TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
