import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'age_restrictions.dart';
import 'services/auth_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class PersonalDetailsScreen extends StatefulWidget {
  const PersonalDetailsScreen({super.key});

  @override
  State<PersonalDetailsScreen> createState() => _PersonalDetailsScreenState();
}

class _PersonalDetailsScreenState extends State<PersonalDetailsScreen> {
  static const Color _bgTop = Color(0xFF0B1222);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _cardTop = Color(0xFF121C2A);
  static const Color _cardBottom = Color(0xFF171B2B);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFF9E7CFF);

  final AuthService _authService = AuthService();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _birthDateController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = true;
  bool _isSaving = false;
  String _currentEmail = '';
  String _currentPhone = '';
  DateTime? _birthDate;

  @override
  void initState() {
    super.initState();
    _loadCurrentDetails();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    _birthDateController.dispose();
    super.dispose();
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
    final email = (data['email'] as String? ?? user.email ?? '').trim();
    final birthDateRaw = (data['birthDate'] as String? ?? '').trim();
    DateTime? birthDate;
    if (birthDateRaw.isNotEmpty) {
      birthDate = parseStoredBirthDate(birthDateRaw);
    }

    if (!mounted) return;
    setState(() {
      _currentPhone = phone;
      _currentEmail = email;
      _birthDate = birthDate;
      _phoneController.text = phone;
      _emailController.text = email;
      _birthDateController.text =
          birthDate == null ? '' : _formatDate(birthDate);
      _isLoading = false;
    });
  }

  String _formatDate(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = value.year.toString();
    return '$day/$month/$year';
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
          color:
              isLight ? const Color(0xFFA9C3FF) : _accentCyan.withValues(alpha:  0.14),
          width: 0.9,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(
          color:
              isLight ? const Color(0xFFA9C3FF) : _accentCyan.withValues(alpha:  0.14),
          width: 0.9,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        borderSide: BorderSide(
          color: isLight
              ? const Color(0xFFB79BFF)
              : _accentPurple.withValues(alpha:  0.7),
          width: 1.0,
        ),
      ),
    );
  }

  Future<void> _pickBirthDate() async {
    final latestBirthDate = latestEligibleBirthDate();
    final storedBirthDate = _birthDate;
    final initialDate =
        storedBirthDate != null && isAtLeastMinimumAge(storedBirthDate)
            ? storedBirthDate
            : latestBirthDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(1900),
      lastDate: latestBirthDate,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: _accentPurple,
              primary: _accentPurple,
              secondary: _accentCyan,
              surface: const Color(0xFF101826),
            ),
            dialogTheme:
                const DialogThemeData(backgroundColor: Color(0xFF101826)),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (picked == null) return;
    setState(() {
      _birthDate = picked;
      _birthDateController.text = _formatDate(picked);
    });
  }

  Future<String?> _promptForSmsCode() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: const Color(0xFF101826),
            title: const Text(
              'הזן קוד SMS',
              style: TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'קוד חד פעמי',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1A2435),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentPurple,
                  foregroundColor: Colors.black,
                ),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('אישור'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    return code;
  }

  Future<void> _verifyAndSavePhone(String newPhone) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in.',
      );
    }

    final completer = Completer<void>();
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: newPhone,
      verificationCompleted: (credential) async {
        try {
          await user.updatePhoneNumber(credential);
          if (!completer.isCompleted) {
            completer.complete();
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      verificationFailed: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      codeSent: (verificationId, resendToken) async {
        final code = await _promptForSmsCode();
        if (code == null || code.isEmpty) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('SMS verification cancelled'));
          }
          return;
        }

        try {
          final credential = PhoneAuthProvider.credential(
            verificationId: verificationId,
            smsCode: code,
          );
          await user.updatePhoneNumber(credential);
          if (!completer.isCompleted) {
            completer.complete();
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      codeAutoRetrievalTimeout: (_) {},
      timeout: const Duration(seconds: 60),
    );

    await completer.future;
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
    final birthDateValue = _birthDate;
    final birthDateText = birthDateValue == null
        ? ''
        : '${birthDateValue.year.toString().padLeft(4, '0')}-${birthDateValue.month.toString().padLeft(2, '0')}-${birthDateValue.day.toString().padLeft(2, '0')}';

    setState(() {
      _isSaving = true;
    });

    try {
      if (phoneValue.isNotEmpty && phoneValue != _currentPhone) {
        await _verifyAndSavePhone(phoneValue);
      }

      if (emailValue.isNotEmpty && emailValue != _currentEmail) {
        await user!.verifyBeforeUpdateEmail(emailValue);
      }

      await _authService.updateContactDetails(
        uid: uid,
        phone: phoneValue,
        email: emailValue,
        birthDate: birthDateText,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            emailValue != _currentEmail
                ? 'הפרטים נשמרו. שלחנו אימות למייל החדש.'
                : 'הפרטים נשמרו בהצלחה.',
          ),
        ),
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
                        .withValues(alpha:  isLight ? 0.15 : 0.08),
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
                        .withValues(alpha:  isLight ? 0.16 : 0.09),
                  ),
                ),
              ),
              SafeArea(
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
                                decoration: BoxDecoration(
                                  color: isLight ? Colors.white : null,
                                  gradient: isLight
                                      ? null
                                      : LinearGradient(
                                          colors: [
                                            _cardTop.withValues(alpha:  0.95),
                                            _cardBottom.withValues(alpha:  0.95),
                                          ],
                                          begin: Alignment.topRight,
                                          end: Alignment.bottomLeft,
                                        ),
                                  border: Border.all(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : _accentCyan.withValues(alpha:  0.12),
                                      width: 0.8),
                                ),
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'טלפון, מייל ותאריך לידה',
                                        style: TextStyle(
                                          color: titleColor,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'שינוי טלפון יתבצע לאחר אימות SMS. שינוי מייל ישלח לאימות לפני השמירה.',
                                        style: TextStyle(
                                            color: mutedColor,
                                            fontWeight: FontWeight.w400),
                                      ),
                                      const SizedBox(height: 18),
                                      TextFormField(
                                        controller: _phoneController,
                                        keyboardType: TextInputType.phone,
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
                                      const SizedBox(height: 14),
                                      TextFormField(
                                        controller: _emailController,
                                        keyboardType:
                                            TextInputType.emailAddress,
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
                                      const SizedBox(height: 14),
                                      TextFormField(
                                        controller: _birthDateController,
                                        readOnly: true,
                                        onTap: _pickBirthDate,
                                        style: TextStyle(color: bodyColor),
                                        decoration: _fieldDecoration(
                                          isLight: isLight,
                                          label: 'תאריך לידה',
                                        ),
                                        validator: (value) {
                                          final birthDate =
                                              parseStoredBirthDate(value ?? '');
                                          if (birthDate == null) {
                                            return 'יש לבחור תאריך לידה';
                                          }
                                          if (!isAtLeastMinimumAge(birthDate)) {
                                            return 'הגיל המינימלי הוא $minimumUserAge';
                                          }
                                          return null;
                                        },
                                      ),
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
            ],
          ),
        ),
      ),
    );
  }
}
