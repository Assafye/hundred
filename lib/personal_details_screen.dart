import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'services/auth_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'login_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

class PersonalDetailsScreen extends StatefulWidget {
  const PersonalDetailsScreen({super.key});

  @override
  State<PersonalDetailsScreen> createState() => _PersonalDetailsScreenState();
}

class _PersonalDetailsScreenState extends State<PersonalDetailsScreen> {
  static const Color _bgTop = Color(0xFF0B1222);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFF9E7CFF);

  final AuthService _authService = AuthService();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEmailVerified = false;
  String _currentEmail = '';

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _loadCurrentDetails();
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _phoneController.dispose();
    _emailController.dispose();
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

  Future<void> _loadCurrentDetails() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = snapshot.data() ?? <String, dynamic>{};
    final phone = (data['phone'] as String? ?? '').trim();
    final authEmail = (user.email ?? '').trim();
    final storedBackupEmail = (data['backupEmail'] as String? ?? '').trim();
    final storedEmail = (data['email'] as String? ?? '').trim();
    final isSyntheticEmail =
        authEmail.endsWith('@${AuthService.phoneAuthDomain}');
    final effectiveRealEmail = !isSyntheticEmail && authEmail.isNotEmpty
        ? authEmail
        : (storedBackupEmail.isNotEmpty
            ? storedBackupEmail
            : (storedEmail.isNotEmpty &&
                    !storedEmail.endsWith('@${AuthService.phoneAuthDomain}')
                ? storedEmail
                : ''));
    final isBackupVerified = data['backupEmailVerified'] == true;
    final isEmailVerified = effectiveRealEmail.isNotEmpty &&
        (isBackupVerified || (!isSyntheticEmail && user.emailVerified));

    if (!mounted) return;
    setState(() {
      _currentEmail = effectiveRealEmail;
      _isEmailVerified = isEmailVerified;
      _phoneController.text = phone;
      _emailController.text = effectiveRealEmail;
      _isLoading = false;
    });
  }

  InputDecoration _fieldDecoration({
    required bool isLight,
    required String label,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: isLight ? const Color(0xFF5B6D85) : const Color(0xFFAFC1DF),
      ),
      filled: true,
      fillColor: isLight ? Colors.white : const Color(0xFF121A2A),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : _accentCyan.withValues(alpha: 0.14),
          width: 0.9,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : _accentCyan.withValues(alpha: 0.14),
          width: 0.9,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        borderSide: BorderSide(
          color: isLight
              ? const Color(0xFFB79BFF)
              : _accentPurple.withValues(alpha: 0.7),
          width: 1.0,
        ),
      ),
    );
  }

  Future<String?> _showEmailVerificationDialog({
    required String email,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    var isChecking = false;
    var isResending = false;
    String? dialogError;
    var resendAvailableAt = DateTime.now().add(const Duration(seconds: 45));
    Timer? resendTimer;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final remainingSeconds =
                resendAvailableAt.difference(DateTime.now()).inSeconds;
            final canResend = remainingSeconds <= 0;

            if (resendTimer == null && !canResend) {
              resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
                if (!context.mounted) {
                  t.cancel();
                  return;
                }
                setDialogState(() {});
                if (DateTime.now().isAfter(resendAvailableAt)) {
                  t.cancel();
                }
              });
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Dialog(
                backgroundColor: const Color(0xFF161E2E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: _accentCyan.withValues(alpha: 0.25),
                  ),
                ),
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.mark_email_unread_rounded,
                                  color: _accentCyan, size: 24),
                              SizedBox(width: 8),
                              Text(
                                'אימות כתובת מייל',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: isChecking
                                ? null
                                : () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white60, size: 22),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'שלחנו הודעת אימות לכתובת:\n$email',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'בדוק בתיבת הדואר הנכנס ובתיבת הספאם ולחץ אישור לאחר האימות במייל.',
                        style: TextStyle(
                          color: Color(0xFFB5C4DE),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          dialogError!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (isChecking) ...[
                        const SizedBox(height: 10),
                        const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _accentCyan,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: isChecking
                                  ? null
                                  : () async {
                                      setDialogState(() {
                                        isChecking = true;
                                        dialogError = null;
                                      });
                                      try {
                                        final confirmation = await _authService
                                            .confirmBackupEmail(
                                          expectedEmail: email,
                                        );
                                        if (!context.mounted) return;
                                        switch (confirmation) {
                                          case BackupEmailConfirmationResult
                                                .confirmed:
                                            Navigator.of(dialogContext)
                                                .pop('confirmed');
                                          case BackupEmailConfirmationResult
                                                .requiresRelogin:
                                            Navigator.of(dialogContext)
                                                .pop('relogin');
                                          case BackupEmailConfirmationResult
                                                .pending:
                                            setDialogState(() {
                                              isChecking = false;
                                              dialogError =
                                                  'עדיין לא זיהינו אימות של המייל. יש ללחוץ על הקישור שנשלח אליך במייל ולנסות שוב.';
                                            });
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          setDialogState(() {
                                            isChecking = false;
                                            dialogError =
                                                'אירעה שגיאה בבדיקה: $e';
                                          });
                                        }
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _accentPurple,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text('אישור',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: (isChecking ||
                                      isResending ||
                                      !canResend)
                                  ? null
                                  : () async {
                                      setDialogState(() {
                                        isResending = true;
                                        dialogError = null;
                                      });
                                      try {
                                        await user
                                            .verifyBeforeUpdateEmail(email);
                                        resendAvailableAt = DateTime.now()
                                            .add(const Duration(seconds: 45));
                                        if (context.mounted) {
                                          setDialogState(() {
                                            isResending = false;
                                            dialogError =
                                                'הודעת אימות נשלחה שוב בהצלחה.';
                                          });
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          setDialogState(() {
                                            isResending = false;
                                            dialogError =
                                                'לא הצלחנו לשלוח שוב כרגע.';
                                          });
                                        }
                                      }
                                    },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: canResend
                                      ? _accentCyan.withValues(alpha: 0.5)
                                      : Colors.white12,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Text(
                                canResend
                                    ? 'שליחה חוזרת'
                                    : 'שליחה חוזרת ($remainingSeconds)',
                                style: TextStyle(
                                  color:
                                      canResend ? _accentCyan : Colors.white38,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    resendTimer?.cancel();
    return result;
  }

  Future<void> _saveDetails() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    if (uid == null || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להתחבר מחדש כדי לשמור שינויים.')),
      );
      return;
    }

    final phoneValue = _phoneController.text.trim();
    final emailValue = _emailController.text.trim();

    setState(() {
      _isSaving = true;
    });

    try {
      final normalizedEmail = emailValue.toLowerCase();
      final normalizedCurrent = _currentEmail.trim().toLowerCase();
      final isEmailChangedOrUnverified = normalizedEmail.isNotEmpty &&
          (normalizedEmail != normalizedCurrent || !_isEmailVerified);

      if (isEmailChangedOrUnverified) {
        final isTaken =
            await _authService.isEmailTaken(emailValue, excludeUid: uid);
        if (isTaken) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('כתובת המייל הזו כבר משויכת לחשבון אחר.'),
            ),
          );
          return;
        }

        try {
          await user!.verifyBeforeUpdateEmail(emailValue);
        } on FirebaseAuthException catch (e) {
          if (e.code == 'requires-recent-login') {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('לצורך שינוי מייל יש להתחבר מחדש לאפליקציה.'),
              ),
            );
            return;
          }
          if (e.code == 'email-already-in-use') {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('כתובת המייל הזו כבר משויכת לחשבון אחר.'),
              ),
            );
            return;
          }
          await user!.sendEmailVerification();
        }

        if (!mounted) return;
        final confirmation = await _showEmailVerificationDialog(
          email: emailValue,
        );

        if (!mounted) return;
        if (confirmation == 'confirmed') {
          setState(() {
            _currentEmail = emailValue;
            _isEmailVerified = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('המייל אומת ועודכן בהצלחה!')),
          );
          Navigator.of(context).pop(true);
        } else if (confirmation == 'relogin') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'המייל אומת בהצלחה! מסיבות אבטחה יש להתחבר מחדש כדי להשלים את השמירה.',
              ),
            ),
          );
          try {
            await FirebaseAuth.instance.signOut();
          } catch (_) {}
          if (!mounted) return;
          // Use the root navigator: any screens still on nested stacks hold a
          // now-dead session and must not remain mounted after this reset.
          Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
          );
        }
        return;
      }

      await _authService.updateContactDetails(
        uid: uid,
        phone: phoneValue,
        email: normalizedCurrent.isNotEmpty ? normalizedCurrent : null,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הפרטים נשמרו בהצלחה.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שגיאה בשמירת הפרטים: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.62).clamp(180.0, 220.0);
    final orbSizeB = (screenWidth * 0.72).clamp(200.0, 260.0);
    final scaffoldBg = isLight ? const Color(0xFFF5F8FF) : _bgBottom;
    final appBarBg = isLight ? Colors.white : const Color(0xFF0B1222);
    final titleColor = isLight ? const Color(0xFF101826) : Colors.white;
    final bodyColor = isLight ? const Color(0xFF101826) : Colors.white;
    final mutedColor = isLight ? const Color(0xFF5B6D85) : Colors.white70;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: scaffoldBg,
          appBar: AppBar(
            backgroundColor: appBarBg,
            elevation: 0,
            centerTitle: true,
            title: Text(
              'עריכת פרטים אישיים',
              style: TextStyle(
                  color: titleColor, fontWeight: FontWeight.w700, fontSize: 21),
            ),
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isLight
                          ? const [Color(0xFFF7FAFF), Color(0xFFEFF5FF)]
                          : const [_bgTop, Color(0xFF0E1627), _bgBottom],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -70,
                right: -40,
                child: Container(
                  width: orbSizeA,
                  height: orbSizeA,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (isLight ? const Color(0xFF9EEBFF) : _accentCyan)
                        .withValues(alpha: isLight ? 0.15 : 0.08),
                  ),
                ),
              ),
              Positioned(
                bottom: -100,
                left: -50,
                child: Container(
                  width: orbSizeB,
                  height: orbSizeB,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (isLight ? const Color(0xFFB9A9FF) : _accentPurple)
                        .withValues(alpha: isLight ? 0.16 : 0.09),
                  ),
                ),
              ),
              SafeArea(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _dismissKeyboardOnBackgroundTap,
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              padding: EdgeInsets.zero,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight),
                                child: Container(
                                  width: double.infinity,
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 16, 20, 96),
                                  decoration: const BoxDecoration(),
                                  child: Form(
                                    key: _formKey,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          'טלפון ומייל',
                                          style: TextStyle(
                                            color: titleColor,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          ' ',
                                          style: TextStyle(
                                              color: mutedColor,
                                              fontWeight: FontWeight.w400),
                                        ),
                                        const SizedBox(height: 18),
                                        TextFormField(
                                          controller: _phoneController,
                                          readOnly: true,
                                          onTapOutside: (_) {},
                                          keyboardType: TextInputType.phone,
                                          textDirection: TextDirection.ltr,
                                          textAlign: TextAlign.right,
                                          style: TextStyle(color: bodyColor),
                                          decoration: _fieldDecoration(
                                            isLight: isLight,
                                            label: 'מספר טלפון',
                                          ),
                                          validator: (value) {
                                            final text = value?.trim() ?? '';
                                            if (text.isEmpty) return null;
                                            if (text.length < 7) {
                                              return 'מספר טלפון לא תקין';
                                            }
                                            return null;
                                          },
                                        ),
                                        const SizedBox(height: 6),
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            'מספר הטלפון הוא מזהה הכניסה ואינו ניתן לשינוי .',
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              color: mutedColor,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        TextFormField(
                                          controller: _emailController,
                                          onTapOutside: (_) {},
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          textDirection: TextDirection.ltr,
                                          textAlign: TextAlign.right,
                                          style: TextStyle(color: bodyColor),
                                          decoration: _fieldDecoration(
                                            isLight: isLight,
                                            label: 'מייל',
                                          ),
                                          validator: (value) {
                                            final text = value?.trim() ?? '';
                                            if (text.isEmpty) {
                                              return 'יש להזין מייל';
                                            }
                                            if (!RegExp(
                                                    r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                                .hasMatch(text)) {
                                              return 'כתובת מייל לא תקינה';
                                            }
                                            return null;
                                          },
                                        ),
                                        if (!_isEmailVerified) ...[
                                          const SizedBox(height: 6),
                                          const Align(
                                            alignment: Alignment.centerRight,
                                            child: Text(
                                              'יש לאמת מייל למשתמש',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 18),
                                        ElevatedButton.icon(
                                          onPressed:
                                              _isSaving ? null : _saveDetails,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: isLight
                                                ? Colors.white
                                                : _accentPurple,
                                            foregroundColor: isLight
                                                ? const Color(0xFFB79BFF)
                                                : Colors.black,
                                            side: isLight
                                                ? const BorderSide(
                                                    color: Color(0xFFB79BFF),
                                                    width: 1,
                                                  )
                                                : BorderSide.none,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 16),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            elevation: 0,
                                          ),
                                          icon: _isSaving
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: Color(0xFFB79BFF),
                                                  ),
                                                )
                                              : const Icon(Icons.save_rounded),
                                          label: Text(
                                            _isSaving
                                                ? 'שומר...'
                                                : 'שמור שינויים',
                                            style: TextStyle(
                                              color: isLight
                                                  ? const Color(0xFFB79BFF)
                                                  : Colors.black,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
