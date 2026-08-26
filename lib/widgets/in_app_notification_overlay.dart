import 'dart:async';

import 'package:flutter/material.dart';

import '../app_categories.dart';
import '../services/notification_service.dart';
import '../services/notification_navigation_service.dart';
import '../services/notification_runtime_service.dart';
import '../services/weekly_challenge_service.dart';

class InAppNotificationOverlay extends StatefulWidget {
  const InAppNotificationOverlay({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<InAppNotificationOverlay> createState() =>
      _InAppNotificationOverlayState();
}

class _InAppNotificationOverlayState extends State<InAppNotificationOverlay> {
  StreamSubscription<InAppNotificationEvent>? _sub;
  InAppNotificationEvent? _current;
  Timer? _hideTimer;

  void _dismissCurrent() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _current = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _sub = NotificationRuntimeService.instance.inAppEvents.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        _current = event;
      });
      _hideTimer?.cancel();
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        setState(() {
          _current = null;
        });
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: topPadding + 18,
          left: 12,
          right: 12,
          child: IgnorePointer(
            ignoring: _current == null,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              offset: _current == null ? const Offset(0, -1.2) : Offset.zero,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _current == null ? 0 : 1,
                child: _current == null
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onVerticalDragUpdate: (details) {
                          // Negative dy means upward swipe.
                          if (details.delta.dy <= -8) {
                            _dismissCurrent();
                          }
                        },
                        child: _NotificationBanner(
                          event: _current!,
                          onTap: () async {
                            final current = _current;
                            if (current == null) {
                              return;
                            }
                            _dismissCurrent();
                            await NotificationNavigationService.openFromData(
                              current.data,
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationBanner extends StatelessWidget {
  const _NotificationBanner({
    required this.event,
    required this.onTap,
  });

  final InAppNotificationEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final type = (event.data['type'] as String? ?? '').trim();
    if (type == NotificationTypes.postLike) {
      return _buildPostLikeBanner(context);
    }
    if (type == NotificationTypes.postComment) {
      return _buildPostCommentBanner(context);
    }
    if (type == NotificationTypes.commentReply) {
      return _buildCommentReplyBanner(context);
    }
    if (type == NotificationTypes.newMessage) {
      return _buildNewMessageBanner(context);
    }
    if (type == NotificationTypes.weeklyChallengeUpdated) {
      return _buildWeeklyChallengeUpdatedBanner(context);
    }
    if (type == NotificationTypes.dailyChallengeUpdated) {
      return _buildDailyChallengeUpdatedBanner(context);
    }
    if (type == NotificationTypes.spontaneousReminder) {
      return _buildSpontaneousReminderBanner(context);
    }
    if (type == NotificationTypes.spontaneousTimeWarning) {
      return _buildSpontaneousTimeWarningBanner(context);
    }
    if (type == NotificationTypes.weeklyStars) {
      return _buildWeeklyStarsBanner(context);
    }
    if (type == NotificationTypes.groupJoin) {
      return _buildGroupJoinBanner(context);
    }
    if (type == NotificationTypes.addedToGroup) {
      return _buildAddedToGroupBanner(context);
    }
    if (type == NotificationTypes.popJoin) {
      return _buildPopJoinBanner(context);
    }
    if (type == NotificationTypes.postSave) {
      return _buildPostSaveBanner(context);
    }
    if (type == NotificationTypes.newFollower) {
      return _buildNewFollowerBanner(context);
    }
    if (type == NotificationTypes.newFriend) {
      return _buildNewFriendBanner(context);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.92),
                      const Color(0xFF182845).withValues(alpha: 0.92),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.0,
                strokeAlign: BorderSide.strokeAlignInside,
                color: Colors.transparent,
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF8EE3FF),
                        Color(0xFFB7A9FF),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8EE3FF).withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.notifications_active_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPostCommentBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final postImageUrl = (event.data['postImageUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final rawTitle = (event.data['title'] as String? ?? '').trim();
    final commentText = rawTitle.replaceAll('"', '').trim();
    final title = actorName.isNotEmpty
      ? '$actorName הגיב/ה: $commentText'
      : 'הגיבו: $commentText';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildPostThumbnail(postImageUrl: postImageUrl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _weeklyChallengeCategory() {
    final explicit = (event.data['challengeCategory'] as String? ?? '').trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }

    final body = (event.data['body'] as String? ?? '').trim();
    final match = RegExp(r'אתגר חדש:\s*([^|]+)').firstMatch(body);
    if (match != null) {
      final parsed = (match.group(1) ?? '').trim();
      if (parsed.isNotEmpty) {
        return parsed;
      }
    }

    return WeeklyChallengeService.currentChallenge().mainCategory;
  }

  Widget _buildWeeklyChallengeUpdatedBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final challengeCategory = _weeklyChallengeCategory();
    final challengeIcon = categoryIconFor(
      challengeCategory.isEmpty ? kGeneralCategory : challengeCategory,
    );
    const title = 'האתגר השבועי התעדכן! ניתן לצפות במסך כוכבי השבוע';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8B78FF).withValues(alpha: 0.30),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(
                    challengeIcon,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDailyChallengeUpdatedBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final challengeCategory = _weeklyChallengeCategory();
    final challengeIcon = categoryIconFor(
      challengeCategory.isEmpty ? kGeneralCategory : challengeCategory,
    );
    const title = 'המשימה היומית התעדכנה! השעון התחיל לרוץ...';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8B78FF).withValues(alpha: 0.30),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(
                    challengeIcon,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyStarsBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final postImageUrl = (event.data['postImageUrl'] as String? ?? '').trim();
    const title = 'הפוסט שלך נכנס למסך כוכבי השבוע!';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF2B1F4A).withValues(alpha: 0.94),
                      const Color(0xFF1E2F4C).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFFFF4D8),
                      const Color(0xFFF4F1FF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFC857).withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFFFFD166),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFC857), Color(0xFFFF7A8A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFFC857).withValues(alpha: 0.30),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.celebration_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildPostThumbnail(postImageUrl: postImageUrl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpontaneousReminderBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const title = 'מבחן הספונטניות זמין! זה הזמן להגריל משימה לקבל ניקוד x10';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF76CFFF).withValues(alpha: 0.40),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
              BoxShadow(
                color: const Color(0xFFC9B5FF).withValues(alpha: 0.24),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.15,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55),
                      width: 1.0,
                    ),
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: Color(0xFF2A2361),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: Color(0xFF2A2361),
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _messagePreviewText() {
    final body = (event.data['body'] as String? ?? '').trim();
    if (body.isEmpty) {
      return 'שלח/ה הודעה חדשה';
    }

    // Keep backward compatibility with older payloads that wrapped the body in quotes.
    if (body.length >= 2 && body.startsWith('"') && body.endsWith('"')) {
      return body.substring(1, body.length - 1).trim();
    }
    return body;
  }

  Widget _buildNewMessageBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final senderName = (event.data['actorName'] as String? ?? '').trim().isEmpty
        ? 'משתמש'
        : (event.data['actorName'] as String).trim();
    final senderAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final isGroupChat = (event.data['isGroupChat'] as bool?) ?? false;
    final chatNameRaw = (event.data['chatName'] as String? ?? '').trim();
    final chatName = chatNameRaw.isNotEmpty
        ? chatNameRaw
        : ((event.data['title'] as String? ?? '').trim().isNotEmpty
            ? (event.data['title'] as String).trim()
            : 'קבוצה');
    final chatAvatarUrl = (event.data['chatAvatarUrl'] as String? ?? '').trim();
    final messageText = _messagePreviewText();

    if (!isGroupChat) {
      final privateTitle = '$senderName "$messageText"';
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                colors: isDark
                    ? [
                        const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                        const Color(0xFF182845).withValues(alpha: 0.94),
                      ]
                    : [
                        const Color(0xFFEAF5FF),
                        const Color(0xFFE9EEFF),
                      ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  width: 1.25,
                  color: const Color(0xFF7ED9FF),
                ),
              ),
              child: Row(
                textDirection: TextDirection.rtl,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildAvatar(avatarUrl: senderAvatarUrl, size: 42),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      privateTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final groupSubtitle = '$senderName: "$messageText"';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(
                  avatarUrl: chatAvatarUrl.isEmpty ? senderAvatarUrl : chatAvatarUrl,
                  size: 42,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        chatName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          color: isDark ? Colors.white : const Color(0xFF13233B),
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        groupSubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.78)
                              : const Color(0xFF2A3E57),
                          fontWeight: FontWeight.w500,
                          fontSize: 12.5,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _spontaneousCategory() {
    final explicit = (event.data['spontaneousCategory'] as String? ?? '').trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }
    return kGeneralCategory;
  }

  int _spontaneousWarningHours() {
    final raw = event.data['warningHoursRemaining'];
    if (raw is num && raw.toInt() > 0) {
      return raw.toInt();
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final body = (event.data['body'] as String? ?? '').trim();
    final match = RegExp(r'(\d+)').firstMatch(body);
    if (match != null) {
      final parsed = int.tryParse((match.group(1) ?? '').trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return 1;
  }

  String _spontaneousWarningHoursLabel() {
    final hours = _spontaneousWarningHours();
    if (hours == 1) {
      return 'שעה';
    }
    return '$hours שעות';
  }

  Widget _buildSpontaneousTimeWarningBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final category = _spontaneousCategory();
    final icon = categoryIconFor(
      category.isEmpty ? kGeneralCategory : category,
    );
    final title =
        'השעון מתקתק! נשאר לך עוד ${_spontaneousWarningHoursLabel()} למשימה שלך!';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF251C44).withValues(alpha: 0.95),
                      const Color(0xFF1D304D).withValues(alpha: 0.95),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7C9BFF).withValues(alpha: 0.24),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.15,
                color: const Color(0xFFA9C3FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55),
                      width: 1.0,
                    ),
                  ),
                  child: Icon(
                    icon,
                    color: const Color(0xFF2A2361),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<String> _stringList(Map<String, dynamic> data, String key) {
    final raw = data[key];
    if (raw is! List) {
      return const <String>[];
    }
    return raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  int _addedUsersCount() {
    final explicitRaw = event.data['addedUsersCount'];
    if (explicitRaw is num && explicitRaw.toInt() > 0) {
      return explicitRaw.toInt();
    }
    if (explicitRaw is String) {
      final parsed = int.tryParse(explicitRaw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final userUids = _stringList(event.data, 'addedUserUids').toSet().length;
    if (userUids > 0) {
      return userUids;
    }

    final userNames = _stringList(event.data, 'addedUserNames').toSet().length;
    if (userNames > 0) {
      return userNames;
    }

    final singleName = (event.data['addedUserName'] as String? ?? '').trim();
    return singleName.isNotEmpty ? 1 : 1;
  }

  String _addedPrimaryUserName() {
    final singleName = (event.data['addedUserName'] as String? ?? '').trim();
    if (singleName.isNotEmpty) {
      return singleName;
    }

    final names = _stringList(event.data, 'addedUserNames');
    if (names.isNotEmpty) {
      return names.first;
    }

    return 'משתמש';
  }

  List<String> _addedToGroupAvatarUrls() {
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final singleAddedAvatar =
        (event.data['addedUserAvatarUrl'] as String? ?? '').trim();
    final listAddedAvatars = _stringList(event.data, 'addedUserAvatarUrls');

    final result = <String>[];
    final seen = <String>{};

    void addAvatar(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) {
        return;
      }
      if (seen.add(normalized)) {
        result.add(normalized);
      }
    }

    addAvatar(actorAvatarUrl);
    addAvatar(singleAddedAvatar);
    for (final avatar in listAddedAvatars) {
      addAvatar(avatar);
    }

    return result;
  }

  Widget _buildAddedToGroupBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final normalizedActor = actorName.isNotEmpty ? actorName : 'משתמש';
    final groupName = (event.data['groupName'] as String? ?? '').trim();
    final normalizedGroup = groupName.isNotEmpty ? groupName : 'קבוצה';
    final addedCount = _addedUsersCount();
    final primaryAddedName = _addedPrimaryUserName();
    final avatarUrls = _addedToGroupAvatarUrls().take(4).toList(growable: false);

    final title = addedCount > 1
        ? '$normalizedActor הוסיף $addedCount אנשים לקבוצה "$normalizedGroup"'
        : '$normalizedActor הוסיף את $primaryAddedName לקבוצה "$normalizedGroup"';

    final avatarStack = <Widget>[];
    for (final avatarUrl in avatarUrls) {
      avatarStack.add(
        Positioned(
          right: avatarStack.length * 14.0,
          child: _buildAvatar(avatarUrl: avatarUrl, size: 34),
        ),
      );
    }

    final stackWidth = avatarUrls.isEmpty ? 34.0 : avatarUrls.length * 14.0 + 34.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: stackWidth,
                  height: 34,
                  child: avatarStack.isEmpty
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: _buildAvatar(avatarUrl: '', size: 34),
                        )
                      : Stack(children: avatarStack),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF13233B),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommentReplyBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final postImageUrl = (event.data['postImageUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final rawTitle = (event.data['title'] as String? ?? '').trim();
    final replyText = rawTitle.replaceAll('"', '').trim();
    final title = actorName.isNotEmpty
        ? '$actorName הגיב לך: $replyText'
        : 'הגיבו לך: $replyText';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildPostThumbnail(postImageUrl: postImageUrl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupJoinBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final groupName = (event.data['groupName'] as String? ?? '').trim();
    final normalizedActor = actorName.isNotEmpty ? actorName : 'משתמש';
    final normalizedGroup = groupName.isNotEmpty ? groupName : 'קבוצה';
    final title = '$normalizedActor הצטרף לקבוצה "$normalizedGroup"';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
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
  }

  Widget _buildPopJoinBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final groupName = (event.data['groupName'] as String? ?? '').trim();
    final normalizedActor = actorName.isNotEmpty ? actorName : 'משתמש';
    final normalizedGroup = groupName.isNotEmpty ? groupName : 'פופ';
    final title = '$normalizedActor הצטרף לפופ שלך "$normalizedGroup"!';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
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
  }

  Widget _buildPostSaveBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final postImageUrl = (event.data['postImageUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final title = actorName.isNotEmpty
        ? '$actorName שמר את הפוסט שלך'
        : 'שמרו את הפוסט שלך';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildPostThumbnail(postImageUrl: postImageUrl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNewFollowerBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final title = actorName.isNotEmpty
        ? '$actorName התחיל לעקוב אחריך'
        : 'מישהו התחיל לעקוב אחריך';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
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
  }

  Widget _buildNewFriendBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final normalizedName = actorName.isEmpty ? 'משתמש' : actorName;
    final title = 'איזה כיף, $normalizedName נהיה חבר שלך!';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF13233B),
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.15,
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
  }

  Widget _buildPostLikeBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actorAvatarUrl = (event.data['actorAvatarUrl'] as String? ?? '').trim();
    final postImageUrl = (event.data['postImageUrl'] as String? ?? '').trim();
    final actorName = (event.data['actorName'] as String? ?? '').trim();
    final likeCount = (event.data['likeCount'] as num?)?.toInt() ?? 1;
    final title = likeCount > 1
        ? 'יש לך $likeCount לייקים על הפוסט'
        : 'יש לך לייק חדש על הפוסט';
    final subtitle = actorName.isEmpty
        ? event.body.trim()
      : '$actorName אהב/ה את הפוסט שלך';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: isDark
                  ? [
                      const Color(0xFF1B2D4C).withValues(alpha: 0.94),
                      const Color(0xFF182845).withValues(alpha: 0.94),
                    ]
                  : [
                      const Color(0xFFEAF5FF),
                      const Color(0xFFE9EEFF),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF75CEF9).withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                width: 1.25,
                color: const Color(0xFF7ED9FF),
              ),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildAvatar(avatarUrl: actorAvatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color:
                                  isDark ? Colors.white : const Color(0xFF13233B),
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              height: 1.15,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.78)
                                  : const Color(0xFF2A3E57),
                              fontWeight: FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildPostThumbnail(postImageUrl: postImageUrl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar({required String avatarUrl, required double size}) {
    if (avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFBFD9FF),
        ),
        child: const Icon(Icons.person_rounded, size: 20, color: Colors.white),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          avatarUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFFBFD9FF),
            child: const Icon(Icons.person_rounded, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildPostThumbnail({required String postImageUrl}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 48,
        height: 48,
        child: postImageUrl.isEmpty
            ? Container(
                color: const Color(0xFFE9EBFF),
                child: const Icon(
                  Icons.image_rounded,
                  color: Color(0xFF7C7CEF),
                  size: 20,
                ),
              )
            : Image.network(
                postImageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFFE9EBFF),
                  child: const Icon(
                    Icons.image_rounded,
                    color: Color(0xFF7C7CEF),
                    size: 20,
                  ),
                ),
              ),
      ),
    );
  }
}
