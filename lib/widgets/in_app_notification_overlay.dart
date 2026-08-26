import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_navigation_service.dart';
import '../services/notification_runtime_service.dart';

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
          top: topPadding + 10,
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
                    : _NotificationBanner(
                        event: _current!,
                        onTap: () async {
                          final current = _current;
                          if (current == null) {
                            return;
                          }
                          setState(() {
                            _current = null;
                          });
                          await NotificationNavigationService.openFromData(
                            current.data,
                          );
                        },
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
}
