import 'dart:async';
import 'dart:ui';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;

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

class _PhoneRegistrationScreenState extends State<PhoneRegistrationScreen>
    with SingleTickerProviderStateMixin {
  static const _background = Color(0xFF070B12);
  static const _panel = Color(0xF0121928);
  static const _primary = Color(0xFF8B83FF);
  static const _accent = Color(0xFF53D9FF);
  static const _text = Color(0xFFEAF0FF);
  static const _muted = Color(0xFFAAB7E8);

  final AuthService _authService = AuthService();
  late final AnimationController _backgroundController;
  final _formKey = GlobalKey<FormState>();
  final _countryCodeController = TextEditingController(text: '+972');
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String? _verificationId;
  AuthCredential? _phoneCredential;
  int? _resendToken;
  Timer? _resendTimer;
  int _resendSecondsRemaining = 0;
  int _step = 0;
  bool _busy = false;
  bool _isExiting = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;
  String? _lastAutoSubmittedCode;
  String? _error;

  @override
  void initState() {
    super.initState();
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _resendTimer?.cancel();
    _backgroundController.dispose();
    _countryCodeController.dispose();
    _phoneController.dispose();
    _codeFocusNode.dispose();
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

  String _enteredPhoneNumber() {
    final countryDigits =
        _countryCodeController.text.replaceAll(RegExp(r'\D'), '');
    final enteredNumber = _phoneController.text.trim();
    if (enteredNumber.startsWith('+')) return enteredNumber;

    var localDigits = enteredNumber.replaceAll(RegExp(r'\D'), '');
    if (localDigits.startsWith('0')) {
      localDigits = localDigits.substring(1);
    }
    return countryDigits.isEmpty
        ? enteredNumber
        : '+$countryDigits$localDigits';
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendSecondsRemaining = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsRemaining <= 1) {
        timer.cancel();
        setState(() => _resendSecondsRemaining = 0);
        return;
      }
      setState(() => _resendSecondsRemaining--);
    });
  }

  String get _resendCountdownLabel {
    final seconds = _resendSecondsRemaining.toString().padLeft(2, '0');
    return 'שליחה מחדש בעוד 00:$seconds';
  }

  Future<void> _sendCode() async {
    if (_countryCodeController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty) {
      setState(() => _error = 'יש להזין מספר טלפון.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final phone = _authService.normalizePhoneNumber(_enteredPhoneNumber());
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      setState(() {
        _busy = false;
        _error = 'יש להזין מספר טלפון תקין, לדוגמה 052-1234567.';
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
            _lastAutoSubmittedCode = null;
            _codeController.clear();
          });
          _startResendCountdown();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _codeFocusNode.requestFocus();
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

  void _onVerificationCodeChanged(String code) {
    if (code.length < 6) {
      _lastAutoSubmittedCode = null;
      return;
    }
    if (_busy || code == _lastAutoSubmittedCode) return;

    _lastAutoSubmittedCode = code;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _step != 1 || _busy || _codeController.text != code) {
        return;
      }
      _verifyCode();
    });
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
    AuthService.registrationFlowInProgress.value = true;
    try {
      await FirebaseAuth.instance.signInWithCredential(credential);
      _phoneCredential = credential;
      if (!mounted) return;
      setState(() {
        _step = 2;
        _busy = false;
        _error = null;
      });
      _resendTimer?.cancel();
    } on FirebaseAuthException catch (error) {
      AuthService.registrationFlowInProgress.value = false;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? 'קוד האימות אינו תקין.';
      });
    }
  }

  Future<void> _exitRegistration() async {
    if (_isExiting) return;
    _isExiting = true;
    await _authService.discardTemporaryPhoneUser();
    AuthService.registrationFlowInProgress.value = false;
    if (!mounted) return;

    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
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
        phone: _enteredPhoneNumber(),
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
    VoidCallback? onToggleVisibility,
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
        decoration: _decoration(label).copyWith(
          suffixIcon: onToggleVisibility == null
              ? null
              : IconButton(
                  onPressed: onToggleVisibility,
                  tooltip: obscureText ? 'הצגת סיסמה' : 'הסתרת סיסמה',
                  icon: Icon(
                    obscureText
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: _muted,
                    size: 20,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _phoneField() {
    final phoneBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(
        color: _accent.withValues(alpha: .48),
        width: 1.2,
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 88,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withValues(alpha: .14),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: TextFormField(
                    controller: _countryCodeController,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: '+972',
                      hintStyle: TextStyle(
                        color: _muted.withValues(alpha: .7),
                        fontWeight: FontWeight.w500,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1B2940),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 17,
                      ),
                      border: phoneBorder,
                      enabledBorder: phoneBorder,
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                          color: _accent,
                          width: 1.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withValues(alpha: .14),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _busy ? null : _sendCode(),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: '05*-*******',
                      hintStyle: TextStyle(
                        color: _muted.withValues(alpha: .7),
                        fontWeight: FontWeight.w500,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1B2940),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 17,
                      ),
                      border: phoneBorder,
                      enabledBorder: phoneBorder,
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                          color: _accent,
                          width: 1.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _verificationCodeField() {
    return AnimatedBuilder(
      animation: Listenable.merge([_codeController, _codeFocusNode]),
      builder: (context, child) {
        final code = _codeController.text;
        final selectionOffset = _codeController.selection.baseOffset;
        final hasSelectedDigit = _codeController.selection.isValid &&
            !_codeController.selection.isCollapsed;
        final activeIndex = selectionOffset < 0
            ? code.length.clamp(0, 5)
            : selectionOffset.clamp(0, 5);

        return Semantics(
          label: 'קוד אימות בן 6 ספרות',
          textField: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _codeFocusNode.requestFocus,
            child: SizedBox(
              width: 286,
              height: 62,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: .01,
                      child: TextField(
                        controller: _codeController,
                        focusNode: _codeFocusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        onChanged: _onVerificationCodeChanged,
                        onSubmitted: (_) {
                          if (_codeController.text.length == 6 && !_busy) {
                            _verifyCode();
                          }
                        },
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          counterText: '',
                        ),
                      ),
                    ),
                  ),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      children: List.generate(6, (index) {
                        final hasDigit = index < code.length;
                        final isSelected = _codeFocusNode.hasFocus &&
                            hasSelectedDigit &&
                            index == activeIndex;
                        final isActive = _codeFocusNode.hasFocus &&
                            index == activeIndex &&
                            (code.length < 6 || hasSelectedDigit);
                        final lineColor = isSelected
                            ? const Color(0xFFC8F7FF)
                            : hasDigit || isActive
                                ? _accent
                                : _muted.withValues(alpha: .42);

                        return Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _codeFocusNode.requestFocus();
                              final offset = index.clamp(0, code.length);
                              _codeController.selection = index < code.length
                                  ? TextSelection(
                                      baseOffset: offset,
                                      extentOffset: offset + 1,
                                    )
                                  : TextSelection.collapsed(offset: offset);
                            },
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: index == 0 ? 0 : 5,
                                right: index == 5 ? 0 : 5,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        hasDigit ? code[index] : '',
                                        style: const TextStyle(
                                          color: _text,
                                          fontSize: 25,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    height: hasDigit || isActive ? 3 : 2,
                                    decoration: BoxDecoration(
                                      color: lineColor,
                                      borderRadius: BorderRadius.circular(3),
                                      boxShadow: hasDigit || isActive
                                          ? [
                                              BoxShadow(
                                                color: lineColor.withValues(
                                                  alpha: isSelected ? .58 : .28,
                                                ),
                                                blurRadius: isSelected ? 12 : 8,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content() {
    if (_step == 0) {
      return Column(children: [
        _phoneField(),
        const SizedBox(height: 26),
        _button('שליחת קוד', _sendCode, compact: true),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'כבר יש לך חשבון? ',
              style: TextStyle(color: _muted, fontSize: 14),
            ),
            InkWell(
              onTap: _isExiting ? null : () => unawaited(_exitRegistration()),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                child: Text(
                  'התחברות',
                  style: TextStyle(
                    color: _accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ]);
    }
    if (_step == 1) {
      return Column(children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'שלחנו קוד למספר',
              style: TextStyle(color: _muted, height: 1.5),
            ),
            const SizedBox(width: 5),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                _enteredPhoneNumber(),
                style: const TextStyle(color: _muted, height: 1.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _verificationCodeField(),
        const SizedBox(height: 26),
        _button('אימות', _verifyCode, compact: true),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy || _resendSecondsRemaining > 0 ? null : _sendCode,
          child: Text(
            _resendSecondsRemaining > 0
                ? _resendCountdownLabel
                : 'שלח קוד מחדש',
            style: TextStyle(
              color: _resendSecondsRemaining > 0
                  ? _muted.withValues(alpha: .72)
                  : _accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ]);
    }
    return Form(
      key: _formKey,
      child: Column(children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                controller: _firstNameController,
                label: 'שם פרטי',
                validator: _required,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                controller: _lastNameController,
                label: 'שם משפחה',
                validator: _required,
              ),
            ),
          ],
        ),
        _field(
          controller: _passwordController,
          label: 'סיסמה',
          obscureText: _hidePassword,
          onToggleVisibility: () {
            setState(() => _hidePassword = !_hidePassword);
          },
          validator: _password,
        ),
        _field(
          controller: _confirmPasswordController,
          label: 'אימות סיסמה',
          obscureText: _hideConfirmPassword,
          onToggleVisibility: () {
            setState(() => _hideConfirmPassword = !_hideConfirmPassword);
          },
          validator: (value) => value?.trim() == _passwordController.text.trim()
              ? null
              : 'הסיסמאות אינן תואמות',
        ),
        _button('המשך ליצירת פרופיל', _createAccount, compact: true),
      ]),
    );
  }

  Widget _button(
    String label,
    VoidCallback onPressed, {
    bool compact = false,
  }) {
    return SizedBox(
      width: compact ? 180 : double.infinity,
      child: ElevatedButton(
        onPressed: _busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          minimumSize: compact ? const Size(0, 42) : null,
          padding: EdgeInsets.symmetric(vertical: compact ? 10 : 16),
          tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
          elevation: compact ? 6 : 8,
          shadowColor: _primary.withValues(alpha: .38),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 24 : 18),
          ),
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
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_exitRegistration());
      },
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: _background,
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: _text,
            title: const Text('הרשמה'),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: _backgroundController,
                builder: (context, child) {
                  final progress = _backgroundController.value;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        top: -110 + (progress * 55),
                        right: -105 + (progress * 35),
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48),
                          child: Container(
                            width: 260,
                            height: 260,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _accent.withValues(alpha: .16),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: -120 + (progress * 45),
                        left: -100 + (progress * 48),
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 58, sigmaY: 58),
                          child: Container(
                            width: 300,
                            height: 300,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _primary.withValues(alpha: .22),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final visibleHeight =
                        (constraints.maxHeight - keyboardInset)
                            .clamp(0.0, constraints.maxHeight)
                            .toDouble();
                    final keyboardProgress =
                        (keyboardInset / 300).clamp(0.0, 1.0);
                    final restingOffset = -52 * (1 - keyboardProgress);

                    return SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.fromLTRB(
                        20,
                        16,
                        20,
                        keyboardInset + 16,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: (visibleHeight - 32)
                              .clamp(0.0, double.infinity)
                              .toDouble(),
                        ),
                        child: Center(
                          child: Transform.translate(
                            offset: Offset(0, restingOffset),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: Container(
                                width: double.infinity,
                                padding:
                                    const EdgeInsets.fromLTRB(22, 18, 22, 18),
                                decoration: BoxDecoration(
                                  color: _panel,
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: .09),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: .46),
                                      blurRadius: 34,
                                      offset: const Offset(0, 18),
                                    ),
                                    BoxShadow(
                                      color: _primary.withValues(alpha: .08),
                                      blurRadius: 28,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 58,
                                      height: 58,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(19),
                                        gradient: const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [_accent, _primary],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color:
                                                _primary.withValues(alpha: .3),
                                            blurRadius: 22,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                      ),
                                      child: const Icon(
                                        Icons.diversity_3_rounded,
                                        color: Colors.white,
                                        size: 30,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _step == 2
                                          ? 'אתם כמעט שם!'
                                          : 'הצטרפו לקהילה',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: _text,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    SizedBox(height: _step == 1 ? 8 : 18),
                                    _content(),
                                    if (_error != null) ...[
                                      const SizedBox(height: 14),
                                      Text(
                                        _error!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                      if (_error!.contains('רשום במערכת')) ...[
                                        const SizedBox(height: 10),
                                        TextButton.icon(
                                          onPressed: _isExiting
                                              ? null
                                              : () => unawaited(
                                                    _exitRegistration(),
                                                  ),
                                          icon: const Icon(
                                            Icons.login,
                                            color: _accent,
                                            size: 18,
                                          ),
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
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
