import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'age_restrictions.dart';
import 'privacy_policy_dialog.dart';
import 'services/auth_service.dart';
import 'usage_guide_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

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
  bool _hasAcceptedPrivacyPolicy = false;
  String? _usernameAvailabilityError;

  Timer? _usernameDebounce;

  int _currentStep = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    super.dispose();
  }

  String _registrationErrorMessage(Object error) {
    if (error is! FirebaseAuthException) {
      return 'לא הצלחנו להשלים את תהליך ההרשמה כרגע. נסה שוב.';
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

            return AlertDialog(
              backgroundColor: const Color(0xFF1E2752),
              title: Row(
                children: [
                  IconButton(
                    onPressed: isBusy
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    icon:
                        const Icon(Icons.close_rounded, color: _textSecondary),
                    tooltip: 'סגירה',
                  ),
                  const Expanded(
                    child: Text(
                      'אימות כתובת מייל',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'שלחנו קישור אימות לכתובת:',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: _textSecondary, height: 1.45),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.email,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'אשר/י את המייל וחזור/י לכאן. לא הגיע? בדוק/י ספאם או שלח/י שוב.',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: _accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorMessage!,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      isBusy || DateTime.now().isBefore(resendAvailableAt)
                          ? null
                          : resendEmail,
                  child: Text(
                    resendCountdownLabel(),
                    style: const TextStyle(color: _accent),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(86, 34),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: isBusy ? null : confirmVerification,
                  child: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text('כבר אימתתי'),
                ),
              ],
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
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        minLines: minLines,
        maxLines: maxLines,
        inputFormatters: inputFormatters,
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
      lastDate: latestEligibleBirthDate(now),
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
    if (text.isEmpty) return 'שדה חובה';
    if (text.length < 7) return 'לפחות 7 תווים';
    if (!RegExp(r'[A-Z]').hasMatch(text)) return 'חובה אות גדולה באנגלית';
    if (!RegExp(r'[a-z]').hasMatch(text)) return 'חובה אות קטנה באנגלית';
    if (!RegExp(r'[0-9]').hasMatch(text)) return 'חובה לפחות מספר אחד';
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(text)) {
      return 'חובה סימן מיוחד אחד לפחות';
    }
    return null;
  }

  DateTime? _parseDdMmYyyy(String value) {
    return parseStoredBirthDate(value);
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
        final isTaken = await _authService.isUsernameTaken('@$clean');
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

    final parsedBirthDate = _parseDdMmYyyy(_birthDateController.text);
    if (parsedBirthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להזין תאריך בפורמט DD/MM/YYYY.')),
      );
      return;
    }

    _birthDate = parsedBirthDate;

    setState(() {
      _isRegistering = true;
    });

    try {
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
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (!mounted) return;

      final isVerified = verificationState.isVerified
          ? true
          : await _showEmailVerificationDialog(state: verificationState);

      if (!mounted) return;
      if (!isVerified) {
        await _authService.endPendingRegistrationFlow(signOut: true);
        return;
      }

      setState(() {
        _currentStep = 1;
      });
    } catch (e, stackTrace) {
      print('[RegisterScreen][_continueFromDetailsStep] error: $e');
      print(
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

  Future<void> _onRegisterPressed() async {
    final formState = _profileFormKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }

    if (!_hasAcceptedPrivacyPolicy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('יש לאשר את מדיניות הפרטיות ותנאי השימוש כדי להשלים הרשמה.'),
        ),
      );
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

    setState(() {
      _isRegistering = true;
    });

    try {
      final isTaken = await _authService.isUsernameTaken(usernameForStorage);
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

      await _authService.completeVerifiedRegistration(
        password: _passwordController.text.trim(),
        username: usernameForStorage,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        displayName: _displayNameController.text.trim(),
        phone: _phoneController.text.trim(),
        birthDate: _formatDate(_birthDate!),
        lifeMotto: _lifeMottoController.text.trim(),
        bio: _bioController.text.trim(),
        profileImages: _profileImages,
      );

      // Firebase Auth signs in automatically on account creation.
      // Sign out so the user returns to login instead of being routed to feed.
      await _authService.endPendingRegistrationFlow(signOut: true);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ההרשמה הושלמה בהצלחה. נעבור לחוברת היכרות קצרה.'),
          backgroundColor: _primary,
        ),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const UsageGuideScreen(returnToLoginOnExit: true),
        ),
        (route) => false,
      );
    } catch (e, stackTrace) {
      print('[RegisterScreen][_onRegisterPressed] error: $e');
      print('[RegisterScreen][_onRegisterPressed] stackTrace: $stackTrace');
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

  Widget _buildPrivacyPolicyAcceptance() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          textDirection: TextDirection.rtl,
          children: [
            Checkbox(
              value: _hasAcceptedPrivacyPolicy,
              fillColor: const WidgetStatePropertyAll(_primary),
              checkColor: Colors.white,
              onChanged: (value) {
                setState(() {
                  _hasAcceptedPrivacyPolicy = value ?? false;
                });
              },
            ),
            const SizedBox(width: 2),
            Flexible(
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  textDirection: TextDirection.rtl,
                  children: [
                    const Text(
                      'קראתי את ',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => showPrivacyPolicyDialog(context),
                      child: const Text(
                        'מדיניות הפרטיות',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: _accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: _accent,
                        ),
                      ),
                    ),
                    const Text(
                      ' ואת ',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => showTermsOfUseDialog(context),
                      child: const Text(
                        'תנאי השימוש',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: _accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: _accent,
                        ),
                      ),
                    ),
                    const Text(
                      ' ואני מאשר/ת אותם',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepHeader() {
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
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextFormField(
              controller: _birthDateController,
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
                  selection: TextSelection.collapsed(offset: formatted.length),
                );
              },
              decoration: _inputDecoration('תאריך לידה (DD/MM/YYYY)').copyWith(
                suffixIcon: IconButton(
                  onPressed: _pickBirthDate,
                  icon:
                      const Icon(Icons.calendar_month_rounded, color: _primary),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'שדה חובה';
                final birthDate = _parseDdMmYyyy(v);
                if (birthDate == null) {
                  return 'פורמט לא תקין, יש להזין DD/MM/YYYY';
                }
                if (!isAtLeastMinimumAge(birthDate)) {
                  return 'ההרשמה מיועדת לגילאי $minimumUserAge ומעלה';
                }
                return null;
              },
            ),
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
          _buildField(
            controller: _displayNameController,
            label: 'שם משתמש',
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'שדה חובה' : null,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextFormField(
              controller: _handleController,
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
                            valueColor: AlwaysStoppedAnimation<Color>(_accent),
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
          const SizedBox(height: 6),
          const Text(
            'אלו התמונות שיופיעו בפרופיל שלך.',
            textAlign: TextAlign.right,
            style: TextStyle(color: _textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            itemCount: _profileImages.length + 1,
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

              final isDisabled = _profileImages.length >= _maxProfileImages ||
                  _isPickingProfileImages;

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
          const SizedBox(height: 14),
          _buildField(
            controller: _lifeMottoController,
            label: 'משפט מפתח לחיים (אופציונלי)',
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
              'דוגמאות "פסטה רוזה זה החיים / מי בא צניחה חופשית"',
              textAlign: TextAlign.right,
              style: TextStyle(color: _textSecondary, fontSize: 12),
            ),
          ),
          _buildField(
            controller: _bioController,
            label: 'כמה מילים שיעזרו לאנשים ללמוד עליך',
            maxLines: 4,
            minLines: 3,
            validator: (v) {
              if (v != null && v.trim().length > 350) {
                return 'עד 350 תווים';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.8).clamp(230.0, 310.0);
    final orbSizeB = (screenWidth * 0.92).clamp(260.0, 360.0);
    return SwipeBackWrapper(
      child: Scaffold(
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
              ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
                    decoration: BoxDecoration(
                      color: const Color(0xD0121A2B),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                          color: _accent.withValues(alpha: 0.12), width: 0.8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.24),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'הרשמה',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_currentStep == 0)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'אם כבר יש לך משתמש - ',
                                style: TextStyle(
                                    color: _textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400),
                              ),
                              InkWell(
                                onTap: () => Navigator.of(context).pop(),
                                child: const Text(
                                  'התחבר',
                                  style: TextStyle(
                                    color: _accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 14),
                        _buildStepHeader(),
                        if (_currentStep == 0)
                          _buildDetailsStep()
                        else
                          _buildProfileStep(),
                        if (_currentStep == 1) _buildPrivacyPolicyAcceptance(),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isRegistering
                                ? null
                                : (_currentStep == 0
                                    ? _continueFromDetailsStep
                                    : _onRegisterPressed),
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
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white),
                                    ),
                                  )
                                : Text(
                                    _currentStep == 0 ? 'המשך' : 'סיום הרשמה',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                          ),
                        ),
                        if (_currentStep == 1)
                          TextButton(
                            onPressed: _isRegistering
                                ? null
                                : () {
                                    setState(() {
                                      _currentStep = 0;
                                    });
                                  },
                            child: const Text(
                              'חזרה לשלב הקודם',
                              style: TextStyle(color: _textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 2,
                right: 6,
                child: Material(
                  color: Colors.transparent,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
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
