import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'age_restrictions.dart';
import 'login_screen.dart';
import 'privacy_policy_dialog.dart';
import 'services/auth_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'usage_guide_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({
    super.key,
    this.initialStep = 0,
    this.prefilledEmail,
    this.prefilledPassword,
    this.onExitToLogin,
  });

  final int initialStep;
  final String? prefilledEmail;
  final String? prefilledPassword;
  final VoidCallback? onExitToLogin;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  static const Color _bgTop = Color(0xFF0B1222);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _primary = Color(0xFF7B79FF);
  static const Color _accent = Color(0xFF53D9FF);
  static const Color _textPrimary = Color(0xFFEAF0FF);
  static const Color _textSecondary = Color(0xFFAAB7E8);
  static const Color _fieldFill = Color(0xFF141D2E);
  static const int _maxProfileImages = 6;
  static const String _passwordRequirementsMessage =
      'הסיסמה חייבת לכלול לפחות 7 תווים, אות גדולה באנגלית, אות קטנה באנגלית, מספר אחד וסימן מיוחד אחד ';

  final _detailsFormKey = GlobalKey<FormState>();
  final _profileFormKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _birthDateController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _handleController = TextEditingController();
  final TextEditingController _lifeMottoController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _backupEmailController = TextEditingController();

  final AuthService _authService = AuthService();

  DateTime? _birthDate;
  final List<XFile> _profileImages = <XFile>[];

  bool _isPickingProfileImages = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;
  bool _animateBg = false;
  bool _isRegistering = false;
  bool _isCheckingUsername = false;
  bool _isUsernameTaken = false;
  bool _isRestoringDraft = false;
  String? _usernameAvailabilityError;

  Timer? _usernameDebounce;

  int _currentStep = 0;
  int _profileStage = 0;

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _currentStep = widget.initialStep.clamp(0, 1);
    _isRestoringDraft = _currentStep == 1;
    if (widget.prefilledEmail != null &&
        widget.prefilledEmail!.trim().isNotEmpty) {
      _emailController.text = widget.prefilledEmail!.trim();
    }
    if (widget.prefilledPassword != null &&
        widget.prefilledPassword!.trim().isNotEmpty) {
      _passwordController.text = widget.prefilledPassword!.trim();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _restorePendingRegistrationDraft();
      if (!mounted) return;
      setState(() {
        _animateBg = true;
        _isRestoringDraft = false;
      });
    });
  }

  int _profileStageFromName(String stage) {
    switch (stage) {
      case 'username':
        return 0;
      case 'images':
        return 1;
      case 'birth_date':
        return 2;
      case 'bio':
      case 'profile_summary':
        return 3;
      default:
        return 0;
    }
  }

  Future<void> _restorePendingRegistrationDraft() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final email = (widget.prefilledEmail ?? _emailController.text).trim();

    Map<String, dynamic> draft = <String, dynamic>{};
    if (currentUser != null) {
      draft =
          await _authService.loadPendingRegistrationDraftByUid(currentUser.uid);
    }
    if (draft.isEmpty && email.isNotEmpty) {
      draft = await _authService.loadPendingRegistrationDraftByEmail(email);
    }
    if (draft.isEmpty) {
      return;
    }

    final firstName = (draft['firstName'] as String? ?? '').trim();
    final lastName = (draft['lastName'] as String? ?? '').trim();
    final displayName = (draft['displayName'] as String? ?? '').trim();
    final username = (draft['username'] as String? ?? '').trim();
    final birthDate = (draft['birthDate'] as String? ?? '').trim();
    final phone = (draft['phone'] as String? ?? '').trim();
    final lifeMotto = (draft['lifeMotto'] as String? ?? '').trim();
    final bio = (draft['bio'] as String? ?? '').trim();
    final stage = (draft['onboardingStage'] as String? ?? '').trim();

    if (firstName.isNotEmpty) {
      _firstNameController.text = firstName;
    }
    if (lastName.isNotEmpty) {
      _lastNameController.text = lastName;
    }
    if (displayName.isNotEmpty) {
      _displayNameController.text = displayName;
    } else if (firstName.isNotEmpty || lastName.isNotEmpty) {
      _displayNameController.text = _normalizedName('$firstName $lastName');
    }
    if (username.isNotEmpty) {
      _handleController.text =
          username.startsWith('@') ? username.substring(1) : username;
    }
    if (lifeMotto.isNotEmpty) {
      _lifeMottoController.text = lifeMotto;
    }
    if (bio.isNotEmpty) {
      _bioController.text = bio;
    }
    if (birthDate.isNotEmpty) {
      _birthDateController.text = birthDate;
      final parsed =
          _parseDdMmYyyy(birthDate) ?? parseStoredBirthDate(birthDate);
      if (parsed != null) {
        _birthDate = parsed;
        _birthDateController.text = _formatDate(parsed);
      }
    }
    if (phone.isNotEmpty) {
      _phoneController.text = phone;
    }
    if (stage.isNotEmpty && stage != 'credentials') {
      _profileStage = _profileStageFromName(stage);
    }
  }

  Future<User?> _ensureAuthenticatedForRegistration() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      return currentUser;
    }

    final email = (widget.prefilledEmail ?? _emailController.text).trim();
    final password =
        (widget.prefilledPassword ?? _passwordController.text).trim();

    if (email.isNotEmpty && password.isNotEmpty) {
      try {
        final credential =
            await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        return credential.user;
      } catch (_) {}
    }

    return null;
  }

  DateTime? _resolvedBirthDate() {
    if (_birthDate != null) {
      return _birthDate;
    }

    final raw = _birthDateController.text.trim();
    if (raw.isEmpty) {
      return null;
    }

    final parts = raw.split('/');
    if (parts.length != 3) {
      return null;
    }

    try {
      final day = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final year = int.parse(parts[2]);
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
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
    _usernameDebounce?.cancel();
    unawaited(_authService.endPendingRegistrationFlow(signOut: true));
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _birthDateController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _displayNameController.dispose();
    _handleController.dispose();
    _lifeMottoController.dispose();
    _bioController.dispose();
    _backupEmailController.dispose();
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

  String _registrationErrorMessage(Object error) {
    if (error is! FirebaseAuthException) {
      if (error is FirebaseException) {
        switch (error.code) {
          case 'permission-denied':
            return 'אין הרשאה לבצע את הפעולה כרגע. נסה/י שוב בעוד רגע.';
          case 'unavailable':
          case 'network-request-failed':
            return 'אין חיבור יציב כרגע. בדוק/י אינטרנט ונסה/י שוב.';
          case 'deadline-exceeded':
          case 'timeout':
            return 'תם הזמן לביצוע הפעולה. נסה/י שוב.';
          default:
            final msg = (error.message ?? '').trim();
            if (msg.isNotEmpty) {
              return msg;
            }
            return 'לא הצלחנו להשלים את תהליך ההרשמה כרגע. נסה/י שוב.';
        }
      }

      if (error is TimeoutException) {
        return 'תם הזמן לביצוע הפעולה. נסה/י שוב.';
      }

      final rawMessage = error.toString().trim();
      if (rawMessage.isNotEmpty && rawMessage != 'Exception') {
        return rawMessage;
      }
      return 'לא הצלחנו להשלים את תהליך ההרשמה כרגע. נסה/י שוב.';
    }

    switch (error.code) {
      case 'email-already-in-use':
        return error.message ?? 'כתובת המייל הזו כבר בשימוש.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'כבר התחלת הרשמה עם כתובת המייל הזו, אבל הסיסמה שהוזנה לא תואמת.';
      case 'invalid-email':
        return 'כתובת המייל שהוזנה אינה תקינה.';
      case 'too-many-requests':
        return 'נשלחו יותר מדי בקשות אימות. נסה שוב בעוד כמה דקות.';
      case 'session-expired':
        return error.message ?? 'פג תוקף תהליך האימות. יש להתחיל שוב.';
      case AuthService.emailNotVerifiedCode:
        return 'עדיין לא זיהינו אימות מייל. פתח/י את ההודעה ולחץ/י על קישור האימות.';
      case AuthService.registrationIncompleteCode:
        return 'יש להשלים את שלב יצירת הפרופיל לפני שניתן להתחבר.';
      default:
        return error.message ?? 'אירעה שגיאה בתהליך ההרשמה.';
    }
  }

  Future<bool> _showEmailVerificationDialog({
    required PendingRegistrationState state,
  }) async {
    var isBusy = false;
    String? errorMessage;
    var resendAvailableAt = DateTime.now().add(const Duration(minutes: 1));
    Timer? resendTimer;

    String resendCountdownLabel() {
      final remainingSeconds =
          resendAvailableAt.difference(DateTime.now()).inSeconds;
      if (remainingSeconds <= 0) {
        return 'שלח שוב';
      }

      final minutes = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
      final seconds = (remainingSeconds % 60).toString().padLeft(2, '0');
      return 'שלח שוב בעוד $minutes:$seconds';
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            resendTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
              if (!dialogContext.mounted) {
                timer.cancel();
                return;
              }
              setDialogState(() {});
              if (!DateTime.now().isBefore(resendAvailableAt)) {
                timer.cancel();
              }
            });

            Future<void> resendEmail() async {
              if (DateTime.now().isBefore(resendAvailableAt)) {
                return;
              }

              setDialogState(() {
                isBusy = true;
                errorMessage = null;
              });

              try {
                await _authService.resendPendingEmailVerification();
                setDialogState(() {
                  resendAvailableAt =
                      DateTime.now().add(const Duration(minutes: 1));
                });
                resendTimer?.cancel();
                resendTimer =
                    Timer.periodic(const Duration(seconds: 1), (timer) {
                  if (!dialogContext.mounted) {
                    timer.cancel();
                    return;
                  }
                  setDialogState(() {});
                  if (!DateTime.now().isBefore(resendAvailableAt)) {
                    timer.cancel();
                  }
                });
              } catch (e) {
                setDialogState(() {
                  errorMessage = _registrationErrorMessage(e);
                });
              } finally {
                setDialogState(() {
                  isBusy = false;
                });
              }
            }

            Future<void> confirmVerification() async {
              setDialogState(() {
                isBusy = true;
                errorMessage = null;
              });

              try {
                final isVerified =
                    await _authService.refreshPendingEmailVerificationStatus();
                if (!mounted || !dialogContext.mounted) return;

                if (isVerified) {
                  Navigator.of(dialogContext).pop(true);
                  return;
                }

                setDialogState(() {
                  errorMessage =
                      'עדיין לא זיהינו אימות. אשר/י את המייל ואז לחץ/י שוב על "כבר אימתתי".';
                });
              } catch (e) {
                if (e is FirebaseAuthException && e.code == 'session-expired') {
                  try {
                    final restoredState =
                        await _authService.beginEmailVerificationRegistration(
                      email: _emailController.text.trim(),
                      password: _passwordController.text.trim(),
                    );
                    if (!mounted || !dialogContext.mounted) return;

                    if (restoredState.isVerified) {
                      Navigator.of(dialogContext).pop(true);
                      return;
                    }

                    setDialogState(() {
                      errorMessage =
                          'האימות עדיין לא הושלם. אשר/י את המייל ואז לחץ/י שוב על "כבר אימתתי".';
                    });
                    return;
                  } catch (_) {
                    // Fall back to the original session-expired message below.
                  }
                }
                setDialogState(() {
                  errorMessage = _registrationErrorMessage(e);
                });
              } finally {
                if (mounted) {
                  setDialogState(() {
                    isBusy = false;
                  });
                }
              }
            }

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1B2442), Color(0xFF101827)],
                  ),
                  border: Border.all(
                    color: const Color(0xFF53D9FF).withValues(alpha: 0.26),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 30,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: IconButton(
                        onPressed: isBusy
                            ? null
                            : () => Navigator.of(dialogContext).pop(false),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _textSecondary,
                        ),
                        tooltip: 'סגירה',
                      ),
                    ),
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF7B79FF), Color(0xFF53D9FF)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF53D9FF).withValues(alpha: 0.35),
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
                    Text(
                      state.email,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'אשר/י את המייל וחזור/י לכאן. לא הגיע? בדוק/י ספאם או שלח/י שוב.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isBusy ? null : confirmVerification,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: isBusy
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
                      child: TextButton(
                        onPressed:
                            isBusy || DateTime.now().isBefore(resendAvailableAt)
                                ? null
                                : resendEmail,
                        child: Text(
                          resendCountdownLabel(),
                          style: const TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    resendTimer?.cancel();

    return result == true;
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
            BorderSide(color: _accent.withValues(alpha: 0.14), width: 0.9),
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
      errorMaxLines: 5,
      errorStyle: const TextStyle(color: Colors.redAccent),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
    List<TextInputFormatter>? inputFormatters,
    String? prefixText,
    int minLines = 1,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        onTapOutside: (_) {},
        keyboardType: keyboardType,
        obscureText: obscureText,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        minLines: minLines,
        maxLines: maxLines,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        style:
            const TextStyle(color: _textPrimary, fontWeight: FontWeight.w500),
        decoration: _inputDecoration(label).copyWith(
          suffixIcon: suffixIcon,
          prefixText: prefixText,
          prefixStyle: const TextStyle(
              color: _textSecondary, fontWeight: FontWeight.w500),
        ),
        validator: validator,
      ),
    );
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(1930),
      lastDate: now,
      initialDate: _birthDate ?? DateTime(now.year - 18, now.month, now.day),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _primary,
              surface: Color(0xFF1F2750),
              onPrimary: Colors.white,
              onSurface: _textPrimary,
            ),
            dialogTheme:
                const DialogThemeData(backgroundColor: Color(0xFF1A2247)),
          ),
          child: child!,
        );
      },
    );

    if (selected == null || !mounted) return;

    setState(() {
      _birthDate = selected;
      _birthDateController.text = _formatDate(selected);
    });
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final y = date.year.toString();
    return '$d/$m/$y';
  }

  String _normalizedName(String? value) {
    return (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _nameValidator(String? value) {
    final normalized = _normalizedName(value);
    if (normalized.isEmpty) return 'שדה חובה';
    if (normalized.runes.length < 2) return 'לפחות 2 אותיות';
    return null;
  }

  String _autoFormatBirthDateInput(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    final trimmed = digits.length > 8 ? digits.substring(0, 8) : digits;
    if (trimmed.length <= 2) {
      return trimmed;
    }
    if (trimmed.length <= 4) {
      return '${trimmed.substring(0, 2)}/${trimmed.substring(2)}';
    }
    return '${trimmed.substring(0, 2)}/${trimmed.substring(2, 4)}/${trimmed.substring(4)}';
  }

  String? _passwordValidator(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return _passwordRequirementsMessage;
    if (text.length < 7) return _passwordRequirementsMessage;
    if (!RegExp(r'[A-Z]').hasMatch(text)) return _passwordRequirementsMessage;
    if (!RegExp(r'[a-z]').hasMatch(text)) return _passwordRequirementsMessage;
    if (!RegExp(r'[0-9]').hasMatch(text)) return _passwordRequirementsMessage;
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(text)) {
      return _passwordRequirementsMessage;
    }
    return null;
  }

  DateTime? _parseDdMmYyyy(String value) {
    return parseStoredBirthDate(value);
  }

  void _removeProfileImage(int index) {
    if (index < 0 || index >= _profileImages.length) return;
    setState(() {
      _profileImages.removeAt(index);
    });
  }

  void _setDefaultProfileImage(int index) {
    if (index <= 0 || index >= _profileImages.length) return;

    setState(() {
      final selected = _profileImages.removeAt(index);
      _profileImages.insert(0, selected);
    });
  }

  Future<void> _showDefaultImagePickerDialog() async {
    if (_profileImages.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש לבחור קודם תמונות פרופיל.')),
      );
      return;
    }

    var selectedIndex = 0;

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2752),
              title: const Text(
                'בחירת תמונת ברירת מחדל',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: min(MediaQuery.of(context).size.width * 0.8, 340),
                child: GridView.builder(
                  shrinkWrap: true,
                  itemCount: _profileImages.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    final image = _profileImages[index];
                    final isSelected = selectedIndex == index;

                    return GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedIndex = index;
                        });
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color:
                                isSelected ? _accent : const Color(0xFF3A467E),
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              kIsWeb
                                  ? Image.network(image.path, fit: BoxFit.cover)
                                  : Image.file(File(image.path),
                                      fit: BoxFit.cover),
                              if (isSelected)
                                const Align(
                                  alignment: Alignment.topRight,
                                  child: Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(
                                      Icons.check_circle,
                                      color: _accent,
                                      size: 18,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text(
                    'ביטול',
                    style: TextStyle(color: _textSecondary),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('שמור'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave != true || !mounted) return;
    _setDefaultProfileImage(selectedIndex);
  }

  Future<void> _pickProfileImages() async {
    if (_isPickingProfileImages) return;

    final remaining = _maxProfileImages - _profileImages.length;
    if (remaining <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ניתן להעלות עד 6 תמונות פרופיל.')),
      );
      return;
    }

    setState(() {
      _isPickingProfileImages = true;
    });

    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1080,
      );

      if (!mounted) return;
      if (picked.isEmpty) return;

      final selected = picked.take(remaining).toList(growable: false);
      setState(() {
        _profileImages.addAll(selected);
      });

      if (picked.length > remaining) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('נשמרו $remaining תמונות בלבד (מקסימום 6).')),
        );
      }
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('לא הצלחנו לגשת לגלריה. בדוק הרשאות ונסה שוב.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPickingProfileImages = false;
        });
      }
    }
  }

  void _onHandleChanged(String value) {
    _usernameDebounce?.cancel();
    final clean = value.trim();

    if (clean.length < 3) {
      if (!mounted) return;
      setState(() {
        _isCheckingUsername = false;
        _isUsernameTaken = false;
        _usernameAvailabilityError = null;
      });
      return;
    }

    setState(() {
      _isCheckingUsername = true;
      _isUsernameTaken = false;
      _usernameAvailabilityError = null;
    });

    _usernameDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final currentUid = FirebaseAuth.instance.currentUser?.uid;
        final isTaken = await _authService.isUsernameTaken(
          '@$clean',
          excludeUid: currentUid,
        );
        if (!mounted || _handleController.text.trim() != clean) return;
        setState(() {
          _isCheckingUsername = false;
          _isUsernameTaken = isTaken;
          _usernameAvailabilityError = isTaken ? 'היוזר תפוס' : null;
        });
      } catch (_) {
        if (!mounted || _handleController.text.trim() != clean) return;
        setState(() {
          _isCheckingUsername = false;
          _isUsernameTaken = false;
          _usernameAvailabilityError = null;
        });
      }
    });
  }

  Future<void> _continueFromDetailsStep() async {
    final formState = _detailsFormKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }

    setState(() {
      _isRegistering = true;
    });

    try {
      final email = _emailController.text.trim();
      final emailTaken = await _authService.isEmailTaken(
        email,
      );
      if (emailTaken) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'יש חשבון עם המייל שהזנת, יש ללכת למסך ההתחברות',
            ),
          ),
        );
        return;
      }

      final phoneTaken = await _authService.isPhoneTaken(
        _phoneController.text.trim(),
      );
      if (phoneTaken) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('מספר הטלפון כבר משויך לחשבון קיים.')),
        );
        return;
      }

      final verificationState =
          await _authService.beginEmailVerificationRegistration(
        email: email,
        password: _passwordController.text.trim(),
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
        phone: _phoneController.text,
      );

      if (!mounted) return;

      bool isVerified = verificationState.isVerified;
      if (isVerified) {
        // Enforce a fresh server-backed verification status before allowing
        // transition to step 2.
        isVerified = await _authService.refreshPendingEmailVerificationStatus();
      }

      if (!isVerified) {
        isVerified =
            await _showEmailVerificationDialog(state: verificationState);
      }

      if (!mounted) return;
      if (!isVerified) {
        await _authService.endPendingRegistrationFlow(signOut: true);
        return;
      }

      setState(() {
        _currentStep = 1;
      });
    } catch (e, stackTrace) {
      debugPrint('[RegisterScreen][_continueFromDetailsStep] error: $e');
      debugPrint(
        '[RegisterScreen][_continueFromDetailsStep] stackTrace: $stackTrace',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_registrationErrorMessage(e))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  Future<bool> _showProfileSummary({required DateTime birthDate}) async {
    var accepted = false;
    final displayName = _displayNameController.text.trim();
    final username = '@${_handleController.text.trim()}';
    final lifeMotto = _lifeMottoController.text.trim();
    final bio = _bioController.text.trim();
    final birthDateStr = _formatDate(birthDate);

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1B263B), Color(0xFF101726)],
                    ),
                    border: Border.all(
                      color: _accent.withValues(alpha: 0.25),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 32,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
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
                                Icon(Icons.person_outline_rounded,
                                    color: _accent, size: 22),
                                SizedBox(width: 8),
                                Text(
                                  'פרופיל משתמש',
                                  style: TextStyle(
                                    color: _textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              icon: const Icon(Icons.close_rounded,
                                  color: _textSecondary, size: 22),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'אלו פרטי הפרופיל שלך, ניתן לערוך אותם בכל עת מתוך האפליקציה.',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Preview Card container
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131D2F),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _accent.withValues(alpha: 0.15),
                              width: 0.9,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Avatar / Images row
                              if (_profileImages.isNotEmpty) ...[
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _accent,
                                      width: 2.2,
                                    ),
                                  ),
                                  child: ClipOval(
                                    child: kIsWeb
                                        ? Image.network(
                                            _profileImages.first.path,
                                            fit: BoxFit.cover,
                                          )
                                        : Image.file(
                                            File(_profileImages.first.path),
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                                if (_profileImages.length > 1) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 50,
                                    child: Center(
                                      child: ListView.separated(
                                        shrinkWrap: true,
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _profileImages.length - 1,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(width: 8),
                                        itemBuilder: (context, index) {
                                          final image =
                                              _profileImages[index + 1];
                                          return Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: _primary.withValues(
                                                  alpha: 0.55,
                                                ),
                                                width: 1.2,
                                              ),
                                            ),
                                            child: ClipOval(
                                              child: kIsWeb
                                                  ? Image.network(
                                                      image.path,
                                                      fit: BoxFit.cover,
                                                    )
                                                  : Image.file(
                                                      File(image.path),
                                                      fit: BoxFit.cover,
                                                    ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                              ],
                              Text(
                                displayName,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                username,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _accent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.cake_outlined,
                                    color: _textSecondary,
                                    size: 15,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    birthDateStr,
                                    style: const TextStyle(
                                      color: _textSecondary,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              if (lifeMotto.isNotEmpty || bio.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F1726),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: _accent.withValues(alpha: 0.1),
                                    ),
                                  ),
                                  child: Text(
                                    lifeMotto.isNotEmpty
                                        ? (bio.isNotEmpty
                                            ? '$lifeMotto\n$bio'
                                            : lifeMotto)
                                        : bio,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: _textPrimary,
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Terms & Privacy checkbox with links
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: accepted,
                              fillColor: const WidgetStatePropertyAll(_primary),
                              checkColor: Colors.white,
                              onChanged: (value) => setDialogState(
                                () => accepted = value ?? false,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Wrap(
                                  alignment: WrapAlignment.start,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    const Text(
                                      'קראתי את ',
                                      style: TextStyle(
                                        color: _textSecondary,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          showPrivacyPolicyDialog(context),
                                      child: const Text(
                                        'מדיניות הפרטיות',
                                        style: TextStyle(
                                          color: _accent,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          decoration: TextDecoration.underline,
                                          decorationColor: _accent,
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      ' ואת ',
                                      style: TextStyle(
                                        color: _textSecondary,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          showTermsOfUseDialog(context),
                                      child: const Text(
                                        'תנאי השימוש',
                                        style: TextStyle(
                                          color: _accent,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          decoration: TextDecoration.underline,
                                          decorationColor: _accent,
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      ' ואני מאשר/ת אותם',
                                      style: TextStyle(
                                        color: _textSecondary,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: accepted
                                ? () => Navigator.of(dialogContext).pop(true)
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                            ),
                            child: const Text(
                              'צור חשבון',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
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
        );
      },
    );
    return result == true;
  }

  /// Offers adding a backup email and waits for the user to confirm the
  /// verification link before continuing. Returns true if the confirmation
  /// forced a session re-login (registration must resume after login).
  Future<bool> _offerBackupEmail() async {
    _backupEmailController.clear();
    var verificationSent = false;
    var isWorking = false;
    String? pageError;

    final requiresRelogin = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (screenContext) {
          return StatefulBuilder(
            builder: (context, setPageState) {
              Future<void> handlePrimaryAction() async {
                if (isWorking) return;
                final email = _backupEmailController.text.trim();
                if (!verificationSent) {
                  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                    setPageState(
                        () => pageError = 'יש להזין כתובת מייל תקינה.');
                    return;
                  }
                  setPageState(() {
                    isWorking = true;
                    pageError = null;
                  });
                  try {
                    await _authService.linkBackupEmailCredential(
                      email: email,
                      password: _passwordController.text.trim(),
                    );
                    if (!context.mounted) return;
                    setPageState(() {
                      verificationSent = true;
                      isWorking = false;
                    });
                  } catch (error) {
                    if (!context.mounted) return;
                    setPageState(() {
                      isWorking = false;
                      pageError = 'לא הצלחנו לשלוח את האימות. יש לנסות שוב.';
                    });
                  }
                  return;
                }

                setPageState(() {
                  isWorking = true;
                  pageError = null;
                });
                try {
                  final confirmation = await _authService.confirmBackupEmail(
                    expectedEmail: email,
                  );
                  if (!context.mounted) return;
                  switch (confirmation) {
                    case BackupEmailConfirmationResult.confirmed:
                      Navigator.of(screenContext).pop(false);
                    case BackupEmailConfirmationResult.requiresRelogin:
                      Navigator.of(screenContext).pop(true);
                    case BackupEmailConfirmationResult.pending:
                      setPageState(() {
                        isWorking = false;
                        pageError =
                            'עדיין לא זיהינו את האימות. יש ללחוץ על הקישור במייל ולנסות שוב.';
                      });
                  }
                } catch (_) {
                  if (!context.mounted) return;
                  setPageState(() {
                    isWorking = false;
                    pageError = 'לא הצלחנו לבדוק את האימות. יש לנסות שוב.';
                  });
                }
              }

              return Scaffold(
                backgroundColor: _bgBottom,
                resizeToAvoidBottomInset: false,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [_bgTop, Color(0xFF0E1627), _bgBottom],
                        ),
                      ),
                    ),
                    Positioned(
                      top: -90,
                      right: -100,
                      child: Container(
                        width: 270,
                        height: 270,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [Color(0x3653D9FF), Color(0x0053D9FF)],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -120,
                      left: -110,
                      child: Container(
                        width: 310,
                        height: 310,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [Color(0x3B7B79FF), Color(0x007B79FF)],
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final keyboardInset =
                              MediaQuery.viewInsetsOf(context).bottom;
                          return Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: _dismissKeyboardOnBackgroundTap,
                            child: SingleChildScrollView(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: EdgeInsets.fromLTRB(
                                24,
                                16,
                                24,
                                keyboardInset + 28,
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: (constraints.maxHeight -
                                          keyboardInset -
                                          44)
                                      .clamp(0.0, double.infinity)
                                      .toDouble(),
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 440),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: IconButton(
                                            onPressed: isWorking
                                                ? null
                                                : () =>
                                                    Navigator.of(screenContext)
                                                        .pop(false),
                                            icon: const Icon(
                                              Icons.close_rounded,
                                              color: _textSecondary,
                                            ),
                                            tooltip: 'לא עכשיו',
                                          ),
                                        ),
                                        Center(
                                          child: Container(
                                            width: 82,
                                            height: 82,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(26),
                                              gradient: const LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [_accent, _primary],
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: _primary.withValues(
                                                    alpha: .34,
                                                  ),
                                                  blurRadius: 26,
                                                  offset: const Offset(0, 10),
                                                ),
                                              ],
                                            ),
                                            child: Icon(
                                              verificationSent
                                                  ? Icons
                                                      .mark_email_read_rounded
                                                  : Icons
                                                      .alternate_email_rounded,
                                              color: Colors.white,
                                              size: 40,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                        Text(
                                          verificationSent
                                              ? 'אימות מייל הגיבוי'
                                              : 'הוספת מייל גיבוי',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: _textPrimary,
                                            fontSize: 28,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        const Text(
                                          'מייל גיבוי יאפשר התחברות ושחזור חשבון גם אם אין גישה למספר הטלפון.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: _textSecondary,
                                            fontSize: 14,
                                            height: 1.45,
                                          ),
                                        ),
                                        const SizedBox(height: 28),
                                        TextField(
                                          controller: _backupEmailController,
                                          enabled:
                                              !verificationSent && !isWorking,
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          textInputAction: TextInputAction.done,
                                          textDirection: TextDirection.ltr,
                                          textAlign: TextAlign.left,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          onSubmitted: (_) =>
                                              handlePrimaryAction(),
                                          style: const TextStyle(
                                            color: _textPrimary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          decoration: _inputDecoration(
                                            'מייל גיבוי',
                                          ).copyWith(
                                            prefixIcon: const Icon(
                                              Icons.mail_outline_rounded,
                                              color: _accent,
                                            ),
                                          ),
                                        ),
                                        if (verificationSent) ...[
                                          const SizedBox(height: 18),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 14,
                                            ),
                                            decoration: BoxDecoration(
                                              color: _accent.withValues(
                                                  alpha: .09),
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                              border: Border.all(
                                                color: _accent.withValues(
                                                    alpha: .24),
                                              ),
                                            ),
                                            child: const Text(
                                              'יש לבדוק בתיבת הדואר ותיבת הספאם וללחוץ אישור לאחר האימות',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: _textPrimary,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                height: 1.45,
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (pageError != null) ...[
                                          const SizedBox(height: 12),
                                          Text(
                                            pageError!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.redAccent,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 28),
                                        Center(
                                          child: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 220,
                                            ),
                                            transitionBuilder:
                                                (child, animation) {
                                              return FadeTransition(
                                                opacity: animation,
                                                child: ScaleTransition(
                                                  scale: Tween<double>(
                                                    begin: .94,
                                                    end: 1,
                                                  ).animate(animation),
                                                  child: child,
                                                ),
                                              );
                                            },
                                            child: SizedBox(
                                              key: ValueKey<bool>(
                                                verificationSent,
                                              ),
                                              width:
                                                  verificationSent ? 176 : 210,
                                              child: Directionality(
                                                textDirection:
                                                    TextDirection.ltr,
                                                child: ElevatedButton.icon(
                                                  onPressed: isWorking
                                                      ? null
                                                      : handlePrimaryAction,
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        verificationSent
                                                            ? _accent
                                                            : _primary,
                                                    foregroundColor:
                                                        verificationSent
                                                            ? const Color(
                                                                0xFF102043,
                                                              )
                                                            : Colors.white,
                                                    minimumSize:
                                                        const Size(0, 48),
                                                    elevation: verificationSent
                                                        ? 7
                                                        : 2,
                                                    shadowColor:
                                                        verificationSent
                                                            ? _accent
                                                                .withValues(
                                                                alpha: .42,
                                                              )
                                                            : _primary
                                                                .withValues(
                                                                alpha: .28,
                                                              ),
                                                    shape:
                                                        RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              24),
                                                    ),
                                                  ),
                                                  icon: isWorking
                                                      ? const SizedBox.shrink()
                                                      : verificationSent
                                                          ? const Icon(
                                                              Icons
                                                                  .verified_rounded,
                                                              size: 19,
                                                            )
                                                          : const SizedBox
                                                              .shrink(),
                                                  label: isWorking
                                                      ? const SizedBox(
                                                          width: 20,
                                                          height: 20,
                                                          child:
                                                              CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                            color: Colors.white,
                                                          ),
                                                        )
                                                      : Text(
                                                          verificationSent
                                                              ? 'אישור'
                                                              : 'הוספת מייל',
                                                          style:
                                                              const TextStyle(
                                                            fontWeight:
                                                                FontWeight.w800,
                                                          ),
                                                        ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Center(
                                          child: TextButton(
                                            onPressed: isWorking
                                                ? null
                                                : () =>
                                                    Navigator.of(screenContext)
                                                        .pop(false),
                                            child: Text(
                                              verificationSent
                                                  ? 'דילוג'
                                                  : 'לא עכשיו',
                                              style: const TextStyle(
                                                color: _textSecondary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
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
              );
            },
          );
        },
      ),
    );

    return requiresRelogin ?? false;
  }

  Future<void> _continueProfileStage() async {
    final formState = _profileFormKey.currentState;
    if (formState == null || !formState.validate()) return;
    if (_profileStage == 1 && _profileImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש לבחור לפחות תמונת פרופיל אחת.')),
      );
      return;
    }
    if (_profileStage == 2 && _resolvedBirthDate() == null) return;

    setState(() => _isRegistering = true);
    try {
      final user = await _ensureAuthenticatedForRegistration();
      if (user == null) {
        throw FirebaseAuthException(
          code: 'session-expired',
          message: 'יש להתחבר מחדש כדי להמשיך.',
        );
      }

      if (_profileStage == 0) {
        final clean = _handleController.text.trim();
        final isTaken = await _authService.isUsernameTaken(
          '@$clean',
          excludeUid: user.uid,
        );
        if (isTaken) {
          setState(() {
            _isUsernameTaken = true;
            _usernameAvailabilityError = 'היוזר תפוס';
          });
          _profileFormKey.currentState?.validate();
          return;
        }
      }

      final stages = const <String>['username', 'images', 'birth_date', 'bio'];
      final data = <String, dynamic>{
        if (_handleController.text.trim().isNotEmpty) ...{
          'username': '@${_handleController.text.trim()}',
          'usernameLowercase':
              '@${_handleController.text.trim().toLowerCase()}',
        },
        if (_displayNameController.text.trim().isNotEmpty)
          'displayName': _displayNameController.text.trim(),
        if (_resolvedBirthDate() != null)
          'birthDate': _formatDate(_resolvedBirthDate()!),
        'lifeMotto': _lifeMottoController.text.trim(),
        'bio': _bioController.text.trim(),
      };

      final nextStageIndex = (_profileStage + 1).clamp(0, stages.length - 1);
      await _authService.saveOnboardingCheckpoint(
        user.uid,
        stage: stages[nextStageIndex],
        data: data,
      );
      if (!mounted) return;
      setState(() => _profileStage += 1);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_registrationErrorMessage(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  Future<void> _onRegisterPressed() async {
    final formState = _profileFormKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }

    if (_profileImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש לבחור לפחות תמונת פרופיל אחת.')),
      );
      return;
    }

    final handle = _handleController.text.trim();
    final usernameForStorage = '@$handle';
    final birthDateForRegistration = _resolvedBirthDate();

    if (birthDateForRegistration == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('יש לבחור תאריך לידה כדי להשלים את ההרשמה.'),
        ),
      );
      return;
    }

    final accepted = await _showProfileSummary(
      birthDate: birthDateForRegistration,
    );
    if (!mounted || !accepted) return;

    setState(() {
      _isRegistering = true;
    });

    try {
      await _ensureAuthenticatedForRegistration();
      final checkpointUser = FirebaseAuth.instance.currentUser;
      if (checkpointUser != null) {
        await _authService.saveOnboardingCheckpoint(
          checkpointUser.uid,
          stage: 'profile_summary',
          data: {
            'displayName': _displayNameController.text.trim(),
            'username': usernameForStorage,
            'usernameLowercase': usernameForStorage.toLowerCase(),
            'birthDate': _formatDate(birthDateForRegistration),
            'lifeMotto': _lifeMottoController.text.trim(),
            'bio': _bioController.text.trim(),
          },
        );
      }

      Future<bool> checkUsernameTakenWithRecovery() async {
        final currentUid = FirebaseAuth.instance.currentUser?.uid;
        return _authService.isUsernameTaken(
          usernameForStorage,
          excludeUid: currentUid,
        );
      }

      final isTaken = await checkUsernameTakenWithRecovery();
      if (isTaken) {
        setState(() {
          _isUsernameTaken = true;
          _usernameAvailabilityError = 'היוזר תפוס';
        });
        _profileFormKey.currentState?.validate();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('היוזר כבר תפוס, בחר יוזר אחר.')),
        );
        return;
      }

      Future<void> completeRegistrationWithRecovery() async {
        final user = await _ensureAuthenticatedForRegistration();
        if (user == null) {
          throw FirebaseAuthException(
            code: 'session-expired',
            message: 'לא קיים חשבון פעיל לקישור להרשמה.',
          );
        }

        try {
          await _authService.completeVerifiedRegistration(
            password: _passwordController.text.trim(),
            username: usernameForStorage,
            firstName: _firstNameController.text.trim(),
            lastName: _lastNameController.text.trim(),
            displayName: _displayNameController.text.trim(),
            phone: _phoneController.text.trim(),
            birthDate: _formatDate(birthDateForRegistration),
            lifeMotto: _lifeMottoController.text.trim(),
            bio: _bioController.text.trim(),
            profileImages: _profileImages,
            privacyAccepted: true,
          );
        } catch (error) {
          rethrow;
        }
      }

      await completeRegistrationWithRecovery();

      final requiresRelogin = await _offerBackupEmail();
      if (requiresRelogin && mounted) {
        // Rare fallback (no cached password for silent re-auth): the email
        // was still verified successfully, just keep the normal success +
        // explainer sequence below instead of skipping straight to login.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('המייל אומת בהצלחה!'),
          ),
        );
      }

      // Firebase Auth signs in automatically on account creation.
      // Sign out so the user returns to login instead of being routed to feed.
      await _authService.endPendingRegistrationFlow(signOut: true);

      if (!mounted) return;

      if (!isAtLeastMinimumAge(birthDateForRegistration)) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black.withValues(alpha: 0.7),
          builder: (dialogContext) {
            return PopScope(
              canPop: false,
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: const Color(0xFF101827),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.45),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 30,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.redAccent,
                        size: 42,
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'האפליקציה מיועדת לגילאי 13+',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'סיום',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );

        if (!mounted) return;
        if (widget.onExitToLogin != null) {
          widget.onExitToLogin!();
        } else {
          Navigator.of(context).pop();
        }
        return;
      }

      final shouldContinue = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.7),
        builder: (dialogContext) {
          return PopScope(
            canPop: false,
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1B2442), Color(0xFF101827)],
                  ),
                  border: Border.all(
                    color: const Color(0xFF53D9FF).withValues(alpha: 0.26),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 30,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _textSecondary,
                        ),
                        tooltip: 'סגירה',
                      ),
                    ),
                    Container(
                      width: 76,
                      height: 76,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFF7B79FF), Color(0xFF53D9FF)],
                        ),
                      ),
                      child: const Icon(
                        Icons.verified_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'נרשמת בהצלחה!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'נעבור עכשיו להיכרות קצרה עם hundred',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ניתן לדלג בכל זמן ולחזור דרך הגדרות',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF53D9FF),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'המשך',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

      if (!mounted || shouldContinue != true) {
        return;
      }

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const UsageGuideScreen(returnToLoginOnExit: true),
        ),
        (route) => false,
      );
    } catch (e, stackTrace) {
      debugPrint('[RegisterScreen][_onRegisterPressed] error: $e');
      debugPrint(
          '[RegisterScreen][_onRegisterPressed] stackTrace: $stackTrace');
      // Safety net: avoid leaving the app stuck on the neutral splash screen
      // if an unexpected error occurs after the profile was already created.
      AuthService.registrationFlowInProgress.value = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_registrationErrorMessage(e))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  bool _isStageFilled(int stage) {
    switch (stage) {
      case 0:
        return _handleController.text.trim().length >= 3 && !_isUsernameTaken;
      case 1:
        return _profileImages.isNotEmpty;
      case 2:
        return _resolvedBirthDate() != null;
      case 3:
        return _lifeMottoController.text.trim().isNotEmpty ||
            _bioController.text.trim().isNotEmpty;
      default:
        return false;
    }
  }

  void _onStageTap(int targetStage) {
    if (_isRegistering || targetStage == _profileStage) return;
    if (targetStage < _profileStage) {
      setState(() => _profileStage = targetStage);
      return;
    }
    final formState = _profileFormKey.currentState;
    if (formState != null && !formState.validate()) return;
    if (_profileStage == 1 && _profileImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש לבחור לפחות תמונת פרופיל אחת.')),
      );
      return;
    }
    if (_profileStage == 2 && _resolvedBirthDate() == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש לבחור תאריך לידה.')),
      );
      return;
    }
    setState(() => _profileStage = targetStage);
  }

  String get _stageHeading {
    if (_currentStep == 0) return 'הפרטים שלכם';
    switch (_profileStage) {
      case 0:
        return 'בחרו שם משתמש';
      case 1:
        return 'הוסיפו תמונות';
      case 2:
        return 'מתי נולדתם?';
      case 3:
        return 'ספרו על עצמכם';
      default:
        return 'יצירת פרופיל';
    }
  }

  IconData get _stageHeadingIcon {
    if (_currentStep == 0) return Icons.badge_rounded;
    switch (_profileStage) {
      case 0:
        return Icons.alternate_email_rounded;
      case 1:
        return Icons.add_photo_alternate_rounded;
      case 2:
        return Icons.cake_rounded;
      case 3:
        return Icons.auto_awesome_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  List<Color> get _stageHeadingColors {
    if (_currentStep == 0) return const [_accent, _primary];
    switch (_profileStage) {
      case 0:
        return const [Color(0xFF53D9FF), Color(0xFF7B79FF)];
      case 1:
        return const [Color(0xFFFF7AA8), Color(0xFF8B83FF)];
      case 2:
        return const [Color(0xFFFFB65C), Color(0xFFEF6B91)];
      case 3:
        return const [Color(0xFF58E0B5), Color(0xFF53A7FF)];
      default:
        return const [_accent, _primary];
    }
  }

  Widget _buildStageHeading() {
    return Column(
      children: [
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(21),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _stageHeadingColors,
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: .16),
            ),
            boxShadow: [
              BoxShadow(
                color: _stageHeadingColors.last.withValues(alpha: .32),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(
            _stageHeadingIcon,
            color: Colors.white,
            size: 33,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _stageHeading,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _textPrimary,
            fontSize: 27,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildStepHeader() {
    if (_currentStep == 1) {
      const stageTitles = ['יוזר', 'תמונות', 'תאריך לידה', 'אודות'];
      final stageIcons = <IconData>[
        Icons.alternate_email_rounded,
        Icons.photo_library_rounded,
        Icons.calendar_month_rounded,
        Icons.person_rounded,
      ];

      Widget stageDot({
        required int stage,
        required String title,
        required IconData icon,
      }) {
        final isActive = _profileStage == stage;
        final isFilled = _isStageFilled(stage);
        return Expanded(
          child: InkWell(
            onTap: () => _onStageTap(stage),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive
                          ? _accent
                          : (isFilled ? _primary : const Color(0xFF2D386E)),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: _accent.withValues(alpha: 0.32),
                                blurRadius: 12,
                                spreadRadius: 0.8,
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: isFilled
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 18,
                            )
                          : Icon(
                              icon,
                              color: Colors.white,
                              size: 16,
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isActive
                          ? _accent
                          : (isFilled ? _textPrimary : _textSecondary),
                      fontSize: 11,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            for (var i = 0; i < stageTitles.length; i++)
              stageDot(
                stage: i,
                title: stageTitles[i],
                icon: stageIcons[i],
              ),
          ],
        ),
      );
    }

    Widget stepDot({
      required int step,
      required String title,
    }) {
      final isActive = _currentStep == step;
      final isCompleted = _currentStep > step;
      return SizedBox(
        width: 84,
        child: Column(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? _accent
                    : (isCompleted ? _primary : const Color(0xFF2D386E)),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.24),
                          blurRadius: 14,
                          spreadRadius: 0.6,
                        ),
                      ]
                    : null,
              ),
              child: isActive
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CustomPaint(
                        painter: _StepInfinityConnectorPainter(
                          color: Colors.white,
                          strokeWidth: 1.0,
                          symbolScale: 0.7,
                        ),
                      ),
                    )
                  : Icon(
                      isCompleted ? Icons.check_rounded : Icons.circle,
                      color: Colors.white,
                      size: isCompleted ? 22 : 11,
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: isActive ? _accent : _textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        textDirection: TextDirection.ltr,
        children: [
          stepDot(step: 1, title: 'פרופיל'),
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              '-',
              style: TextStyle(
                color: _textSecondary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 4),
          stepDot(step: 0, title: 'פרטים'),
        ],
      ),
    );
  }

  Widget _buildProfileImageTile(int index) {
    final image = _profileImages[index];
    final isDefault = index == 0;

    return GestureDetector(
      onTap: () => _setDefaultProfileImage(index),
      child: Container(
        decoration: BoxDecoration(
          color: _fieldFill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDefault
                ? _accent.withValues(alpha: 0.5)
                : _accent.withValues(alpha: 0.16),
            width: isDefault ? 1.4 : 0.9,
          ),
          boxShadow: isDefault
              ? [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.18),
                    blurRadius: 14,
                    spreadRadius: 0.6,
                  ),
                ]
              : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: kIsWeb
                  ? Image.network(image.path, fit: BoxFit.cover)
                  : Image.file(File(image.path), fit: BoxFit.cover),
            ),
            Positioned(
              top: 6,
              left: 6,
              child: InkWell(
                onTap: () => _removeProfileImage(index),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: Color(0xB3000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 17),
                ),
              ),
            ),
            if (isDefault)
              Align(
                alignment: Alignment.bottomCenter,
                child: InkWell(
                  onTap: _showDefaultImagePickerDialog,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    margin: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xBF53D9FF),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'תמונת ברירת מחדל',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF102043),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsStep() {
    return Form(
      key: _detailsFormKey,
      child: Column(
        children: [
          _buildField(
            controller: _firstNameController,
            label: 'שם',
            validator: _nameValidator,
          ),
          _buildField(
            controller: _lastNameController,
            label: 'שם משפחה',
            validator: _nameValidator,
          ),
          _buildField(
            controller: _phoneController,
            label: 'מספר טלפון',
            keyboardType: TextInputType.phone,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'שדה חובה';
              if (v.trim().length < 9) return 'מספר טלפון לא תקין';
              return null;
            },
          ),
          _buildField(
            controller: _emailController,
            label: 'מייל',
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'שדה חובה';
              if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) {
                return 'כתובת מייל לא תקינה';
              }
              return null;
            },
          ),
          _buildField(
            controller: _passwordController,
            label: 'סיסמה',
            obscureText: _hidePassword,
            validator: _passwordValidator,
            suffixIcon: IconButton(
              onPressed: () => setState(() => _hidePassword = !_hidePassword),
              icon: Icon(
                _hidePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: _textSecondary,
              ),
            ),
          ),
          _buildField(
            controller: _confirmPasswordController,
            label: 'אימות סיסמה',
            obscureText: _hideConfirmPassword,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'שדה חובה';
              if (v.trim() != _passwordController.text.trim()) {
                return 'הסיסמאות אינן תואמות';
              }
              return null;
            },
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => _hideConfirmPassword = !_hideConfirmPassword),
              icon: Icon(
                _hideConfirmPassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: _textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileStep() {
    return Form(
      key: _profileFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_profileStage == 0) ...[
            const SizedBox.shrink(),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextFormField(
                controller: _handleController,
                onTapOutside: (_) {},
                keyboardType: TextInputType.name,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                onChanged: _onHandleChanged,
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'@')),
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                style: const TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                decoration: _inputDecoration('יוזר').copyWith(
                  prefixText: '@',
                  prefixStyle: const TextStyle(
                    color: _textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                  suffixIcon: _isCheckingUsername
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(_accent),
                            ),
                          ),
                        )
                      : null,
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'שדה חובה';
                  final clean = v.trim();
                  if (clean.contains(' ')) {
                    return 'היוזר לא יכול להכיל רווחים';
                  }
                  if (clean.length < 3) {
                    return 'לפחות 3 תווים';
                  }
                  if (_isUsernameTaken) {
                    return 'היוזר תפוס';
                  }
                  return null;
                },
              ),
            ),
            if (_usernameAvailabilityError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10, right: 4),
                child: Text(
                  _usernameAvailabilityError!,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
          if (_profileStage == 1) ...[
            const SizedBox(height: 6),
            const Text(
              'אפשר לבחור עד 6 תמונות פרופיל!',
              textAlign: TextAlign.right,
              style: TextStyle(color: _textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            GridView.builder(
              itemCount: _profileImages.length +
                  (_profileImages.length < _maxProfileImages ? 1 : 0),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 9,
                crossAxisSpacing: 9,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, index) {
                if (index < _profileImages.length) {
                  return _buildProfileImageTile(index);
                }

                final isDisabled = _isPickingProfileImages;

                return InkWell(
                  onTap: isDisabled ? null : _pickProfileImages,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF121A2A),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDisabled
                            ? _accent.withValues(alpha: 0.12)
                            : _primary.withValues(alpha: 0.44),
                        width: 0.9,
                      ),
                    ),
                    child: Center(
                      child: _isPickingProfileImages
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(_primary),
                              ),
                            )
                          : const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_photo_alternate_rounded,
                                    color: _accent, size: 26),
                                SizedBox(height: 4),
                                Text(
                                  'הוספה',
                                  style: TextStyle(
                                    color: _textSecondary,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              'נבחרו ${_profileImages.length}/$_maxProfileImages תמונות.',
              textAlign: TextAlign.right,
              style: const TextStyle(color: _textSecondary, fontSize: 12),
            ),
          ],
          if (_profileStage == 3) ...[
            const SizedBox(height: 14),
            _buildField(
              controller: _lifeMottoController,
              label: 'תתארו אתכם במשפט (אופציונאלי)',
              onChanged: (_) => setState(() {}),
              validator: (v) {
                if (v != null && v.trim().length > 90) {
                  return 'עד 90 תווים';
                }
                return null;
              },
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12, right: 4),
              child: Text(
                'דוגמאות: ״אקסטרים זה החיים / ספונטניות זה שם המשחק״',
                textAlign: TextAlign.right,
                style: TextStyle(color: _textSecondary, fontSize: 12),
              ),
            ),
            _buildField(
              controller: _bioController,
              label: 'מה עוד בא לך שידעו עליך? (אופציונאלי)',
              maxLines: 4,
              minLines: 3,
              onChanged: (_) => setState(() {}),
              validator: (v) {
                if (v != null && v.trim().length > 350) {
                  return 'עד 350 תווים';
                }
                return null;
              },
            ),
          ],
          if (_profileStage == 2) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                controller: _birthDateController,
                onTapOutside: (_) {},
                keyboardType: TextInputType.datetime,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: _textPrimary, fontWeight: FontWeight.w600),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                  LengthLimitingTextInputFormatter(10),
                ],
                onChanged: (value) {
                  final formatted = _autoFormatBirthDateInput(value);
                  if (formatted == value) return;
                  _birthDateController.value = TextEditingValue(
                    text: formatted,
                    selection:
                        TextSelection.collapsed(offset: formatted.length),
                  );
                },
                decoration:
                    _inputDecoration('תאריך לידה (DD/MM/YYYY)').copyWith(
                  suffixIcon: IconButton(
                    onPressed: _pickBirthDate,
                    icon: const Icon(Icons.calendar_month_rounded,
                        color: _primary),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'שדה חובה';
                  final birthDate = _parseDdMmYyyy(v);
                  if (birthDate == null) {
                    return 'פורמט לא תקין, יש להזין DD/MM/YYYY';
                  }
                  return null;
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12, right: 4),
              child: Text(
                'תאריך הלידה נדרש לצורך עמידה בתנאי הקהילה',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _exitToLogin() async {
    await _authService.endPendingRegistrationFlow(signOut: true);
    if (!mounted) return;
    if (widget.onExitToLogin != null) {
      widget.onExitToLogin!();
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Widget _buildRegistrationActionButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isRegistering
            ? null
            : (_currentStep == 0
                ? _continueFromDetailsStep
                : (_profileStage < 3
                    ? _continueProfileStage
                    : _onRegisterPressed)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 0,
        ),
        child: _isRegistering
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                _currentStep == 0
                    ? 'המשך'
                    : (_profileStage < 3 ? 'המשך' : 'צור חשבון'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
      ),
    );
  }

  Widget _buildProfileBackSlot() {
    if (_profileStage == 0) return const SizedBox(height: 4);
    return TextButton(
      onPressed:
          _isRegistering ? null : () => setState(() => _profileStage -= 1),
      child: const Text(
        'חזרה לשלב הקודם',
        style: TextStyle(color: _textSecondary),
      ),
    );
  }

  Widget _buildProfileCardBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildStepHeader(),
        TweenAnimationBuilder<double>(
          key: ValueKey<String>('profile-stage-$_profileStage'),
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStageHeading(),
              const SizedBox(height: 14),
              if (_isRestoringDraft)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(_accent),
                    ),
                  ),
                )
              else
                _buildProfileStep(),
            ],
          ),
          builder: (context, progress, child) {
            return Opacity(
              opacity: progress,
              child: Transform.translate(
                offset: Offset(0, 10 * (1 - progress)),
                child: child,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        _buildRegistrationActionButton(),
        _buildProfileBackSlot(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.8).clamp(230.0, 310.0);
    final orbSizeB = (screenWidth * 0.92).clamp(260.0, 360.0);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentStep == 1 && _profileStage > 0) {
          setState(() {
            _profileStage -= 1;
          });
        } else {
          _exitToLogin();
        }
      },
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: _bgBottom,
          resizeToAvoidBottomInset: false,
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
                          begin: _animateBg
                              ? Alignment.topLeft
                              : Alignment.topRight,
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
                    left: _animateBg ? -95 : -55,
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
                    bottom: _animateBg ? -155 : -115,
                    right: _animateBg ? -110 : -65,
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
                      final keyboardInset =
                          MediaQuery.viewInsetsOf(context).bottom;
                      final visibleHeight =
                          (constraints.maxHeight - keyboardInset)
                              .clamp(0.0, constraints.maxHeight)
                              .toDouble();

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
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.topCenter,
                                clipBehavior: Clip.none,
                                child: Container(
                                  width: double.infinity,
                                  padding:
                                      const EdgeInsets.fromLTRB(18, 22, 18, 20),
                                  decoration: BoxDecoration(
                                    color: const Color(0xD0121A2B),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                        color: _accent.withValues(alpha: 0.12),
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
                                  child: _currentStep == 1
                                      ? _buildProfileCardBody()
                                      : Column(
                                          children: [
                                            _buildStageHeading(),
                                            const SizedBox(height: 10),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                const Text(
                                                  'אם כבר יש לך משתמש - ',
                                                  style: TextStyle(
                                                      color: _textSecondary,
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w400),
                                                ),
                                                InkWell(
                                                  onTap: _exitToLogin,
                                                  child: const Text(
                                                    'התחבר',
                                                    style: TextStyle(
                                                      color: _accent,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 14),
                                            _buildStepHeader(),
                                            if (_isRestoringDraft)
                                              const Padding(
                                                padding: EdgeInsets.symmetric(
                                                    vertical: 40),
                                                child: Center(
                                                  child: SizedBox(
                                                    width: 28,
                                                    height: 28,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2.2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(_accent),
                                                    ),
                                                  ),
                                                ),
                                              )
                                            else ...[
                                              _buildDetailsStep(),
                                              const SizedBox(height: 8),
                                              _buildRegistrationActionButton(),
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
                  Positioned(
                    top: 2,
                    right: 6,
                    child: Material(
                      color: Colors.transparent,
                      child: IconButton(
                        onPressed: _isRegistering
                            ? null
                            : () {
                                if (_currentStep == 1 && _profileStage > 0) {
                                  setState(() {
                                    _profileStage -= 1;
                                  });
                                } else {
                                  _exitToLogin();
                                }
                              },
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: _textPrimary,
                        ),
                        tooltip: 'חזרה',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepInfinityConnectorPainter extends CustomPainter {
  const _StepInfinityConnectorPainter({
    required this.color,
    this.strokeWidth = 1.9,
    this.symbolScale = 1.0,
  });

  final Color color;
  final double strokeWidth;
  final double symbolScale;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = symbolScale.clamp(0.2, 1.0);
    final cx = size.width / 2;
    final cy = size.height / 2;

    final path = Path();
    final a = size.width * 0.42 * scale;
    final yScale = a;
    const pointCount = 220;

    for (var i = 0; i <= pointCount; i++) {
      final t = (i / pointCount) * pi * 2;
      final sinT = sin(t);
      final cosT = cos(t);
      final d = 1 + sinT * sinT;

      final x = cx + a * cosT / d;
      final y = cy + yScale * sinT * cosT / d;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    final centerLineHalf = size.height * 0.3 * scale;
    path
      ..moveTo(cx, cy - centerLineHalf)
      ..lineTo(cx, cy + centerLineHalf);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = strokeWidth
      ..color = color;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StepInfinityConnectorPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.symbolScale != symbolScale;
  }
}
