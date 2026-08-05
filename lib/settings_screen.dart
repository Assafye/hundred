import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'delete_account_screen.dart';
import 'edit_profile_screen.dart';
import 'login_screen.dart';
import 'notification_settings_screen.dart';
import 'personal_details_screen.dart';
import 'privacy_policy_dialog.dart';
import 'services/theme_mode_service.dart';
import 'settings_history_screen.dart';
import 'services/auth_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Color _bgTop = Colors.white;
  static const Color _bgBottom = Colors.white;
  static const Color _cardWhite = Color(0x80FFFFFF);
  static const Color _darkBgTop = Color(0xFF10162A);
  static const Color _darkBgBottom = Color(0xFF0B1019);
  static const Color _darkCardTop = Color(0xFF172437);
  static const Color _darkCardBottom = Color(0xFF231C3F);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFFB79BFF);
  static const Color _shortcutArrow = Color(0xFF9AB0FF);

  final AuthService _authService = AuthService();
  bool _isSigningOut = false;
  final bool _isDeleting = false;
  ThemeMode _selectedThemeMode = ThemeMode.dark;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _selectedThemeMode = ThemeModeService.instance.themeMode;
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _selectedThemeMode = mode);
    await ThemeModeService.instance.setThemeMode(mode);
  }

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    final shouldSignOut = await _showActionConfirmationDialog(
      title: 'התנתקות',
      message: 'האם אתה בטוח שברצונך להתנתק מהחשבון?',
      confirmLabel: 'כן, להתנתק',
      accentColor: _accentCyan,
    );
    if (shouldSignOut != true) {
      return;
    }

    setState(() => _isSigningOut = true);
    try {
      await _authService.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('התנתקות נכשלה: $error')),
      );
      setState(() => _isSigningOut = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_isDeleting) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
    );
  }

  Future<bool?> _showActionConfirmationDialog({
    required String title,
    required String message,
    required String confirmLabel,
    required Color accentColor,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: isLight ? Colors.white : const Color(0xFF101826),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: isLight
                    ? accentColor.withValues(alpha: 0.32)
                    : accentColor.withValues(alpha: 0.22),
              ),
            ),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            title: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isLight
                        ? accentColor.withValues(alpha: 0.14)
                        : accentColor.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    Icons.help_outline_rounded,
                    color: isLight ? const Color(0xFF34425D) : Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              message,
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: isLight ? const Color(0xFF46536D) : Colors.white70,
                height: 1.45,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(
                  'ביטול',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF46536D) : Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  confirmLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _togglePrivacy(bool value) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;

    try {
      await _authService.updatePrivateProfile(uid: uid, isPrivate: value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value ? 'החשבון הוגדר כפרטי' : 'החשבון הוגדר כציבורי'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('עדכון פרטיות נכשל: $error')),
      );
    }
  }

  Widget _sectionCard({required Widget child, required bool isLight}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: isLight ? _cardWhite : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  _darkCardTop.withValues(alpha: 0.95),
                  _darkCardBottom.withValues(alpha: 0.95),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
        border: Border.all(
            color: _accentCyan.withValues(alpha: isLight ? 0.25 : 0.2)),
        boxShadow: [
          BoxShadow(
            color: isLight
                ? _accentCyan.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.2),
            blurRadius: isLight ? 18 : 16,
            offset: Offset(0, isLight ? 6 : 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _navTile({
    required bool isLight,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isLight
              ? Colors.white.withValues(alpha: 0.6)
              : const Color(0xFF1A2435),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: _accentCyan.withValues(alpha: isLight ? 0.2 : 0.14)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isLight ? Colors.black87 : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_left_rounded,
              color: isLight ? _shortcutArrow : Colors.white54,
            ),
          ],
        ),
      ),
    );
  }

  Widget _themeSegmentLabel(String text) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final titleColor = isLight ? Colors.black : Colors.white;
    final subtitleColor = isLight ? Colors.black87 : Colors.white70;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.84).clamp(240.0, 320.0);
    final orbSizeB = (screenWidth * 0.9).clamp(260.0, 340.0);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: isLight ? _bgBottom : _darkBgBottom,
          appBar: AppBar(
            backgroundColor:
                isLight ? const Color(0xFFBFD9FF) : const Color(0xFF131E31),
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            centerTitle: true,
            iconTheme: IconThemeData(color: titleColor),
            title: Text(
              'הגדרות',
              style: TextStyle(color: titleColor, fontWeight: FontWeight.w800),
            ),
          ),
          body: Container(
            constraints: const BoxConstraints.expand(),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isLight
                    ? const [_bgTop, _bgBottom]
                    : const [_darkBgTop, Color(0xFF131B33), _darkBgBottom],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Stack(
              children: [
                if (isLight)
                  Positioned(
                    top: -120,
                    right: -90,
                    child: IgnorePointer(
                      child: Container(
                        width: orbSizeA,
                        height: orbSizeA,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              const Color(0xFFB9A9FF).withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ),
                if (isLight)
                  Positioned(
                    bottom: -130,
                    left: -90,
                    child: IgnorePointer(
                      child: Container(
                        width: orbSizeB,
                        height: orbSizeB,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              const Color(0xFF9EEBFF).withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ),
                uid == null || uid.isEmpty
                    ? Center(
                        child: Text(
                          'יש להתחבר מחדש כדי לראות הגדרות',
                          style: TextStyle(color: subtitleColor),
                        ),
                      )
                    : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .collection('users')
                            .doc(uid)
                            .snapshots(),
                        builder: (context, snapshot) {
                          final data =
                              snapshot.data?.data() ?? <String, dynamic>{};
                          final displayName = (data['displayName'] as String? ??
                                  data['firstName'] as String? ??
                                  '')
                              .trim();
                          final username =
                              (data['username'] as String? ?? '').trim();
                          final bio = (data['bio'] as String? ?? '').trim();
                          final isPrivate =
                              (data['isPrivate'] as bool?) ?? false;
                          final allowGroupInvite =
                              (data['allowGroupInvite'] as bool?) ?? true;
                          final currentName = displayName.isNotEmpty
                              ? displayName
                              : 'הפרופיל שלי';
                          final currentHandle =
                              username.isNotEmpty ? username : '@user';

                          return ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                            children: [
                              _sectionCard(
                                isLight: isLight,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'קיצורי דרך',
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    _navTile(
                                      isLight: isLight,
                                      icon: Icons.history_rounded,
                                      title: 'היסטוריה',
                                      subtitle: 'לייקים, תגובות ופופים אחרונים',
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const SettingsHistoryScreen(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    _navTile(
                                      isLight: isLight,
                                      icon: Icons.badge_rounded,
                                      title: 'עריכת פרטים אישיים',
                                      subtitle:
                                          'טלפון, מייל ותאריך לידה עם אימות',
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const PersonalDetailsScreen(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    _navTile(
                                      isLight: isLight,
                                      icon: Icons.edit_rounded,
                                      title: 'עריכת פרופיל ציבורי',
                                      subtitle: 'שם, יוזר, ביו ותמונת פרופיל',
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => EditProfileScreen(
                                            currentName: currentName,
                                            currentHandle: currentHandle,
                                            currentBio: bio,
                                            currentAllowGroupInvite:
                                                allowGroupInvite,
                                            currentImageUrl:
                                                (data['profilePictureUrl']
                                                            as String? ??
                                                        '')
                                                    .trim(),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    _navTile(
                                      isLight: isLight,
                                      icon: Icons.notifications_active_rounded,
                                      title: 'התראות',
                                      subtitle:
                                          'שליטה מלאה על סוגי ההתראות שתקבל',
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const NotificationSettingsScreen(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    _navTile(
                                      isLight: isLight,
                                      icon: Icons.privacy_tip_rounded,
                                      title: 'מדיניות פרטיות',
                                      subtitle:
                                          'קריאת תנאי שימוש ומדיניות פרטיות',
                                      onTap: () =>
                                          showPrivacyPolicyDialog(context),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                              _sectionCard(
                                isLight: isLight,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'תצוגה',
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'בחר מצב כהה, בהיר או התאמה אוטומטית לפי המכשיר.',
                                      style: TextStyle(color: subtitleColor),
                                    ),
                                    const SizedBox(height: 12),
                                    SegmentedButton<ThemeMode>(
                                      showSelectedIcon: false,
                                      style: ButtonStyle(
                                        foregroundColor: WidgetStatePropertyAll(
                                          isLight ? Colors.black : Colors.white,
                                        ),
                                        backgroundColor:
                                            WidgetStateProperty.resolveWith(
                                                (states) {
                                          if (states
                                              .contains(WidgetState.selected)) {
                                            return isLight
                                                ? _accentPurple.withValues(
                                                    alpha: 0.75)
                                                : _accentPurple.withValues(
                                                    alpha: 0.72);
                                          }
                                          return isLight
                                              ? Colors.white
                                                  .withValues(alpha: 0.65)
                                              : const Color(0xFF1A2435);
                                        }),
                                        side: WidgetStatePropertyAll(
                                          BorderSide(
                                            color: _accentCyan.withValues(
                                                alpha: isLight ? 0.35 : 0.2),
                                          ),
                                        ),
                                      ),
                                      segments: [
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.dark,
                                          icon: const Icon(
                                              Icons.dark_mode_rounded,
                                              size: 18),
                                          label: _themeSegmentLabel('כהה'),
                                        ),
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.light,
                                          icon: const Icon(
                                              Icons.light_mode_rounded,
                                              size: 18),
                                          label: _themeSegmentLabel('בהיר'),
                                        ),
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.system,
                                          icon: const Icon(
                                              Icons.brightness_auto_rounded,
                                              size: 18),
                                          label: _themeSegmentLabel('מערכת'),
                                        ),
                                      ],
                                      selected: <ThemeMode>{_selectedThemeMode},
                                      onSelectionChanged: (selection) {
                                        if (selection.isEmpty) return;
                                        _setThemeMode(selection.first);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                              _sectionCard(
                                isLight: isLight,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'חשבון פרטי',
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'רק חברים יוכלו לצפות בתוכן הפרופיל והפופים שלך.',
                                      style: TextStyle(color: subtitleColor),
                                    ),
                                    const SizedBox(height: 12),
                                    SwitchListTile.adaptive(
                                      contentPadding: EdgeInsets.zero,
                                      value: isPrivate,
                                      onChanged: _togglePrivacy,
                                      activeThumbColor:
                                          isLight ? _accentPurple : _accentCyan,
                                      activeTrackColor: isLight
                                          ? _accentCyan.withValues(alpha: 0.8)
                                          : _accentPurple.withValues(
                                              alpha: 0.55),
                                      title: Text(
                                        'הפוך את החשבון לפרטי',
                                        style: TextStyle(
                                          color: titleColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      subtitle: Text(
                                        'משתמשים שאינם חברים יקבלו הודעת נעילה בפרופיל.',
                                        style: TextStyle(color: subtitleColor),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                              _sectionCard(
                                isLight: isLight,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'חשבון',
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (isLight)
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          gradient: const LinearGradient(
                                            colors: [
                                              Color(0xFFAEEAFF),
                                              Color(0xFFC9B7FF)
                                            ],
                                            begin: Alignment.centerRight,
                                            end: Alignment.centerLeft,
                                          ),
                                        ),
                                        child: ElevatedButton.icon(
                                          onPressed:
                                              _isSigningOut ? null : _signOut,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            foregroundColor: Colors.black,
                                            shadowColor: Colors.transparent,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 14),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                          ),
                                          icon: _isSigningOut
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: Colors.black,
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.logout_rounded),
                                          label: Text(
                                            _isSigningOut
                                                ? 'מתנתק...'
                                                : 'התנתקות',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800),
                                          ),
                                        ),
                                      ),
                                    if (!isLight)
                                      ElevatedButton.icon(
                                        onPressed:
                                            _isSigningOut ? null : _signOut,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _accentCyan,
                                          foregroundColor: Colors.black,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                        ),
                                        icon: _isSigningOut
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.black,
                                                ),
                                              )
                                            : const Icon(Icons.logout_rounded),
                                        label: Text(
                                          _isSigningOut
                                              ? 'מתנתק...'
                                              : 'התנתקות',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                    const SizedBox(height: 10),
                                    if (isLight)
                                      OutlinedButton.icon(
                                        onPressed:
                                            _isDeleting ? null : _deleteAccount,
                                        style: OutlinedButton.styleFrom(
                                          backgroundColor: Colors.white,
                                          foregroundColor: _accentPurple,
                                          side: BorderSide(
                                              color: _accentPurple.withValues(
                                                  alpha: 0.9),
                                              width: 1.1),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                        ),
                                        icon: _isDeleting
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: _accentPurple,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.delete_forever_rounded),
                                        label: Text(
                                          _isDeleting
                                              ? 'מוחק...'
                                              : 'מחיקת חשבון',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                    if (!isLight)
                                      OutlinedButton.icon(
                                        onPressed:
                                            _isDeleting ? null : _deleteAccount,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          side: BorderSide(
                                              color: Colors.redAccent
                                                  .withValues(alpha: 0.8)),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                        ),
                                        icon: _isDeleting
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.delete_forever_rounded),
                                        label: Text(
                                          _isDeleting
                                              ? 'מוחק...'
                                              : 'מחיקת חשבון',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
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
