import 'dart:async';
import 'dart:ui';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;

import '../services/auth_service.dart';

enum _RecoveryMethod { phone, email }

/// Shows the "forgot password" bubble dialog with tabs to recover via phone
/// (signs the user in with an SMS code) or email (sends a reset link).
///
/// Returns the signed-in [User] if the phone flow completed successfully,
/// otherwise `null`.
Future<User?> showForgotPasswordSheet(
  BuildContext context, {
  required AuthService authService,
  String? initialEmail,
}) {
  return showGeneralDialog<User?>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'שחזור חשבון',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, __) => _ForgotPasswordSheet(
      authService: authService,
      initialEmail: initialEmail,
    ),
    transitionBuilder: (dialogContext, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: .92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet({
    required this.authService,
    this.initialEmail,
  });

  final AuthService authService;
  final String? initialEmail;

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  static const _panel = Color(0xFF101826);
  static const _fieldFill = Color(0xFF1B2940);
  static const _accent = Color(0xFF53D9FF);
  static const _primary = Color(0xFF8B83FF);
  static const _text = Color(0xFFEAF0FF);
  static const _muted = Color(0xFFAAB7E8);

  _RecoveryMethod _method = _RecoveryMethod.phone;

  // Phone flow.
  final _countryCodeController = TextEditingController(text: '+972');
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  int _phoneStep = 0;
  String? _verificationId;
  int? _resendToken;
  String? _lastAutoSubmittedCode;

  // Email flow.
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail ?? '');
  bool _emailSent = false;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _countryCodeController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _codeFocusNode.dispose();
    _emailController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration(String label) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: _accent.withValues(alpha: .16), width: 1.1),
    );
    return InputDecoration(
      floatingLabelBehavior: FloatingLabelBehavior.never,
      label: Align(
        alignment: Alignment.centerRight,
        child: Text(
          label,
          style: TextStyle(color: _muted.withValues(alpha: .7)),
        ),
      ),
      filled: true,
      fillColor: _fieldFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: _accent, width: 1.8),
      ),
    );
  }

  void _switchMethod(_RecoveryMethod method) {
    if (_method == method || _busy) return;
    setState(() {
      _method = method;
      _error = null;
    });
  }

  String _friendlyAuthError(FirebaseAuthException error, String fallback) {
    switch (error.code) {
      case 'invalid-email':
        return 'כתובת המייל אינה תקינה.';
      case 'invalid-phone-number':
        return 'מספר הטלפון אינו תקין.';
      case 'invalid-verification-code':
        return 'קוד האימות שגוי.';
      case 'too-many-requests':
        return 'יותר מדי ניסיונות. נסה שוב בעוד כמה דקות.';
      case 'network-request-failed':
        return 'אין חיבור לאינטרנט. בדוק את החיבור ונסה שוב.';
      default:
        return fallback;
    }
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

  Future<void> _sendPhoneCode() async {
    if (_phoneController.text.trim().isEmpty) {
      setState(() => _error = 'יש להזין מספר טלפון.');
      return;
    }
    final phone = widget.authService.normalizePhoneNumber(_enteredPhoneNumber());
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      setState(() => _error = 'יש להזין מספר טלפון תקין.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (!await widget.authService.isRegisteredPhone(phone)) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'לא נמצא חשבון עם מספר הטלפון הזה.';
        });
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'לא ניתן לבדוק את החשבון כרגע. נסה שוב.';
      });
      return;
    }

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        forceResendingToken: _resendToken,
        verificationCompleted: (credential) async {
          if (!mounted) return;
          await _signInWithPhoneCredential(credential);
        },
        verificationFailed: (error) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = _friendlyAuthError(error, 'לא הצלחנו לשלוח קוד אימות.');
          });
        },
        codeSent: (verificationId, resendToken) {
          if (!mounted) return;
          setState(() {
            _verificationId = verificationId;
            _resendToken = resendToken;
            _phoneStep = 1;
            _busy = false;
            _lastAutoSubmittedCode = null;
            _codeController.clear();
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _codeFocusNode.requestFocus();
          });
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyAuthError(error, 'לא הצלחנו לשלוח קוד אימות.');
      });
    }
  }

  Future<void> _verifyPhoneCode() async {
    final verificationId = _verificationId;
    final code = _codeController.text.trim();
    if (verificationId == null || code.length != 6) {
      setState(() => _error = 'יש להזין קוד אימות בן 6 ספרות.');
      return;
    }
    await _signInWithPhoneCredential(
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
      if (!mounted ||
          _phoneStep != 1 ||
          _busy ||
          _codeController.text != code) {
        return;
      }
      _verifyPhoneCode();
    });
  }

  Future<void> _signInWithPhoneCredential(AuthCredential credential) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user =
          (await FirebaseAuth.instance.signInWithCredential(credential)).user;
      if (!mounted) return;
      Navigator.of(context).pop(user);
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyAuthError(error, 'קוד האימות אינו נכון.');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'לא הצלחנו לאמת את מספר הטלפון.';
      });
    }
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'יש להזין כתובת מייל.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.authService.sendPasswordResetForEmailOrUsername(email);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _emailSent = true;
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.code == 'invalid-email'
            ? 'כתובת המייל אינה תקינה.'
            : 'לא הצלחנו לשלוח כרגע, נסה שוב בעוד רגע.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'לא הצלחנו לשלוח כרגע, נסה שוב בעוד רגע.';
      });
    }
  }

  Widget _stepLayer({required bool visible, required Widget child}) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1 : 0,
        child: child,
      ),
    );
  }

  Widget _tabButton(String label, _RecoveryMethod method) {
    final selected = _method == method;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchMethod(method),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? _accent : _muted,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 4,
                width: selected ? 56 : 0,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: _accent.withValues(alpha: .5),
                            blurRadius: 8,
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
  }

  Widget _primaryButton(String label, VoidCallback? onPressed) {
    return SizedBox(
      width: 200,
      height: 44,
      child: ElevatedButton(
        onPressed: _busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
      ),
    );
  }

  Widget _phoneEntryStep() {
    final phoneBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: _accent.withValues(alpha: .48), width: 1.2),
    );
    return Column(
      key: const ValueKey('phone-entry'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'התחבר בעזרת קוד אימות לטלפון',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 76,
                    child: TextFormField(
                      controller: _countryCodeController,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        hintText: '+972',
                        hintStyle: TextStyle(color: _muted.withValues(alpha: .7)),
                        filled: true,
                        fillColor: _fieldFill,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        border: phoneBorder,
                        enabledBorder: phoneBorder,
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: _accent, width: 1.8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _busy ? null : _sendPhoneCode(),
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.left,
                      style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        hintText: '05*-*******',
                        hintStyle: TextStyle(color: _muted.withValues(alpha: .7)),
                        filled: true,
                        fillColor: _fieldFill,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: phoneBorder,
                        enabledBorder: phoneBorder,
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: _accent, width: 1.8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 44),
        Center(child: _primaryButton('קבלת קוד אימות', _sendPhoneCode)),
      ],
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
                            _verifyPhoneCode();
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

  Widget _phoneCodeStep() {
    return Column(
      key: const ValueKey('phone-code'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _phoneStep = 0;
                        _error = null;
                      }),
              icon: const Icon(Icons.arrow_back_rounded, color: _muted),
              tooltip: 'חזרה',
            ),
            const Expanded(
              child: Text(
                'הזן את קוד האימות שנשלח אליך',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 286),
            child: _verificationCodeField(),
          ),
        ),
        const SizedBox(height: 44),
        Center(child: _primaryButton('אימות והתחברות', _verifyPhoneCode)),
      ],
    );
  }

  Widget _emailSentStep() {
    return Column(
      key: const ValueKey('email-sent'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: .16),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mark_email_read_rounded, color: _accent, size: 32),
        ),
        const SizedBox(height: 16),
        const Text(
          'אם קיים חשבון עם כתובת המייל שהזנת, נשלח אליו מייל לאיפוס הסיסמה. בדוק גם בתיקיית הספאם.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _text, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
        ),
        const SizedBox(height: 22),
        _primaryButton('סגירה', () => Navigator.of(context).pop()),
      ],
    );
  }

  Widget _emailEntryStep() {
    return Column(
      key: const ValueKey('email-entry'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'לקבלת מייל לאיפוס הסיסמה',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.left,
              onFieldSubmitted: (_) => _busy ? null : _sendResetEmail(),
              style: const TextStyle(color: _text, fontWeight: FontWeight.w600),
              decoration: _fieldDecoration('כתובת מייל'),
            ),
          ),
        ),
        const SizedBox(height: 44),
        Center(child: _primaryButton('שליחת מייל לאיפוס', _sendResetEmail)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.of(context).size;
    final dialogWidth = mediaSize.width > 380 ? 340.0 : mediaSize.width - 32;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final isPhoneCodeStep =
        _method == _RecoveryMethod.phone && _phoneStep == 1;

    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: dialogWidth),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(1.6),
        child: Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(27),
          ),
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 40,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Text(
                      'שחזור חשבון',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: _muted.withValues(alpha: .8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (_method == _RecoveryMethod.phone || !_emailSent)
                Row(
                  children: [
                    _tabButton('טלפון', _RecoveryMethod.phone),
                    _tabButton('מייל', _RecoveryMethod.email),
                  ],
                ),
              const SizedBox(height: 8),
              Stack(
                alignment: Alignment.topCenter,
                children: [
                  _stepLayer(
                    visible: _method == _RecoveryMethod.phone && _phoneStep == 0,
                    child: _phoneEntryStep(),
                  ),
                  _stepLayer(
                    visible: isPhoneCodeStep,
                    child: _phoneCodeStep(),
                  ),
                  _stepLayer(
                    visible: _method == _RecoveryMethod.email && !_emailSent,
                    child: _emailEntryStep(),
                  ),
                  _stepLayer(
                    visible: _method == _RecoveryMethod.email && _emailSent,
                    child: _emailSentStep(),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (isPhoneCodeStep) {
              FocusScope.of(context).unfocus();
            } else {
              Navigator.of(context).maybePop();
            }
          },
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              color: Colors.black.withValues(alpha: .35),
              child: SafeArea(
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(bottom: keyboardInset),
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: bubble,
                      ),
                    ),
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
