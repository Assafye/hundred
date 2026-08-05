import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hundred_version1/services/auth_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class EditProfileScreen extends StatefulWidget {
  final String currentName;
  final String currentHandle;
  final String currentBio;
  final bool currentAllowGroupInvite;
  final String? currentImageUrl;
  final List<String> currentImageUrls;

  const EditProfileScreen({
    super.key,
    required this.currentName,
    required this.currentHandle,
    required this.currentBio,
    required this.currentAllowGroupInvite,
    this.currentImageUrl,
    this.currentImageUrls = const <String>[],
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const Color _bgTop = Colors.white;
  static const Color _bgBottom = Colors.white;
  static const Color _darkBgTop = Color(0xFF10162A);
  static const Color _darkBgBottom = Color(0xFF0B1019);
  static const Color _cardTop = Color(0xFF172437);
  static const Color _cardBottom = Color(0xFF231C3F);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFF9E7CFF);
  static const int _maxProfileImages = 6;

  late TextEditingController _nameController;
  late TextEditingController _handleController;
  late TextEditingController _bioController;
  late bool _allowGroupInvite;
  final List<String> _existingProfileImageUrls = <String>[];
  final List<XFile> _newProfileImageFiles = <XFile>[];
  final List<Uint8List> _newProfileImageBytes = <Uint8List>[];
  int _primaryCombinedImageIndex = 0;
  bool _isSaving = false;
  final ImagePicker _picker = ImagePicker();
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _handleController = TextEditingController(
      text: widget.currentHandle.startsWith('@')
          ? widget.currentHandle.substring(1)
          : widget.currentHandle,
    );
    _bioController = TextEditingController(text: widget.currentBio);
    _allowGroupInvite = widget.currentAllowGroupInvite;

    final initialUrls = <String>[
      ...widget.currentImageUrls,
      if ((widget.currentImageUrl ?? '').trim().isNotEmpty)
        widget.currentImageUrl!.trim(),
    ];
    _existingProfileImageUrls.addAll(_normalizeProfileImageUrls(initialUrls));
    _loadInitialProfileImages();
  }

  List<String> _normalizeProfileImageUrls(Iterable<String> rawUrls) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final raw in rawUrls) {
      final url = raw.trim();
      if (url.isEmpty) continue;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) {
        continue;
      }
      if (!seen.add(url)) continue;
      normalized.add(url);
      if (normalized.length >= _maxProfileImages) break;
    }
    return normalized;
  }

  Future<void> _loadInitialProfileImages() async {
    if (_existingProfileImageUrls.isNotEmpty) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      if (data == null) return;

      final profilePictureUrl =
          (data['profilePictureUrl'] as String? ?? '').trim();
      final profileImageUrls =
          ((data['profileImageUrls'] as List?) ?? const <dynamic>[])
              .whereType<String>()
              .toList(growable: false);
      final normalized = _normalizeProfileImageUrls(
        <String>[
          if (profilePictureUrl.isNotEmpty) profilePictureUrl,
          ...profileImageUrls,
        ],
      );
      if (normalized.isEmpty || !mounted) return;

      setState(() {
        _existingProfileImageUrls
          ..clear()
          ..addAll(normalized);
        _primaryCombinedImageIndex = 0;
      });
    } catch (_) {
      // Keep silent: if remote image cannot be loaded, placeholder will be shown.
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  int get _totalProfileImages =>
      _existingProfileImageUrls.length + _newProfileImageFiles.length;

  Future<void> _pickProfileImages() async {
    final remaining = _maxProfileImages - _totalProfileImages;
    if (remaining <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ניתן להעלות עד 6 תמונות פרופיל.')),
      );
      return;
    }

    final picked = await _picker.pickMultiImage(
      imageQuality: 85,
      maxWidth: 1080,
    );
    if (picked.isEmpty) return;

    final selected = picked.take(remaining).toList(growable: false);
    final bytesList = <Uint8List>[];
    for (final file in selected) {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) continue;
      bytesList.add(bytes);
    }

    if (bytesList.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _newProfileImageFiles.addAll(selected.take(bytesList.length));
      _newProfileImageBytes.addAll(bytesList);
      if (_totalProfileImages == bytesList.length) {
        _primaryCombinedImageIndex = 0;
      } else if (_primaryCombinedImageIndex >= _totalProfileImages) {
        _primaryCombinedImageIndex = _totalProfileImages - 1;
      }
    });

    if (picked.length > remaining && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('נוספו $remaining תמונות בלבד (מקסימום 6).')),
      );
    }
  }

  void _setPrimaryProfileImage(int combinedIndex) {
    if (combinedIndex < 0 || combinedIndex >= _totalProfileImages) return;
    setState(() {
      _primaryCombinedImageIndex = combinedIndex;
    });
  }

  void _removeProfileImageAt(int combinedIndex) {
    if (combinedIndex < 0 || combinedIndex >= _totalProfileImages) return;

    setState(() {
      if (combinedIndex < _existingProfileImageUrls.length) {
        _existingProfileImageUrls.removeAt(combinedIndex);
      } else {
        final localIndex = combinedIndex - _existingProfileImageUrls.length;
        _newProfileImageFiles.removeAt(localIndex);
        _newProfileImageBytes.removeAt(localIndex);
      }

      final totalAfter = _totalProfileImages;
      if (totalAfter <= 0) {
        _primaryCombinedImageIndex = 0;
        return;
      }

      if (_primaryCombinedImageIndex == combinedIndex) {
        _primaryCombinedImageIndex = 0;
      } else if (_primaryCombinedImageIndex > combinedIndex) {
        _primaryCombinedImageIndex -= 1;
      }

      if (_primaryCombinedImageIndex >= totalAfter) {
        _primaryCombinedImageIndex = totalAfter - 1;
      }
    });
  }

  Future<void> _saveProfile() async {
    if (_isSaving) return;

    final nameValue = _nameController.text.trim();
    final handleValue = _handleController.text.trim();
    final bioValue = _bioController.text.trim();

    if (nameValue.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להזין שם משתמש.')),
      );
      return;
    }
    if (handleValue.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להזין שם יוזר.')),
      );
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final usernameForStorage = '@$handleValue';

    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להתחבר מחדש כדי לשמור שינויים.')),
      );
      return;
    }

    final usernameAlreadyTaken = await _authService.isUsernameTaken(
      usernameForStorage,
      excludeUid: uid,
    );
    if (usernameAlreadyTaken) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('שם המשתמש כבר תפוס, בחר שם אחר.')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _authService.updateUserProfile(
        uid: uid,
        displayName: nameValue,
        username: usernameForStorage,
        bio: bioValue,
        allowGroupInvite: _allowGroupInvite,
        existingProfileImageUrls: _existingProfileImageUrls,
        newProfileImageFiles: _newProfileImageFiles,
        primaryImageIndexInCombined:
            _totalProfileImages > 0 ? _primaryCombinedImageIndex : null,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הפרופיל נשמר בהצלחה.')),
      );
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final message = e.code == 'username-already-in-use'
          ? 'שם המשתמש כבר תפוס, בחר שם אחר.'
          : 'לא ניתן לשמור את הפרופיל כרגע.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שגיאה בשמירת הפרופיל: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Widget _buildProfileImagesSection({required bool isLight}) {
    final totalImages = _totalProfileImages;
    final itemCount =
        totalImages < _maxProfileImages ? totalImages + 1 : totalImages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.builder(
          itemCount: itemCount,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 9,
            crossAxisSpacing: 9,
            childAspectRatio: 1,
          ),
          itemBuilder: (context, index) {
            if (index == totalImages && totalImages < _maxProfileImages) {
              return InkWell(
                onTap: _pickProfileImages,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  decoration: BoxDecoration(
                    color: isLight
                        ? Colors.white.withOpacity( 0.62)
                        : const Color(0xFF121A2A),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isLight
                          ? const Color(0xFFA7BFFF)
                          : _accentPurple.withOpacity( 0.42),
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_rounded, size: 26),
                      SizedBox(height: 5),
                      Text(
                        'הוספה',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              );
            }

            final isPrimary = index == _primaryCombinedImageIndex;
            final hasExisting = index < _existingProfileImageUrls.length;
            final media = hasExisting
                ? _existingProfileImageUrls[index]
                : _newProfileImageBytes[
                    index - _existingProfileImageUrls.length];

            return GestureDetector(
              onTap: () => _setPrimaryProfileImage(index),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isPrimary
                              ? _accentPurple
                              : (isLight
                                  ? const Color(0xFFA9C3FF)
                                  : _accentCyan.withOpacity( 0.2)),
                          width: isPrimary ? 2.2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: hasExisting
                            ? Image.network(
                                media as String,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: isLight
                                      ? const Color(0xFFF1F4FA)
                                      : const Color(0xFF1E2632),
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.white70,
                                  ),
                                ),
                              )
                            : Image.memory(
                                media as Uint8List,
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                  ),
                  if (isPrimary)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xBF9E7CFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'ראשית',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: InkWell(
                      onTap: () => _removeProfileImageAt(index),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity( 0.58),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          'תמונות פרופיל: $totalImages/$_maxProfileImages. לחץ על תמונה כדי לבחור תמונה ראשית.',
          textAlign: TextAlign.right,
          style: TextStyle(
            color: isLight ? Colors.black87 : const Color(0xFFAFC1DF),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration({
    required bool isLight,
    required String label,
    String? prefixText,
  }) {
    return InputDecoration(
      floatingLabelBehavior: FloatingLabelBehavior.never,
      label: Align(
        alignment: Alignment.centerRight,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: TextStyle(
            color: isLight ? Colors.black87 : const Color(0xFFAFC1DF),
          ),
        ),
      ),
      prefixText: prefixText,
      prefixStyle: TextStyle(
        color: isLight ? Colors.black : const Color(0xFFEAF4FF),
        fontWeight: FontWeight.w700,
      ),
      filled: true,
      fillColor:
          isLight ? Colors.white.withOpacity( 0.58) : const Color(0xFF142136),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color:
              isLight ? const Color(0xFFA9C3FF) : _accentCyan.withOpacity( 0.22),
          width: 1,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color:
              isLight ? const Color(0xFFA9C3FF) : _accentCyan.withOpacity( 0.22),
          width: 1,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: isLight ? const Color(0xFFB79BFF) : _accentPurple,
          width: 1.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.62).clamp(180.0, 220.0);
    final orbSizeB = (screenWidth * 0.72).clamp(200.0, 260.0);
    final titleColor = isLight ? Colors.black : Colors.white;
    final bodyTextColor = isLight ? Colors.black : Colors.white;
    final minCardHeight =
        (MediaQuery.of(context).size.height - kToolbarHeight - 210)
            .clamp(420.0, 920.0);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
        backgroundColor: isLight ? _bgBottom : _darkBgBottom,
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: titleColor),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'עריכת פרופיל',
            style: TextStyle(color: titleColor, fontWeight: FontWeight.w800),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isLight
                        ? const [_bgTop, _bgBottom]
                        : const [_darkBgTop, Color(0xFF131B33), _darkBgBottom],
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
                      .withOpacity( isLight ? 0.14 : 0.08),
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
                      .withOpacity( isLight ? 0.14 : 0.09),
                ),
              ),
            ),
            SafeArea(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.fromLTRB(20, kToolbarHeight + 18, 20, 96),
                child: Container(
                  constraints: BoxConstraints(minHeight: minCardHeight),
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: isLight ? Colors.white.withOpacity( 0.6) : null,
                    gradient: isLight
                        ? null
                        : LinearGradient(
                            colors: [
                              _cardTop.withOpacity( 0.94),
                              _cardBottom.withOpacity( 0.94),
                            ],
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                          ),
                    border: Border.all(
                      color: isLight
                          ? const Color(0xFFA9C3FF)
                          : _accentCyan.withOpacity( 0.24),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isLight
                            ? const Color(0xFF53C1F9).withOpacity( 0.1)
                            : Colors.black.withOpacity( 0.22),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildProfileImagesSection(isLight: isLight),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _nameController,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: bodyTextColor, fontWeight: FontWeight.w600),
                        maxLength: 20,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(20),
                        ],
                        decoration: _fieldDecoration(
                            isLight: isLight, label: 'שם משתמש'),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _handleController,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: bodyTextColor, fontWeight: FontWeight.w600),
                        inputFormatters: [
                          FilteringTextInputFormatter.deny(RegExp(r'@')),
                          FilteringTextInputFormatter.deny(RegExp(r'\s')),
                          LengthLimitingTextInputFormatter(20),
                        ],
                        maxLength: 20,
                        decoration: _fieldDecoration(
                            isLight: isLight, label: 'יוזר', prefixText: '@'),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _bioController,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: bodyTextColor, fontWeight: FontWeight.w500),
                        keyboardType: TextInputType.multiline,
                        minLines: 3,
                        maxLines: 5,
                        maxLength: 80,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(80),
                        ],
                        decoration: _fieldDecoration(
                            isLight: isLight, label: 'תיאור משתמש'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isLight ? Colors.white : _accentPurple,
                  foregroundColor:
                      isLight ? const Color(0xFFB79BFF) : Colors.white,
                  side: isLight
                      ? const BorderSide(color: Color(0xFFB79BFF), width: 1)
                      : BorderSide.none,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: _isSaving
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isLight
                                ? const Color(0xFFB79BFF)
                                : Colors.white),
                      )
                    : Text(
                        'שמור',
                        style: TextStyle(
                            color: isLight
                                ? const Color(0xFFB79BFF)
                                : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
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
