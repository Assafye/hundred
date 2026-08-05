import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'online_screen.dart';
import 'chats_screen.dart';
import 'create_post_screen.dart';
import 'feed_screen.dart';
import 'profile_screen.dart';

class MainBottomNav extends StatelessWidget {
  static final ValueNotifier<bool> feedPlaybackPausedByComposer =
      ValueNotifier<bool>(false);
  static const double _compactWidthBreakpoint = 380;
  static const double _compactNavHeight = 66;
  static const double _regularNavHeight = 72;

  static double navBarHeightForWidth(double width) {
    return width < _compactWidthBreakpoint
        ? _compactNavHeight
        : _regularNavHeight;
  }

  static double occupiedHeight(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return navBarHeightForWidth(mediaQuery.size.width) +
        mediaQuery.padding.bottom;
  }

  final int currentIndex;
  final VoidCallback? onReselectCurrentTab;

  const MainBottomNav({
    super.key,
    required this.currentIndex,
    this.onReselectCurrentTab,
  });

  void _navigateToRoot(BuildContext context, Widget screen) {
    Navigator.pushAndRemoveUntil(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
      (route) => false,
    );
  }

  void _handleTap(BuildContext context, int index) {
    if (index == 2) {
      feedPlaybackPausedByComposer.value = true;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const CreatePostScreen()),
      ).whenComplete(() {
        feedPlaybackPausedByComposer.value = false;
      });
      return;
    }

    if (index == currentIndex) {
      onReselectCurrentTab?.call();
      return;
    }

    if (index == 0) {
      _navigateToRoot(context, const FeedScreen());
    } else if (index == 1) {
      _navigateToRoot(context, const OnlineScreen());
    } else if (index == 3) {
      _navigateToRoot(context, const ChatsScreen());
    } else if (index == 4) {
      _navigateToRoot(context, const MyProfileScreen());
    }
  }

  Widget _buildNavIcon({
    required BuildContext context,
    required IconData icon,
    required bool isActive,
    required Color iconColor,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final compact = screenWidth < 380;
    final baseSize = compact ? 34.0 : 38.0;
    final activeSize = compact ? 38.0 : 42.0;
    final iconSize = compact
        ? (isActive ? 22.0 : 20.0)
        : (isActive ? 25.0 : 23.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: isActive ? activeSize : baseSize,
      height: isActive ? activeSize : baseSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: isActive
            ? LinearGradient(
                colors: isLight
                    ? const [Color(0x66CDAFFF), Color(0x66A9EEFF)]
                    : const [Color(0x449E7CFF), Color(0x3353C1F9)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: (isLight
                          ? const Color(0xFF53C1F9)
                          : const Color(0xFF53C1F9))
                      .withValues(alpha:  isLight ? 0.22 : 0.18),
                  blurRadius: isLight ? 14 : 12,
                  spreadRadius: 0.4,
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        color: iconColor,
        size: iconSize,
      ),
    );
  }

  Widget _buildPlusIcon(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final compact = screenWidth < 380;
    return Container(
      width: compact ? 44 : 48,
      height: compact ? 44 : 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF53C1F9).withValues(alpha:  0.25),
            blurRadius: 16,
            spreadRadius: 1.1,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: const Color(0xFF9E7CFF).withValues(alpha:  0.28),
            blurRadius: 20,
            spreadRadius: 0.6,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: compact ? 38 : 41,
          height: compact ? 38 : 41,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
            color: isLight
                ? const Color(0xFFFFFFFF).withValues(alpha:  0.36)
                : const Color(0xFF101827).withValues(alpha:  0.22),
            border:
                Border.all(color: Colors.white.withValues(alpha:  0.34), width: 0.9),
          ),
          child: Icon(
            Icons.add_rounded,
            color: isLight ? const Color(0xFF1D2742) : Colors.white,
            size: compact ? 24 : 28,
          ),
        ),
      ),
    );
  }

  DateTime? _toDateTime(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  Widget _buildProfileIconWithNotificationDot({
    required BuildContext context,
    required bool isActive,
    required Color iconColor,
  }) {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final baseIcon = _buildNavIcon(
      context: context,
      icon: Icons.person_rounded,
      isActive: isActive,
      iconColor: iconColor,
    );

    if (uid.isEmpty) {
      return baseIcon;
    }

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) {
          return baseIcon;
        }

        final userData = userSnapshot.data?.data() ?? const <String, dynamic>{};
        final lastVisitedAt = _toDateTime(userData['notificationsLastVisitedAt']);
        final unreadCount = (userData['unreadNotificationsCount'] as num?)?.toInt() ?? 0;

        if (lastVisitedAt == null) {
          return _wrapProfileIconWithDot(baseIcon, showDot: unreadCount > 0);
        }

        final notificationsQuery = userRef
            .collection('notifications')
            .where('createdAt', isGreaterThan: Timestamp.fromDate(lastVisitedAt))
            .limit(1)
            .snapshots();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: notificationsQuery,
          builder: (context, notificationsSnapshot) {
            final hasNewSinceLastVisit =
                (notificationsSnapshot.data?.docs.isNotEmpty ?? false);
            return _wrapProfileIconWithDot(
              baseIcon,
              showDot: hasNewSinceLastVisit,
            );
          },
        );
      },
    );
  }

  Widget _wrapProfileIconWithDot(Widget icon, {required bool showDot}) {
    if (!showDot) {
      return icon;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: 5,
          left: 4,
          child: Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF8D74E6), Color(0xFF6DBFE8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0xAA8D74E6),
                  blurRadius: 8,
                  spreadRadius: 0.8,
                ),
                BoxShadow(
                  color: Color(0x886DBFE8),
                  blurRadius: 10,
                  spreadRadius: 0.8,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final selectedColor =
        isLight ? const Color(0xFF7E63D8) : const Color(0xFFB39DFF);
    final unselectedColor =
        isLight ? const Color(0xFF6D7A98) : const Color(0xFF9CA4C9);
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final screenWidth = MediaQuery.of(context).size.width;
    final navHeight = navBarHeightForWidth(screenWidth);

    Widget navItem({
      required int index,
      required Widget child,
    }) {
      return Expanded(
        child: InkWell(
          onTap: () => _handleTap(context, index),
          child: SizedBox(
            height: navHeight,
            child: Center(child: child),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLight
              ? const [Color(0xFFF8FBFF), Color(0xFFEAF1FF)]
              : const [Color(0xFF100F1E), Color(0xFF1A1730)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border(
          top: BorderSide(
            color: (isLight ? const Color(0xFFC9B4FF) : const Color(0xFFB39DFF))
                .withValues(alpha:  isLight ? 0.56 : 0.28),
            width: 0.9,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: (isLight ? const Color(0xFF7D8FB2) : const Color(0xFF080611))
                .withValues(alpha:  isLight ? 0.2 : 0.34),
            blurRadius: isLight ? 18 : 20,
            offset: Offset(0, isLight ? -5 : -7),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: navHeight,
          child: Row(
            children: [
              navItem(
                index: 0,
                child: _buildNavIcon(
                  context: context,
                  icon: Icons.all_inclusive_rounded,
                  isActive: currentIndex == 0,
                  iconColor:
                      currentIndex == 0 ? selectedColor : unselectedColor,
                ),
              ),
              navItem(
                index: 1,
                child: _buildNavIcon(
                  context: context,
                  icon: Icons.wifi_tethering_rounded,
                  isActive: currentIndex == 1,
                  iconColor:
                      currentIndex == 1 ? selectedColor : unselectedColor,
                ),
              ),
              navItem(index: 2, child: _buildPlusIcon(context)),
              navItem(
                index: 3,
                child: _buildNavIcon(
                  context: context,
                  icon: Icons.forum_rounded,
                  isActive: currentIndex == 3,
                  iconColor:
                      currentIndex == 3 ? selectedColor : unselectedColor,
                ),
              ),
              navItem(
                index: 4,
                child: _buildProfileIconWithNotificationDot(
                  context: context,
                  isActive: currentIndex == 4,
                  iconColor:
                      currentIndex == 4 ? selectedColor : unselectedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
