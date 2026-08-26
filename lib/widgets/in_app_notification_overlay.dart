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
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: isLight
                ? Colors.white.withValues(alpha: 0.98)
                : const Color(0xFF16253A).withValues(alpha: 0.98),
            border: Border.all(
              color: isLight
                  ? const Color(0xFF8DBBFF)
                  : const Color(0xFF53C1F9).withValues(alpha: 0.45),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF53C1F9).withValues(alpha: 0.22),
                  ),
                  child: const Icon(
                    Icons.notifications_active_rounded,
                    color: Color(0xFF53C1F9),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF0E1524)
                              : Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      if (event.body.trim().isNotEmpty)
                        Text(
                          event.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF4A5C7A)
                                : Colors.white70,
                            fontWeight: FontWeight.w500,
                            fontSize: 12,
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
}
