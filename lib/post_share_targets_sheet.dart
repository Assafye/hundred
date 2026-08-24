import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import '../services/chat_service.dart';
import '../services/keyboard_dismiss_controller.dart';
import '../services/share_flow_log_service.dart';

class PostShareTargetsSheet extends StatefulWidget {
  final Map<String, dynamic> postPayload;
  final Future<void> Function()? onShareSent;

  const PostShareTargetsSheet({
    super.key,
    required this.postPayload,
    this.onShareSent,
  });

  @override
  State<PostShareTargetsSheet> createState() => _PostShareTargetsSheetState();
}

class _PostShareTargetsSheetState extends State<PostShareTargetsSheet> {
  final ChatService _chatService = ChatService();
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _friendSearchController = TextEditingController();
  final GlobalKey _friendSearchRegionKey = GlobalKey();
  late final Future<Map<String, List<Map<String, dynamic>>>>
      _shareTargetsFuture;

  bool _isSending = false;
  String _friendSearchQuery = '';

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

  bool _tapHitsFriendSearchRegion(PointerDownEvent event) {
    final regionContext = _friendSearchRegionKey.currentContext;
    if (regionContext == null) {
      return false;
    }
    final renderObject = regionContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }

    final localPosition = renderObject.globalToLocal(event.position);
    final size = renderObject.size;
    return localPosition.dx >= 0 &&
        localPosition.dy >= 0 &&
        localPosition.dx <= size.width &&
        localPosition.dy <= size.height;
  }

  void _dismissKeyboardOnBackgroundTap(PointerDownEvent event) {
    if (_tapHitsEditable(event) || _tapHitsFriendSearchRegion(event)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _shareTargetsFuture = _chatService.fetchPostShareTargets();
    _friendSearchController.addListener(_handleFriendSearchChanged);
  }

  void _handleFriendSearchChanged() {
    final nextQuery = _friendSearchController.text.trim();
    if (nextQuery == _friendSearchQuery) {
      return;
    }
    setState(() {
      _friendSearchQuery = nextQuery;
    });
  }

  bool _friendMatchesSearch(Map<String, dynamic> target) {
    final rawQuery = _friendSearchQuery.trim().toLowerCase();
    if (rawQuery.isEmpty) {
      return true;
    }

    final normalizedQuery =
        rawQuery.startsWith('@') ? rawQuery.substring(1) : rawQuery;

    String normalizedValue(dynamic value) {
      final text = value?.toString().trim().toLowerCase() ?? '';
      if (text.startsWith('@')) {
        return text.substring(1);
      }
      return text;
    }

    final candidates = <String>{
      normalizedValue(target['username']),
      normalizedValue(target['handle']),
      normalizedValue(target['name']),
      normalizedValue(target['userId']),
    }..removeWhere((value) => value.isEmpty);

    for (final candidate in candidates) {
      if (candidate.contains(normalizedQuery)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _sendAfterClosingSheet(
    Map<String, dynamic> target,
    String note,
  ) async {
    final targetType = (target['type'] as String? ?? '').trim();
    final targetName = (target['name'] as String? ?? '').trim();
    final postId = (widget.postPayload['postId'] as String? ?? '').trim();
    if (targetType.isEmpty) {
      await ShareFlowLogService.log(
        'TARGET_SEND_ABORT_EMPTY_TYPE',
        data: <String, Object?>{'postId': postId, 'targetName': targetName},
      );
      return false;
    }

    await ShareFlowLogService.log(
      'TARGET_SEND_CONFIRMED',
      data: <String, Object?>{
        'postId': postId,
        'targetType': targetType,
        'targetName': targetName,
        'noteLength': note.length,
      },
    );
    if (!mounted) {
      return false;
    }

    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final sheetNavigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(rootNavigator.context);
    final postPayloadCopy = Map<String, dynamic>.from(widget.postPayload);

    if (mounted) {
      await ShareFlowLogService.log(
        'TARGETS_SHEET_CLOSE_REQUESTED',
        data: <String, Object?>{'postId': postId},
      );
      if (!mounted) {
        return false;
      }
      sheetNavigator.pop();
    }

    try {
      String chatId = '';
      if (targetType == 'friend') {
        final friendId = (target['userId'] as String? ?? '').trim();
        if (friendId.isEmpty) {
          await ShareFlowLogService.log(
            'TARGET_SEND_INVALID_FRIEND_ID',
            data: <String, Object?>{'postId': postId, 'targetName': targetName},
          );
          throw Exception('לא נמצא מזהה חבר');
        }
        final friendName = (target['name'] as String? ?? '').trim();
        final friendAvatar = (target['avatarUrl'] as String? ?? '').trim();
        await ShareFlowLogService.log(
          'TARGET_SEND_FIND_OR_CREATE_CHAT_START',
          data: <String, Object?>{'postId': postId, 'friendId': friendId},
        );
        chatId = await _chatService.findOrCreateDirectChat(
          otherUserId: friendId,
          otherDisplayName: friendName,
          otherAvatarUrl: friendAvatar,
        );
        await ShareFlowLogService.log(
          'TARGET_SEND_FIND_OR_CREATE_CHAT_DONE',
          data: <String, Object?>{'postId': postId, 'chatId': chatId},
        );
      } else {
        chatId = (target['chatId'] as String? ?? '').trim();
        await ShareFlowLogService.log(
          'TARGET_SEND_GROUP_CHAT_RESOLVED',
          data: <String, Object?>{'postId': postId, 'chatId': chatId},
        );
      }

      if (chatId.isEmpty) {
        await ShareFlowLogService.log(
          'TARGET_SEND_ABORT_EMPTY_CHAT',
          data: <String, Object?>{'postId': postId, 'targetName': targetName},
        );
        throw Exception('לא נמצאה שיחה תקינה לשליחה');
      }

      await ShareFlowLogService.log(
        'TARGET_SEND_MESSAGE_START',
        data: <String, Object?>{'postId': postId, 'chatId': chatId},
      );
      await _chatService.sendPostMessage(
        chatId: chatId,
        postPayload: postPayloadCopy,
        note: note,
      );
      await ShareFlowLogService.log(
        'TARGET_SEND_MESSAGE_SUCCESS',
        data: <String, Object?>{'postId': postId, 'chatId': chatId},
      );

      if (widget.onShareSent != null) {
        try {
          await widget.onShareSent!();
        } catch (callbackError) {
          await ShareFlowLogService.log(
            'TARGET_SEND_SUCCESS_CALLBACK_FAILED',
            data: <String, Object?>{
              'postId': postId,
              'chatId': chatId,
              'error': callbackError,
            },
          );
        }
      }

      messenger?.showSnackBar(
        const SnackBar(content: Text('הפוסט נשלח בהצלחה')),
      );
    } catch (error) {
      await ShareFlowLogService.log(
        'TARGET_SEND_MESSAGE_FAILURE',
        data: <String, Object?>{'postId': postId, 'error': error},
      );
      messenger?.showSnackBar(
        SnackBar(content: Text('שליחה נכשלה: $error')),
      );
    }

    return true;
  }

  Future<void> _sendToTarget(
    Map<String, dynamic> target, {
    required String note,
  }) async {
    if (_isSending) return;

    _isSending = true;
    await ShareFlowLogService.log(
      'TARGET_SEND_STARTED',
      data: <String, Object?>{
        'postId': (widget.postPayload['postId'] as String? ?? '').trim(),
        'targetType': (target['type'] as String? ?? '').trim(),
        'targetName': (target['name'] as String? ?? '').trim(),
      },
    );
    final didCloseSheet = await _sendAfterClosingSheet(target, note);
    if (!didCloseSheet) {
      _isSending = false;
    }
  }

  Future<void> _openNoteComposer(Map<String, dynamic> target) async {
    final targetName = (target['name'] as String? ?? 'יעד').trim();
    _noteController.clear();
    await ShareFlowLogService.log(
      'TARGET_NOTE_DIALOG_OPEN',
      data: <String, Object?>{
        'postId': (widget.postPayload['postId'] as String? ?? '').trim(),
        'targetName': targetName,
      },
    );
    if (!mounted) {
      _isSending = false;
      return;
    }

    final note = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (sheetContext) {
        final isLight = Theme.of(sheetContext).brightness == Brightness.light;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor:
                isLight ? const Color(0xFFF8FBFF) : const Color(0xFF111C31),
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: Text(
              'שליחה אל $targetName',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: TextField(
              controller: _noteController,
              onTapOutside: (_) {},
              textAlign: TextAlign.right,
              maxLines: 3,
              autofocus: true,
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
              ),
              decoration: InputDecoration(
                hintText: 'הודעה נלווית לפני שליחה (אופציונלי)',
                hintStyle: TextStyle(
                  color: isLight ? const Color(0xFF6E7A94) : Colors.white54,
                ),
                filled: true,
                fillColor:
                    isLight ? const Color(0xFFEFF5FF) : const Color(0xFF1B2A46),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: (isLight
                            ? const Color(0xFF8FB7FF)
                            : const Color(0xFF46D3FF))
                        .withValues(alpha:  0.28),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: (isLight
                            ? const Color(0xFF8FB7FF)
                            : const Color(0xFF46D3FF))
                        .withValues(alpha:  0.28),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: isLight
                        ? const Color(0xFF8B9CFF)
                        : const Color(0xFF8C62FF),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    _isSending ? null : () => Navigator.pop(sheetContext),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                onPressed: _isSending
                    ? null
                    : () => Navigator.pop(
                          sheetContext,
                          _noteController.text.trim(),
                        ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isLight
                      ? const Color(0xFFE0EAFF)
                      : const Color(0xFF8C62FF),
                  foregroundColor: isLight ? Colors.black : Colors.white,
                ),
                child: const Text('שלח'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted || note == null) {
      _isSending = false;
      await ShareFlowLogService.log(
        'TARGET_NOTE_DIALOG_CANCELLED',
        data: <String, Object?>{
          'postId': (widget.postPayload['postId'] as String? ?? '').trim(),
          'targetName': targetName,
        },
      );
      return;
    }

    await ShareFlowLogService.log(
      'TARGET_NOTE_DIALOG_SUBMIT',
      data: <String, Object?>{
        'postId': (widget.postPayload['postId'] as String? ?? '').trim(),
        'targetName': targetName,
        'noteLength': note.length,
      },
    );
    await _sendToTarget(target, note: note);
  }

  Widget _targetTile(Map<String, dynamic> target) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final name = (target['name'] as String? ?? 'ללא שם').trim();
    final avatarUrl = (target['avatarUrl'] as String? ?? '').trim();
    final targetType = (target['type'] as String? ?? '').trim();
    final subtitle = targetType == 'group' ? 'קבוצה' : 'חבר';

    return ListTile(
      onTap: _isSending ? null : () => _openNoteComposer(target),
      leading: CircleAvatar(
        backgroundColor:
            isLight ? const Color(0xFFDDE9FF) : const Color(0xFF24334D),
        backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
        child: avatarUrl.isEmpty
            ? Text(
                name.isNotEmpty ? name.characters.first : '?',
                style: TextStyle(color: isLight ? Colors.black : Colors.white),
              )
            : null,
      ),
      title: Text(
        name,
        style: TextStyle(
          color: isLight ? Colors.black : Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: isLight ? Colors.black54 : Colors.white60,
        ),
      ),
      tileColor: isLight
          ? const Color(0xFFF0F6FF).withValues(alpha:  0.95)
          : const Color(0xFF1A2438).withValues(alpha:  0.72),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: isLight ? const Color(0xFF759BFF) : const Color(0xFF9EDBFF),
      ),
    );
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _friendSearchController
      ..removeListener(_handleFriendSearchChanged)
      ..dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SafeArea(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _dismissKeyboardOnBackgroundTap,
        child: Container(
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isLight
                ? const [Color(0xFFFAFCFF), Color(0xFFECF3FF)]
                : [
                    const Color(0xFF0D172A).withValues(alpha:  0.98),
                    const Color(0xFF1B1635).withValues(alpha:  0.98),
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: (isLight
                        ? const Color(0xFF8FB7FF)
                        : const Color(0xFF9EDBFF))
                    .withValues(alpha:  0.55),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'שלח פוסט לחברים או לקבוצות',
              style: TextStyle(
                color: isLight ? Colors.black : const Color(0xFFEAF4FF),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              key: _friendSearchRegionKey,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _friendSearchController,
                onTapOutside: (_) {},
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  hintText: 'חפש חבר לפי שם משתמש',
                  hintStyle: TextStyle(
                    color: isLight
                        ? const Color(0xFF6A7894)
                        : const Color(0xFFA9B7D3),
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: isLight
                        ? const Color(0xFF5C75B9)
                        : const Color(0xFF9EDBFF),
                  ),
                  filled: true,
                  fillColor: isLight
                      ? const Color(0xFFEFF5FF)
                      : const Color(0xFF18233A),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: (isLight
                              ? const Color(0xFF8FB7FF)
                              : const Color(0xFF46D3FF))
                          .withValues(alpha:  0.28),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: (isLight
                              ? const Color(0xFF8FB7FF)
                              : const Color(0xFF46D3FF))
                          .withValues(alpha:  0.28),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: isLight
                          ? const Color(0xFF8B9CFF)
                          : const Color(0xFF8C62FF),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<Map<String, List<Map<String, dynamic>>>>(
                future: _shareTargetsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(
                        color: isLight
                            ? const Color(0xFF7E63D8)
                            : const Color(0xFF9E7CFF),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'שגיאה בטעינת רשימת יעדים',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                        ),
                      ),
                    );
                  }

                  final data = snapshot.data ??
                      const <String, List<Map<String, dynamic>>>{};
                  final friends =
                      data['friends'] ?? const <Map<String, dynamic>>[];
                  final filteredFriends = friends
                      .where(_friendMatchesSearch)
                      .toList(growable: false);
                  final groups =
                      data['groups'] ?? const <Map<String, dynamic>>[];

                  if (friends.isEmpty && groups.isEmpty) {
                    return Center(
                      child: Text(
                        'לא נמצאו חברים או קבוצות לשליחה',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                        ),
                      ),
                    );
                  }

                  return ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      if (friends.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                          child: Text(
                            'חברים',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF5D84F5)
                                  : const Color(0xFF9EDBFF),
                              fontWeight: FontWeight.w800,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        if (filteredFriends.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                            child: Text(
                              'לא נמצאו חברים בשם המשתמש שחיפשת',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF5F6D89)
                                    : Colors.white70,
                              ),
                            ),
                          )
                        else
                          ...filteredFriends.map((target) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _targetTile(target),
                              )),
                        const SizedBox(height: 6),
                      ],
                      if (groups.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                          child: Text(
                            'קבוצות',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF5D84F5)
                                  : const Color(0xFF9EDBFF),
                              fontWeight: FontWeight.w800,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        ...groups.map((target) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _targetTile(target),
                            )),
                      ],
                    ],
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
