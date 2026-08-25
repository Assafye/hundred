import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'group_details_screen.dart';
import 'post_media_utils.dart';
import 'post_detail_view.dart';
import 'services/chat_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'services/share_flow_log_service.dart';
import 'user_profile_screen.dart';
import 'models/post_media_item.dart';
import 'widgets/group_avatar.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

class ChatRoomScreen extends StatefulWidget {
  final String chatName;
  final String? avatarUrl;
  final String chatId;
  final bool? isDirectChat;
  final String? directOtherUserId;

  const ChatRoomScreen({
    super.key,
    required this.chatName,
    this.avatarUrl,
    required this.chatId,
    this.isDirectChat,
    this.directOtherUserId,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ReplyTarget {
  final String messageId;
  final String senderId;
  final String senderName;
  final String textPreview;
  final String messageType;

  const _ReplyTarget({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.textPreview,
    required this.messageType,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'text': textPreview,
      'messageType': messageType,
    };
  }
}

class _PendingChatMedia {
  _PendingChatMedia({
    required this.file,
    required this.isVideo,
  });

  final XFile file;
  final bool isVideo;
  final TextEditingController captionController = TextEditingController();

  void dispose() {
    captionController.dispose();
  }
}

class _ChatRoomScreenState extends State<ChatRoomScreen>
  with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final ChatService _chatService = ChatService();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  final Map<String, int> _visibleMessageIndexById = <String, int>{};
  String? _lastReadMarkerKey;
  String? _lastRenderedLatestMessageId;
  int _lastRenderedMessageCount = 0;
  bool _didInitialAutoScroll = false;
  bool _didResolveInitialAnchor = false;
  bool _stickToBottom = true;
  bool _hasUserScrolled = false;
  String? _highlightedMessageId;
  final Map<String, Map<String, String>> _senderSummaries =
      <String, Map<String, String>>{};
  final Set<String> _loadingSenderIds = <String>{};
  final Map<String, Future<bool>> _sharedPostDeletedCache =
      <String, Future<bool>>{};
  bool _isSendingMedia = false;
  bool _isSendingText = false;
  String _latestDirectOtherUid = '';
  _ReplyTarget? _replyTarget;
  final GlobalKey _attachmentButtonKey = GlobalKey();
  final Object _composerTapRegionGroupId = Object();
  OverlayEntry? _attachmentMenuOverlay;
  bool _isClosingAttachmentMenu = false;
  late final AnimationController _attachmentMenuController;
  late final Animation<double> _bottomBubbleScale;
  late final Animation<double> _bottomBubbleOpacity;
  late final Animation<double> _topBubbleScale;
  late final Animation<double> _topBubbleOpacity;

  bool _isLightMode(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light;
  }

  void _showMediaPickerError(Object error) {
    if (!mounted) return;

    var message = 'לא ניתן לפתוח מדיה כרגע. נסה שוב.';
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      if (code.contains('camera_access_denied') ||
          code.contains('camera_access_restricted')) {
        message =
            'אין הרשאת מצלמה באייפון. אפשר לאשר בהגדרות > Hundred > Camera.';
      } else if (code.contains('photo_access_denied') ||
          code.contains('photo_access_restricted')) {
        message =
            'אין הרשאת גלריה באייפון. אפשר לאשר בהגדרות > Hundred > Photos.';
      } else if (code.contains('microphone_access_denied') ||
          code.contains('microphone_access_restricted')) {
        message =
            'אין הרשאת מיקרופון באייפון. אפשר לאשר בהגדרות > Hundred > Microphone.';
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void initState() {
    super.initState();
    _attachmentMenuController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
    );
    _bottomBubbleScale = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(
        parent: _attachmentMenuController,
        curve: const Interval(0.0, 0.58, curve: Curves.easeOutBack),
      ),
    );
    _bottomBubbleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _attachmentMenuController,
        curve: const Interval(0.0, 0.42, curve: Curves.easeOut),
      ),
    );
    _topBubbleScale = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(
        parent: _attachmentMenuController,
        curve: const Interval(0.28, 1.0, curve: Curves.easeOutBack),
      ),
    );
    _topBubbleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _attachmentMenuController,
        curve: const Interval(0.28, 0.82, curve: Curves.easeOut),
      ),
    );
    KeyboardDismissController.suspend();
    _scrollController.addListener(_handleScrollActivity);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markChatAsReadFromServer();
    });
  }

  void _handleScrollActivity() {
    if (!_scrollController.hasClients) {
      return;
    }

    _stickToBottom = _isNearBottom(threshold: 56);
  }

  bool _handleUserScrollNotification(UserScrollNotification notification) {
    if (notification.direction == ScrollDirection.idle) {
      return false;
    }

    _hasUserScrolled = true;
    _stickToBottom = _isNearBottom(threshold: 56);
    return false;
  }

  Future<void> _markChatAsReadFromServer() async {
    try {
      await _chatService.markChatAsReadToLatestMessage(chatId: widget.chatId);
    } catch (_) {
      // Keep navigation and rendering responsive even on transient write errors.
    }
  }

  bool _isDirectChat(Map<String, dynamic>? chatData) {
    final isPublic = (chatData?['isPublic'] as bool?) ?? false;
    final participants = List<String>.from(
      (chatData?['participants'] as List<dynamic>?) ?? const <String>[],
    );
    return widget.isDirectChat ??
        ((chatData?['isDirect'] as bool?) ??
            (!isPublic && participants.length == 2));
  }

  String _directChatOtherUid(Map<String, dynamic>? chatData) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final participants = List<String>.from(
      (chatData?['participants'] as List<dynamic>?) ?? const <String>[],
    );

    for (final participant in participants) {
      final uid = participant.trim();
      if (uid.isNotEmpty && uid != currentUid) {
        return uid;
      }
    }
    return '';
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSendingText) return;

    // Keep the keyboard open when send is tapped.
    if (!_inputFocusNode.hasFocus) {
      _inputFocusNode.requestFocus();
    }

    final replyTarget = _replyTarget;

    setState(() {
      _isSendingText = true;
    });

    try {
      final effectiveChatId = await _chatService.sendMessage(
        chatId: widget.chatId,
        text: text,
        replyTo: replyTarget?.toMap(),
        directOtherUserIdHint: (widget.isDirectChat ?? false)
            ? (_latestDirectOtherUid.trim().isNotEmpty
                ? _latestDirectOtherUid
                : (widget.directOtherUserId ?? ''))
            : null,
        directOtherDisplayNameHint:
            (widget.isDirectChat ?? false) ? widget.chatName : null,
        directOtherAvatarUrlHint:
            (widget.isDirectChat ?? false) ? (widget.avatarUrl ?? '') : null,
      );
      if (!mounted) return;

      _controller.clear();
      setState(() {
        _replyTarget = null;
      });
      if (mounted) {
        _inputFocusNode.requestFocus();
      }

      _scheduleScrollToBottom(force: true);

      if ((widget.isDirectChat ?? false) && effectiveChatId != widget.chatId) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatRoomScreen(
              chatName: widget.chatName,
              avatarUrl: widget.avatarUrl,
              chatId: effectiveChatId,
              isDirectChat: true,
              directOtherUserId: widget.directOtherUserId,
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final message =
          error is FirebaseAuthException && error.code == 'blocked-user'
              ? 'לא ניתן לשלוח הודעה: קיימת חסימה בין המשתמשים.'
              : error is TimeoutException
                  ? 'שליחת ההודעה אורכת יותר מדי זמן. נסה שוב.'
                  : 'שליחת הודעה נכשלה: $error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isSendingText = false;
      });
    }
  }

  Future<void> _closeAttachmentMenu({bool immediate = false}) async {
    final overlayEntry = _attachmentMenuOverlay;
    if (overlayEntry == null) {
      return;
    }
    if (_isClosingAttachmentMenu) {
      return;
    }

    _isClosingAttachmentMenu = true;
    try {
      if (!immediate &&
          _attachmentMenuController.status != AnimationStatus.dismissed) {
        await _attachmentMenuController.reverse();
      }
      if (_attachmentMenuOverlay == overlayEntry) {
        overlayEntry.remove();
        _attachmentMenuOverlay = null;
      }
    } finally {
      _isClosingAttachmentMenu = false;
    }
  }

  Widget _buildAttachmentBubble({
    required bool isLight,
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () async {
          await onTap();
          if (mounted) {
            await _closeAttachmentMenu();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isLight
                ? const Color(0xFFFFFFFF).withValues(alpha: 0.9)
                : const Color(0xFF1E2632).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isLight
                  ? const Color(0xFF8FD2F6)
                  : const Color(0xFF53C1F9).withValues(alpha: 0.22),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              Icon(
                icon,
                size: 18,
                color:
                    isLight ? const Color(0xFF4DBEEA) : const Color(0xFF9E7CFF),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: isLight ? const Color(0xFF34425D) : Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAttachmentActions() {
    if (_attachmentMenuOverlay != null) {
      unawaited(_closeAttachmentMenu());
      return;
    }

    final buttonContext = _attachmentButtonKey.currentContext;
    final overlayState = Overlay.of(context);
    if (buttonContext == null || overlayState.mounted == false) {
      return;
    }

    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (buttonBox == null || overlayBox == null) {
      return;
    }

    final isLight = _isLightMode(context);
    final buttonTopLeft = buttonBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final buttonRect = buttonTopLeft & buttonBox.size;
    final overlaySize = overlayBox.size;
    const menuWidth = 136.0;
    const menuHeight = 116.0;
    const right = 0.0;
    final top = (buttonRect.top - menuHeight - 10).clamp(
      12.0,
      overlaySize.height - menuHeight - 12.0,
    );

    _attachmentMenuOverlay = OverlayEntry(
      builder: (overlayContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  unawaited(_closeAttachmentMenu());
                },
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              right: right,
              top: top,
              width: menuWidth,
              child: TextFieldTapRegion(
                groupId: _composerTapRegionGroupId,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: FadeTransition(
                        opacity: _topBubbleOpacity,
                        child: ScaleTransition(
                          alignment: Alignment.bottomRight,
                          scale: _topBubbleScale,
                          child: _buildAttachmentBubble(
                            isLight: isLight,
                            icon: Icons.photo_library_rounded,
                            label: 'גלריה',
                            onTap: _openGalleryPicker,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FadeTransition(
                        opacity: _bottomBubbleOpacity,
                        child: ScaleTransition(
                          alignment: Alignment.bottomRight,
                          scale: _bottomBubbleScale,
                          child: _buildAttachmentBubble(
                            isLight: isLight,
                            icon: Icons.photo_camera_rounded,
                            label: 'מצלמה',
                            onTap: _openCameraPicker,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(_attachmentMenuOverlay!);
    _attachmentMenuController
      ..stop()
      ..reset()
      ..forward();
  }

  Future<void> _openGalleryPicker() async {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final images = await _imagePicker.pickMultiImage(imageQuality: 85);
      if (images.isEmpty) return;
      final limited = images.take(10).toList(growable: false);
      final drafts = limited
          .map((file) => _PendingChatMedia(file: file, isVideo: false))
          .toList(growable: false);
      await _openMediaCaptionSheet(drafts);
    } catch (error) {
      _showMediaPickerError(error);
    }
  }

  Future<void> _openCameraPicker() async {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final image = await _imagePicker.pickImage(source: ImageSource.camera);
      if (image == null) return;
      await _openMediaCaptionSheet(
        <_PendingChatMedia>[_PendingChatMedia(file: image, isVideo: false)],
      );
    } catch (error) {
      _showMediaPickerError(error);
    }
  }

  Future<void> _openMediaCaptionSheet(List<_PendingChatMedia> drafts) async {
    if (drafts.isEmpty) return;

    final isLight = _isLightMode(context);
    final shouldSend = await showModalBottomSheet<bool>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 12,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'כיתוב למדיה',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('ביטול'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: const Text('שליחה'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: drafts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final draft = drafts[index];
                      final path = draft.file.path;
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isLight
                              ? const Color(0xFFF2F7FF)
                              : const Color(0xFF16263D),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 56,
                                height: 56,
                                child: draft.isVideo
                                    ? Container(
                                        color: Colors.black26,
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.play_circle_fill_rounded,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      )
                                    : Image.file(
                                        File(path),
                                        fit: BoxFit.cover,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: draft.captionController,
                                maxLines: 2,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'הוסף כיתוב למדיה...',
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (shouldSend == true) {
      await _sendMediaBatch(drafts);
    }

    for (final draft in drafts) {
      draft.dispose();
    }
  }

  Future<void> _openSharedPost(Map<String, dynamic> postPayload) async {
    final postId = (postPayload['postId'] as String? ?? '').trim();
    if (postId.isEmpty) {
      return;
    }

    final isDeleted = await _isSharedPostDeleted(postId);
    if (!mounted) {
      return;
    }
    if (isDeleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('פוסט זה נמחק')),
      );
      return;
    }

    final postDoc =
        await FirebaseFirestore.instance.collection('posts').doc(postId).get();

    if (!mounted) {
      return;
    }

    Map<String, dynamic> postData;
    if (postDoc.exists) {
      postData = <String, dynamic>{
        'id': postDoc.id,
        ...?postDoc.data(),
      };
    } else {
      postData = <String, dynamic>{
        'id': postId,
        'postId': postId,
        'title': (postPayload['title'] as String? ?? '').trim(),
        'description': (postPayload['description'] as String? ?? '').trim(),
        'imageUrl': (postPayload['imageUrl'] as String? ?? '').trim(),
        'authorId': (postPayload['authorId'] as String? ?? '').trim(),
        'category': (postPayload['category'] as String? ?? '').trim(),
        'subCategory': (postPayload['subCategory'] as String? ?? '').trim(),
      };
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: <Map<String, dynamic>>[postData],
          initialIndex: 0,
        ),
      ),
    );
  }

  Future<bool> _isSharedPostDeleted(String postId) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      return Future<bool>.value(true);
    }

    final cached = _sharedPostDeletedCache[normalizedPostId];
    if (cached != null) {
      return cached;
    }

    final future = FirebaseFirestore.instance
        .collection('posts')
        .doc(normalizedPostId)
        .get()
        .then((doc) {
      if (!doc.exists) {
        return true;
      }

      final data = doc.data() ?? const <String, dynamic>{};
      final isDeleted = (data['isDeleted'] as bool?) ?? false;
      final status = (data['status'] as String? ?? '').trim().toLowerCase();
      return isDeleted || status == 'deleted';
    }).catchError((_) {
      _sharedPostDeletedCache.remove(normalizedPostId);
      return false;
    });

    _sharedPostDeletedCache[normalizedPostId] = future;
    return future;
  }

  Future<void> _openUserProfileFromChat(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty || !mounted) {
      return;
    }

    final resolvedName =
        (_senderSummaries[normalizedUid]?['name'] ?? '').trim();
    if (_isDeletedProfileLabel(resolvedName)) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          uid: normalizedUid,
          currentBottomIndex: 3,
          openedFromDirectChat: widget.isDirectChat == true,
        ),
      ),
    );
  }

  bool _isDeletedProfileLabel(String name) {
    final normalized = name.trim();
    return normalized == 'פרופיל מחוק' || normalized == 'משתמש מחוק';
  }

  Future<String> _resolveSharedPreviewUrl(
      Map<String, dynamic> postPayload) async {
    String readPayload(String key) =>
        (postPayload[key] as String? ?? '').trim();

    final payloadMediaUrls =
        (postPayload['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
    final payloadMediaItems =
        (postPayload['mediaItems'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);

    final directCandidates = <String>[
      readPayload('thumbnailUrl'),
      readPayload('videoThumbnailUrl'),
      readPayload('imageUrl'),
      readPayload('mediaUrl'),
      ...payloadMediaUrls,
    ].where((value) => value.isNotEmpty).toList(growable: false);

    if (directCandidates.isNotEmpty) {
      return directCandidates.first;
    }

    for (final item in payloadMediaItems) {
      final thumbnail =
          (item['thumbnailUrl'] as String? ?? '').trim().isNotEmpty
              ? (item['thumbnailUrl'] as String).trim()
              : (item['videoThumbnailUrl'] as String? ?? '').trim();
      if (thumbnail.isNotEmpty) {
        return thumbnail;
      }
    }

    for (final item in payloadMediaItems) {
      final url = (item['url'] as String? ?? '').trim();
      if (url.isNotEmpty && !isVideoMediaUrl(url)) {
        return url;
      }
    }

    final postId = readPayload('postId');
    if (postId.isEmpty) {
      return '';
    }

    try {
      final postDoc = await FirebaseFirestore.instance
          .collection('posts')
          .doc(postId)
          .get();
      if (!postDoc.exists) {
        return '';
      }

      final data = postDoc.data() ?? <String, dynamic>{};
      final fallback = <String>[
        (data['thumbnailUrl'] as String? ?? '').trim(),
        (data['videoThumbnailUrl'] as String? ?? '').trim(),
        (data['imageUrl'] as String? ?? '').trim(),
        (data['mediaUrl'] as String? ?? '').trim(),
      ].where((value) => value.isNotEmpty).toList(growable: false);

      String firstFromMediaCollections() {
        final mediaUrls =
            (data['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
                .whereType<String>()
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(growable: false);

        if (mediaUrls.isNotEmpty) {
          return mediaUrls.first;
        }

        final mediaItems =
            (data['mediaItems'] as List<dynamic>? ?? const <dynamic>[])
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList(growable: false);

        for (final item in mediaItems) {
          final thumbnail =
              (item['thumbnailUrl'] as String? ?? '').trim().isNotEmpty
                  ? (item['thumbnailUrl'] as String).trim()
                  : (item['videoThumbnailUrl'] as String? ?? '').trim();
          if (thumbnail.isNotEmpty) {
            return thumbnail;
          }
        }

        for (final item in mediaItems) {
          final url = (item['url'] as String? ?? '').trim();
          if (url.isNotEmpty && !isVideoMediaUrl(url)) {
            return url;
          }
        }

        return '';
      }

      if (fallback.isNotEmpty) {
        return fallback.first;
      }

      return firstFromMediaCollections();
    } catch (_) {
      return '';
    }
  }

  Widget _buildSharedPostPreview({
    required Map<String, dynamic> postPayload,
    required bool isMe,
  }) {
    final isLight = _isLightMode(context);
    final title = (postPayload['title'] as String? ?? '').trim();
    final description = (postPayload['description'] as String? ?? '').trim();
    final imageUrl = (postPayload['imageUrl'] as String? ?? '').trim();
    final thumbnailUrl = (postPayload['thumbnailUrl'] as String? ?? '').trim();
    final videoThumbnailUrl =
        (postPayload['videoThumbnailUrl'] as String? ?? '').trim();
    final category = (postPayload['category'] as String? ?? '').trim();
    final postId = (postPayload['postId'] as String? ?? '').trim();
    final initialPreviewUrl = <String>[
      thumbnailUrl,
      videoThumbnailUrl,
      imageUrl,
      (postPayload['mediaUrl'] as String? ?? '').trim(),
      ...(postPayload['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
          .map((value) => value.toString().trim()),
    ].where((value) => value.isNotEmpty).toList(growable: false);
    final previewUrl = initialPreviewUrl.isEmpty ? '' : initialPreviewUrl.first;
    final body = Container(
      width: 168,
      decoration: BoxDecoration(
        color: isLight
            ? (isMe ? const Color(0xFFDCE9FF) : const Color(0xFFEFF5FF))
            : (isMe ? const Color(0xFF262C43) : const Color(0xFF1A2435)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLight
              ? const Color(0xFF6B4BB6).withValues(alpha: 0.65)
              : const Color(0xFF46D3FF).withValues(alpha: 0.26),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<String>(
            future: previewUrl.isNotEmpty
                ? Future<String>.value(previewUrl)
                : _resolveSharedPreviewUrl(postPayload),
            builder: (context, snapshot) {
              final resolvedPreview = (snapshot.data ?? '').trim();
              if (resolvedPreview.isEmpty) {
                return ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                  child: Container(
                    height: 114,
                    color: isLight
                        ? const Color(0xFFF6FAFF)
                        : const Color(0xFF111927),
                    child: Icon(
                      Icons.image_rounded,
                      color: isLight ? const Color(0xFF7A87A3) : Colors.white54,
                    ),
                  ),
                );
              }

              if (isVideoMediaUrl(resolvedPreview)) {
                return FutureBuilder<Uint8List?>(
                  future: buildVideoPreviewBytesFromSource(resolvedPreview),
                  builder: (context, bytesSnapshot) {
                    final bytes = bytesSnapshot.data;
                    return ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14),
                      ),
                      child: Container(
                        height: 114,
                        color: isLight
                            ? const Color(0xFFF6FAFF)
                            : const Color(0xFF111927),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (bytes != null)
                              Image.memory(bytes, fit: BoxFit.cover)
                            else
                              Container(
                                color: isLight
                                    ? const Color(0xFFF6FAFF)
                                    : const Color(0xFF111927),
                              ),
                            Center(
                              child: Icon(
                                Icons.play_circle_fill_rounded,
                                color: isLight ? Colors.black54 : Colors.white,
                                size: 30,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              }

              return ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
                child: Container(
                  height: 114,
                  decoration: BoxDecoration(
                    color: isLight
                        ? const Color(0xFFF6FAFF)
                        : const Color(0xFF111927),
                    image: DecorationImage(
                      image: NetworkImage(resolvedPreview),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isNotEmpty ? title : 'פוסט משותף',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF5D6B87) : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (category.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight
                          ? const Color(0xFF6B4BB6)
                          : const Color(0xFF9EDBFF),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (postId.isEmpty) {
      return body;
    }

    return FutureBuilder<bool>(
      future: _isSharedPostDeleted(postId),
      builder: (context, snapshot) {
        final isDeleted = snapshot.data ?? false;
        if (isDeleted) {
          return Container(
            width: 168,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isLight
                  ? (isMe ? const Color(0xFFDCE9FF) : const Color(0xFFEFF5FF))
                  : (isMe ? const Color(0xFF262C43) : const Color(0xFF1A2435)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isLight
                    ? const Color(0xFF6B4BB6).withValues(alpha: 0.65)
                    : const Color(0xFF46D3FF).withValues(alpha: 0.26),
              ),
            ),
            child: Text(
              'פוסט זה נמחק',
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: isLight ? const Color(0xFF5D6B87) : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        }

        return GestureDetector(
          onTap: () => _openSharedPost(postPayload),
          child: body,
        );
      },
    );
  }

  void _scheduleScrollToBottom({bool force = false, int retries = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        if (force && retries < 6) {
          _scheduleScrollToBottom(force: true, retries: retries + 1);
        }
        return;
      }

      final maxExtent = _scrollController.position.maxScrollExtent;
      if (force && maxExtent <= 0 && retries < 6) {
        _scheduleScrollToBottom(force: true, retries: retries + 1);
        return;
      }
      if (!force && !_stickToBottom) {
        ShareFlowLogService.log(
          'CHAT_SCROLL_SKIP_AUTO',
          data: <String, Object?>{
            'reason': 'not_sticky',
            'force': force,
            'stickToBottom': _stickToBottom,
            'nearBottom': _isNearBottom(threshold: 56),
            'didInitialAutoScroll': _didInitialAutoScroll,
          },
        );
        return;
      }

      if (!force && _didInitialAutoScroll && !_isNearBottom(threshold: 56)) {
        ShareFlowLogService.log(
          'CHAT_SCROLL_SKIP_AUTO',
          data: <String, Object?>{
            'reason': 'user_not_near_bottom',
            'force': force,
            'stickToBottom': _stickToBottom,
            'nearBottom': _isNearBottom(threshold: 56),
            'didInitialAutoScroll': _didInitialAutoScroll,
          },
        );
        return;
      }

      ShareFlowLogService.log(
        'CHAT_SCROLL_AUTO_TO_BOTTOM',
        data: <String, Object?>{
          'force': force,
          'stickToBottom': _stickToBottom,
          'nearBottom': _isNearBottom(threshold: 56),
        },
      );

      _scrollController.animateTo(
        _scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  String _myLastReadMessageId(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> receipts,
    String myUid,
  ) {
    for (final receipt in receipts) {
      final data = receipt.data();
      final uid = (data['uid'] as String? ?? receipt.id).trim();
      if (uid != myUid) {
        continue;
      }
      return (data['lastReadMessageId'] as String? ?? '').trim();
    }
    return '';
  }

  void _restoreInitialAnchorToMessage(
    String messageId, {
    int retries = 0,
  }) {
    if (!mounted) {
      return;
    }

    final targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext == null) {
      if (retries < 10) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _restoreInitialAnchorToMessage(messageId, retries: retries + 1);
        });
      }
      return;
    }

    Scrollable.ensureVisible(
      targetContext,
      alignment: 0.14,
      duration: Duration.zero,
      curve: Curves.linear,
    );
  }

  void _resolveInitialAnchorIfNeeded({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> receiptDocs,
    required String myUid,
  }) {
    if (_didResolveInitialAnchor || docs.isEmpty || myUid.isEmpty) {
      return;
    }

    final lastReadMessageId = _myLastReadMessageId(receiptDocs, myUid);
    final hasLastReadInList = lastReadMessageId.isNotEmpty &&
        docs.any((doc) => doc.id == lastReadMessageId);

    if (hasLastReadInList) {
      _didResolveInitialAnchor = true;
      _didInitialAutoScroll = true;
      _hasUserScrolled = true;
      _stickToBottom = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreInitialAnchorToMessage(lastReadMessageId);
      });
      return;
    }

    _didResolveInitialAnchor = true;
    _didInitialAutoScroll = true;
    _stickToBottom = true;
    _scheduleScrollToBottom(force: true);
  }

  bool _isNearBottom({double threshold = 140}) {
    if (!_scrollController.hasClients) {
      return true;
    }

    final position = _scrollController.position;
    final distanceFromBottom = position.pixels - position.minScrollExtent;
    return distanceFromBottom <= threshold;
  }

  String _replyPreviewText(Map<String, dynamic> data) {
    final directText = (data['text'] as String? ?? '').trim();
    if (directText.isNotEmpty) {
      return directText;
    }

    final messageType =
        (data['messageType'] as String? ?? '').trim().toLowerCase();
    if (messageType == 'post' && data['post'] is Map) {
      final postPayload = Map<String, dynamic>.from(data['post'] as Map);
      final title = (postPayload['title'] as String? ?? '').trim();
      if (title.isNotEmpty) {
        return title;
      }
      final description = (postPayload['description'] as String? ?? '').trim();
      if (description.isNotEmpty) {
        return description;
      }
      return 'פוסט משותף';
    }

    return 'הודעה';
  }

  _ReplyTarget _buildReplyTarget({
    required String messageId,
    required Map<String, dynamic> messageData,
    required String senderName,
  }) {
    return _ReplyTarget(
      messageId: messageId,
      senderId: (messageData['senderId'] as String? ?? '').trim(),
      senderName: senderName.trim().isNotEmpty ? senderName.trim() : 'משתמש',
      textPreview: _replyPreviewText(messageData),
      messageType: (messageData['messageType'] as String? ?? 'text')
          .trim()
          .toLowerCase(),
    );
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(messageId, () => GlobalKey());
  }

  Future<bool> _tryEnsureMessageVisible(String messageId) async {
    final targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext == null) {
      return false;
    }

    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.2,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );

    return true;
  }

  Future<void> _scrollToMessageWithRetries(
    String targetMessageId, {
    String? fromMessageId,
    int attempt = 0,
  }) async {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }

    final becameVisible = await _tryEnsureMessageVisible(targetMessageId);
    if (becameVisible) {
      return;
    }

    if (attempt >= 10) {
      return;
    }

    final position = _scrollController.position;
    final targetIndex = _visibleMessageIndexById[targetMessageId];
    final sourceIndex = fromMessageId == null
        ? null
        : _visibleMessageIndexById[fromMessageId.trim()];

    double nextOffset;
    if (targetIndex != null &&
        sourceIndex != null &&
        targetIndex != sourceIndex) {
      const estimatedItemExtent = 132.0;
      final delta = targetIndex - sourceIndex;
      nextOffset = position.pixels + (delta * estimatedItemExtent);
    } else if (targetIndex != null && _visibleMessageIndexById.length > 1) {
      final fraction = targetIndex / (_visibleMessageIndexById.length - 1);
      nextOffset = position.minScrollExtent +
          (position.maxScrollExtent - position.minScrollExtent) * fraction;
    } else {
      nextOffset =
          attempt.isEven ? position.maxScrollExtent : position.minScrollExtent;
    }

    final clampedOffset = nextOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if ((clampedOffset - position.pixels).abs() < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return _scrollToMessageWithRetries(
        targetMessageId,
        fromMessageId: fromMessageId,
        attempt: attempt + 1,
      );
    }

    await _scrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    return _scrollToMessageWithRetries(
      targetMessageId,
      fromMessageId: fromMessageId,
      attempt: attempt + 1,
    );
  }

  Future<void> _scrollToMessage(String messageId,
      {String? fromMessageId}) async {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return;
    }

    await _scrollToMessageWithRetries(
      normalizedMessageId,
      fromMessageId: fromMessageId,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _highlightedMessageId = normalizedMessageId;
    });

    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted || _highlightedMessageId != normalizedMessageId) {
        return;
      }
      setState(() {
        _highlightedMessageId = null;
      });
    });
  }

  Widget _buildReplySnippet({
    required Map<String, dynamic> replyTo,
    required bool isMe,
    VoidCallback? onTap,
  }) {
    final isLight = _isLightMode(context);
    final senderName = (replyTo['senderName'] as String? ?? 'משתמש').trim();
    final text = (replyTo['text'] as String? ?? '').trim();
    final previewText = text.isNotEmpty ? text : 'הודעה';
    final borderColor = isMe
        ? const Color(0xFF6B4BB6).withValues(alpha: 0.42)
        : (isLight
            ? const Color(0xFF9E7CFF).withValues(alpha: 0.38)
            : const Color(0xFF53C1F9).withValues(alpha: 0.28));
    final backgroundColor = isMe
        ? Colors.white.withValues(alpha: 0.28)
        : (isLight
            ? const Color(0xFFF7FBFF)
            : const Color(0xFF152031).withValues(alpha: 0.9));
    final titleColor = isMe
        ? Colors.black.withValues(alpha: 0.78)
        : (isLight ? const Color(0xFF6B4BB6) : const Color(0xFF9EDBFF));
    final textColor = isMe
        ? Colors.black.withValues(alpha: 0.82)
        : (isLight ? const Color(0xFF34425D) : Colors.white70);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border(
              right: BorderSide(color: borderColor, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                senderName.isNotEmpty ? senderName : 'משתמש',
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: titleColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                previewText,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJoinAnnouncementBanner(Map<String, dynamic> messageData) {
    final isLight = _isLightMode(context);
    final displayName =
        (messageData['joinedDisplayName'] as String? ?? '').trim();
    final avatarUrl = ((messageData['senderAvatarUrl'] as String?) ?? '').trim();
    final text = ChatService.buildGroupJoinAnnouncementText(displayName);
    final avatar = CircleAvatar(
      radius: 14,
      backgroundColor: isLight ? const Color(0xFFDCE8FF) : const Color(0xFF2A3445),
      backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
      child: avatarUrl.isEmpty
          ? Icon(
              Icons.person_rounded,
              size: 15,
              color: isLight ? const Color(0xFF4C6FFF) : Colors.white70,
            )
          : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isLight ? const Color(0xFFF3F7FF) : const Color(0xFF1A2330),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isLight ? const Color(0xFFCFDBF1) : Colors.white12,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              avatar,
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF2F3E5D) : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble({
    required String messageId,
    required String text,
    required bool isMe,
    required String senderId,
    required String senderName,
    required String senderAvatarUrl,
    required String sentAt,
    required List<String> seenUserIds,
    required bool showSenderMeta,
    required bool isFirstInGroup,
    required bool isLastInGroup,
    required Map<String, dynamic> messageData,
  }) {
    final isLight = _isLightMode(context);
    final messageType =
        (messageData['messageType'] as String? ?? 'text').trim().toLowerCase();
    final eventType =
        (messageData['eventType'] as String? ?? '').trim().toLowerCase();
    if (messageType == 'system' && eventType == 'group_member_joined') {
      return _buildJoinAnnouncementBanner(messageData);
    }
    final isPostMessage = messageType == 'post';
    final isMediaMessage = messageType == 'media';
    final isAudioMessage = messageType == 'audio';
    final postPayload = isPostMessage && messageData['post'] is Map
        ? Map<String, dynamic>.from(messageData['post'] as Map)
        : const <String, dynamic>{};
    final mediaItems = isMediaMessage
        ? (messageData['mediaItems'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final normalizedText = text.trim();
    final hasPostCaption = isPostMessage && normalizedText.isNotEmpty;
    final replyTo = messageData['replyTo'] is Map
        ? Map<String, dynamic>.from(messageData['replyTo'] as Map)
        : const <String, dynamic>{};
    final hasReply = replyTo.isNotEmpty;
    final showUnifiedPostFlow = isPostMessage && !hasReply;
    final showBubbleShell =
        (!isPostMessage && !isMediaMessage && !isAudioMessage) || hasReply;
    final bg = isMe
        ? const Color(0xFF9E7CFF)
        : (isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1E2632));
    final fg = isMe
        ? (isLight ? Colors.black : Colors.white)
        : (isLight ? Colors.black : Colors.white);
    final isDeletedSender = _isDeletedProfileLabel(senderName);
    final avatar = CircleAvatar(
      radius: 13,
      backgroundColor:
          isLight ? const Color(0xFFDCE8FF) : const Color(0xFF2A3445),
      backgroundImage: (!isDeletedSender && senderAvatarUrl.isNotEmpty)
          ? NetworkImage(senderAvatarUrl)
          : null,
      child: isDeletedSender
          ? Icon(
              Icons.person_off_rounded,
              color: isLight ? const Color(0xFF6B7894) : Colors.white54,
              size: 14,
            )
          : senderAvatarUrl.isEmpty
              ? Text(
                  senderName.isNotEmpty ? senderName.characters.first : '?',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                )
              : null,
    );
    final bubbleRadius = BorderRadius.only(
      topLeft: Radius.circular(isMe ? 18 : (isFirstInGroup ? 18 : 8)),
      topRight: Radius.circular(isMe ? (isFirstInGroup ? 18 : 8) : 18),
      bottomLeft: Radius.circular(isMe ? 18 : (isLastInGroup ? 18 : 8)),
      bottomRight: Radius.circular(isMe ? (isLastInGroup ? 6 : 8) : 18),
    );
    const bubbleTextAlign = TextAlign.right;
    const bubbleTextDirection = TextDirection.rtl;
    final timestampAlignment =
        isMe ? Alignment.centerRight : Alignment.centerLeft;
    final topSpacing = showSenderMeta ? 6.0 : 2.0;
    final bottomSpacing = isLastInGroup ? 6.0 : 2.0;
    final normalizedSenderId = senderId.trim();
    final isHighlighted = _highlightedMessageId == messageId;

    return Padding(
      key: _messageKeyFor(messageId),
      padding: EdgeInsets.fromLTRB(12, topSpacing, 12, bottomSpacing),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showSenderMeta)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Align(
                      alignment:
                          isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: normalizedSenderId.isEmpty || isDeletedSender
                            ? null
                            : () => _openUserProfileFromChat(
                                  normalizedSenderId,
                                ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          textDirection: TextDirection.ltr,
                          children: isMe
                              ? [
                                  Flexible(
                                    child: Text(
                                      senderName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  avatar,
                                ]
                              : [
                                  avatar,
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      senderName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400),
                                    ),
                                  ),
                                ],
                        ),
                      ),
                    ),
                  ),
                if (isPostMessage)
                  _buildSharedPostPreview(
                    postPayload: postPayload,
                    isMe: isMe,
                  ),
                if (showUnifiedPostFlow && hasPostCaption)
                  SizedBox(
                    width: 168,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 7, horizontal: 12),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasPostCaption)
                              Text(
                                normalizedText,
                                textAlign: bubbleTextAlign,
                                textDirection: bubbleTextDirection,
                                style: TextStyle(color: fg, height: 1.25),
                              ),
                            if (hasPostCaption) const SizedBox(height: 4),
                            Align(
                              alignment: timestampAlignment,
                              child: Text(
                                sentAt,
                                textDirection: bubbleTextDirection,
                                style: TextStyle(
                                  color: isLight
                                      ? fg.withValues(alpha: 0.72)
                                      : Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (showUnifiedPostFlow && !hasPostCaption)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: timestampAlignment,
                      child: Text(
                        sentAt,
                        textDirection: bubbleTextDirection,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF5D6B85)
                              : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                if (isPostMessage && showBubbleShell) const SizedBox(height: 6),
                if (!showUnifiedPostFlow)
                  Container(
                    padding: showBubbleShell
                        ? const EdgeInsets.symmetric(
                            vertical: 7, horizontal: 12)
                        : (isPostMessage
                            ? const EdgeInsets.only(top: 4)
                            : EdgeInsets.zero),
                    decoration: BoxDecoration(
                      color: showBubbleShell ? bg : Colors.transparent,
                      borderRadius: showBubbleShell ? bubbleRadius : null,
                      border: isHighlighted
                          ? Border.all(
                              color: isLight
                                  ? const Color(0xFF53C1F9)
                                  : const Color(0xFF9EDBFF),
                              width: 1.5,
                            )
                          : null,
                      boxShadow: isHighlighted
                          ? [
                              BoxShadow(
                                color: const Color(0xFF53C1F9)
                                    .withValues(alpha: 0.22),
                                blurRadius: 16,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasReply)
                          _buildReplySnippet(
                            replyTo: replyTo,
                            isMe: isMe,
                            onTap: () => _scrollToMessage(
                              (replyTo['messageId'] as String? ?? '').trim(),
                              fromMessageId: messageId,
                            ),
                          ),
                        if (!isPostMessage && !isMediaMessage)
                          if (!isAudioMessage)
                            Text(
                              text,
                              textAlign: bubbleTextAlign,
                              textDirection: bubbleTextDirection,
                              style: TextStyle(color: fg, height: 1.25),
                            ),
                        if (isAudioMessage)
                          _buildAudioMessageBody(
                            durationMs: (messageData['audioDurationMs'] as num?)
                                    ?.toInt() ??
                                0,
                            isLight: isLight,
                            isMe: isMe,
                          ),
                        if (isMediaMessage && mediaItems.isNotEmpty)
                          _buildMediaMessageBody(
                            mediaItems: mediaItems,
                            isLight: isLight,
                            isMe: isMe,
                          ),
                        if (isPostMessage && normalizedText.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              normalizedText,
                              textAlign: bubbleTextAlign,
                              textDirection: bubbleTextDirection,
                              style: TextStyle(color: fg, height: 1.25),
                            ),
                          ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: timestampAlignment,
                          child: Text(
                            sentAt,
                            textDirection: bubbleTextDirection,
                            style: TextStyle(
                                color: isLight
                                    ? fg.withValues(alpha: 0.72)
                                    : Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w400),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (seenUserIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: seenUserIds
                          .take(5)
                          .map(
                            (seenUid) => Padding(
                              padding: const EdgeInsetsDirectional.only(end: 4),
                              child: _buildSeenByAvatar(
                                seenUid,
                                isLight: isLight,
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioMessageBody({
    required int durationMs,
    required bool isLight,
    required bool isMe,
  }) {
    final durationLabel = _formatAudioDurationLabel(durationMs);
    final fg = isMe
        ? (isLight ? Colors.black : Colors.white)
        : (isLight ? const Color(0xFF314260) : Colors.white70);

    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe
            ? (isLight ? const Color(0xFFECE4FF) : const Color(0xFF2B2144))
            : (isLight ? const Color(0xFFF2F7FF) : const Color(0xFF172437)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLight ? const Color(0xFFD7E2F7) : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic_rounded,
            color: fg,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            'הודעת קול',
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            durationLabel,
            style: TextStyle(
              color: fg.withValues(alpha: 0.8),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaMessageBody({
    required List<Map<String, dynamic>> mediaItems,
    required bool isLight,
    required bool isMe,
  }) {
    final visible = mediaItems.take(3).toList(growable: false);
    final caption = mediaItems.isNotEmpty
        ? (mediaItems.first['caption'] as String? ?? '').trim()
        : '';

    if (mediaItems.length == 1) {
      final singleItem = PostMediaItem(
        url: (mediaItems.first['url'] as String? ?? '').trim(),
        storagePath: (mediaItems.first['storagePath'] as String? ?? '').trim(),
        type: ((mediaItems.first['isVideo'] as bool?) ??
                isVideoMediaUrl(
                    (mediaItems.first['url'] as String? ?? '').trim()))
            ? 'video'
            : 'image',
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: SizedBox(
              width: _chatMediaPreviewWidth(context),
              child: GestureDetector(
                onTap: () => _openMediaItemFullScreen(singleItem),
                child: _buildChatMediaFrame(
                  media: mediaItems.first,
                  aspectRatio: 3 / 4,
                  isStacked: false,
                  showBackground: false,
                  showCaptionOverlay: false,
                ),
              ),
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: _chatMediaPreviewWidth(context),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: isLight
                        ? const Color(0xFFF2F7FF)
                        : const Color(0xFF1D2838),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isLight ? const Color(0xFFD4E2FF) : Colors.white12,
                    ),
                  ),
                  child: Text(
                    caption,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: isMe
                          ? Colors.white
                          : (isLight
                              ? const Color(0xFF314260)
                              : Colors.white70),
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: GestureDetector(
            onTap: () => _openMediaItemsViewer(mediaItems),
            child: _buildMultiChatMediaPreview(visible),
          ),
        ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: _chatMediaPreviewWidth(context),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: isLight
                      ? const Color(0xFFF2F7FF)
                      : const Color(0xFF1D2838),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isLight ? const Color(0xFFD4E2FF) : Colors.white12,
                  ),
                ),
                child: Text(
                  caption,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white
                        : (isLight ? const Color(0xFF314260) : Colors.white70),
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMultiChatMediaPreview(List<Map<String, dynamic>> mediaItems) {
    final visible = mediaItems.take(3).toList(growable: false);
    final extraCount = mediaItems.length - visible.length;
    final previewWidth = _chatMediaPreviewWidth(context);
    final stackSpecs = <_ChatMediaStackSpec>[
      const _ChatMediaStackSpec(
        top: 12,
        left: 12,
        right: 14,
        bottom: 12,
        angle: 0,
        scale: 0.89,
        blurSigma: 0,
      ),
      const _ChatMediaStackSpec(
        top: 8,
        left: 6,
        right: 16,
        bottom: 14,
        angle: -0.08,
        scale: 0.95,
        blurSigma: 0.9,
      ),
      const _ChatMediaStackSpec(
        top: 20,
        left: 18,
        right: 6,
        bottom: 2,
        angle: 0.11,
        scale: 0.92,
        blurSigma: 1.8,
      ),
    ];

    return SizedBox(
      width: previewWidth,
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var index = visible.length - 1; index >= 0; index--)
              Positioned.fill(
                top: stackSpecs[index].top,
                left: stackSpecs[index].left,
                right: stackSpecs[index].right,
                bottom: stackSpecs[index].bottom,
                child: Transform.rotate(
                  angle: stackSpecs[index].angle,
                  child: Transform.scale(
                    scale: stackSpecs[index].scale,
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: stackSpecs[index].blurSigma,
                        sigmaY: stackSpecs[index].blurSigma,
                      ),
                      child: _buildChatMediaFrame(
                        media: visible[index],
                        aspectRatio: 3 / 4,
                        isStacked: true,
                        showBackground: false,
                        showCaptionOverlay: false,
                      ),
                    ),
                  ),
                ),
              ),
            if (extraCount > 0)
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '+$extraCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatMediaFrame({
    required Map<String, dynamic> media,
    required double aspectRatio,
    required bool isStacked,
    required bool showBackground,
    required bool showCaptionOverlay,
  }) {
    final url = (media['url'] as String? ?? '').trim();
    final isVideo = (media['isVideo'] as bool?) ?? isVideoMediaUrl(url);
    final borderRadius = BorderRadius.circular(isStacked ? 16 : 18);

    Widget child;
    if (url.isNotEmpty && !isVideo) {
      child = Image.network(
        url,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF111A28),
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 34,
          ),
        ),
      );
    } else if (url.isNotEmpty && isVideo) {
      child = FutureBuilder<Uint8List?>(
        future: buildVideoPreviewBytesFromSource(url),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return Container(
              color: const Color(0xFF111A28),
              alignment: Alignment.center,
              child: const Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
                size: 40,
              ),
            );
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            alignment: Alignment.center,
          );
        },
      );
    } else {
      child = Container(
        color: const Color(0xFF111A28),
        alignment: Alignment.center,
        child: const Icon(
          Icons.image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    final frame = ClipRRect(
      borderRadius: borderRadius,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (isVideo)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.06),
                      Colors.black.withValues(alpha: 0.22),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            if (isVideo)
              const Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 42,
                ),
              ),
            if (showCaptionOverlay)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    (media['caption'] as String? ?? '').trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (!showBackground) {
      return frame;
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.light
            ? const Color(0xFFF2F7FF)
            : const Color(0xFF172133),
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: frame,
    );
  }

  void _openMediaItemsViewer(List<Map<String, dynamic>> mediaItems) {
    final items = mediaItems
        .map(
          (media) => PostMediaItem(
            url: (media['url'] as String? ?? '').trim(),
            storagePath: (media['storagePath'] as String? ?? '').trim(),
            type: ((media['isVideo'] as bool?) ??
                    isVideoMediaUrl((media['url'] as String? ?? '').trim()))
                ? 'video'
                : 'image',
          ),
        )
        .where((item) => item.url.trim().isNotEmpty)
        .toList(growable: false);

    if (items.isEmpty) return;

    final isLight = _isLightMode(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF0F1624),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.86,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final mediaItem = items[index];
                final caption =
                    (mediaItems[index]['caption'] as String? ?? '').trim();
                return GestureDetector(
                  onTap: () => _openMediaItemFullScreen(mediaItem),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildChatMediaFrame(
                        media: mediaItems[index],
                        aspectRatio: _chatMediaAspectRatio(mediaItems[index]),
                        isStacked: false,
                        showBackground: false,
                        showCaptionOverlay: false,
                      ),
                      if (caption.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            caption,
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF2D3A53)
                                  : Colors.white,
                              fontSize: 13,
                              height: 1.25,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _openMediaItemFullScreen(PostMediaItem mediaItem) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ChatMediaViewerPage(
          mediaItem: mediaItem,
          caption: (mediaItem.url.isNotEmpty ? '' : ''),
        ),
      ),
    );
  }

  double _chatMediaAspectRatio(Map<String, dynamic> media) {
    final isVideo = (media['isVideo'] as bool?) ??
        isVideoMediaUrl((media['url'] as String? ?? '').trim());
    if (isVideo) {
      return 9 / 16;
    }
    return 3 / 4;
  }

  double _chatMediaPreviewWidth(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return screenWidth < 390 ? 220 : (screenWidth * 0.56).clamp(240.0, 288.0);
  }

  Future<void> _sendMediaBatch(List<_PendingChatMedia> drafts) async {
    if (drafts.isEmpty) return;

    final mediaDrafts = <Map<String, dynamic>>[];
    for (final draft in drafts.take(10)) {
      final bytes = await draft.file.readAsBytes();
      final fileName = draft.file.name;
      final dotIndex = fileName.lastIndexOf('.');
      final extension = dotIndex >= 0
          ? fileName.substring(dotIndex + 1).toLowerCase()
          : (draft.isVideo ? 'mp4' : 'jpg');
      mediaDrafts.add(<String, dynamic>{
        'bytes': bytes,
        'extension': extension,
        'isVideo': draft.isVideo,
        'caption': draft.captionController.text.trim(),
      });
    }

    try {
      if (!mounted) return;
      setState(() {
        _isSendingMedia = true;
      });

      await _chatService.sendMediaMessage(
        chatId: widget.chatId,
        mediaDrafts: mediaDrafts,
      );
      _scheduleScrollToBottom(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שליחת מדיה נכשלה: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingMedia = false;
        });
      }
    }
  }

  bool _isSameDay(DateTime? first, DateTime? second) {
    if (first == null || second == null) {
      return false;
    }

    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  String _formatDayHeader(DateTime? dateTime) {
    if (dateTime == null) {
      return '';
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(dateTime.year, dateTime.month, dateTime.day);
    final yesterday = today.subtract(const Duration(days: 1));

    if (messageDay == today) {
      return 'היום';
    }
    if (messageDay == yesterday) {
      return 'אתמול';
    }

    final day = messageDay.day.toString().padLeft(2, '0');
    final month = messageDay.month.toString().padLeft(2, '0');
    final year = messageDay.year.toString();
    return '$day/$month/$year';
  }

  Widget _buildDaySeparator(String label) {
    final isLight = _isLightMode(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: isLight ? const Color(0xFFCFDBF1) : Colors.white12,
              margin: const EdgeInsetsDirectional.only(start: 16, end: 8),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1E2632),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isLight ? const Color(0xFFC9D8F2) : Colors.white12,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: isLight ? const Color(0xFFCFDBF1) : Colors.white12,
              margin: const EdgeInsetsDirectional.only(start: 8, end: 16),
            ),
          ),
        ],
      ),
    );
  }

  void _ensureSenderSummaries(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final unresolvedSenderIds = docs
        .map((doc) => ((doc.data()['senderId'] as String?) ?? '').trim())
        .where((senderId) {
          if (senderId.isEmpty) {
            return false;
          }
          if (_senderSummaries.containsKey(senderId)) {
            return false;
          }
          return !_loadingSenderIds.contains(senderId);
        })
        .toSet()
        .toList(growable: false);

    if (unresolvedSenderIds.isEmpty) {
      return;
    }

    _loadingSenderIds.addAll(unresolvedSenderIds);
    _chatService.fetchUserSummaries(unresolvedSenderIds).then((summaries) {
      if (!mounted || summaries.isEmpty) {
        return;
      }
      setState(() {
        _senderSummaries.addAll(summaries);
        for (final entry in summaries.entries) {
          final normalizedUsername =
              _normalizeUsernameLookupKey(entry.key).trim();
          if (normalizedUsername.isNotEmpty) {
            _senderSummaries.putIfAbsent(normalizedUsername, () => entry.value);
            _senderSummaries.putIfAbsent(
                '@$normalizedUsername', () => entry.value);
          }
        }
      });
    }).whenComplete(() {
      _loadingSenderIds.removeAll(unresolvedSenderIds);
    });
  }

  void _handleVisibleMessages(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    _visibleMessageIndexById
      ..clear()
      ..addEntries(
        docs.asMap().entries.map(
              (entry) => MapEntry(entry.value.id, entry.key),
            ),
      );

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (docs.isNotEmpty) {
      final latestDoc = docs.first;
      final latestId = latestDoc.id;
      final hadPreviousSnapshot = _lastRenderedMessageCount > 0;
      final isMessageCountIncreased = docs.length > _lastRenderedMessageCount;
      final isLatestMessageChanged = _lastRenderedLatestMessageId != null &&
          _lastRenderedLatestMessageId != latestId;
      final isNewMessageEvent = !hadPreviousSnapshot ||
          isMessageCountIncreased ||
          isLatestMessageChanged;

      if (isNewMessageEvent) {
        if (!_didResolveInitialAnchor) {
          _lastRenderedLatestMessageId = latestId;
          _lastRenderedMessageCount = docs.length;
          return;
        }

        final latestSenderId =
            (latestDoc.data()['senderId'] as String? ?? '').trim();
        final isMyLatestMessage = myUid != null && latestSenderId == myUid;
        final shouldAutoScroll =
            !_didInitialAutoScroll || isMyLatestMessage || _stickToBottom;
        ShareFlowLogService.log(
          'CHAT_SCROLL_NEW_MESSAGE_EVENT',
          data: <String, Object?>{
            'latestId': latestId,
            'force': isMyLatestMessage,
            'isMyLatestMessage': isMyLatestMessage,
            'didInitialAutoScroll': _didInitialAutoScroll,
            'stickToBottom': _stickToBottom,
            'hasUserScrolled': _hasUserScrolled,
            'count': docs.length,
            'shouldAutoScroll': shouldAutoScroll,
          },
        );
        if (shouldAutoScroll) {
          _scheduleScrollToBottom(
              force: isMyLatestMessage || !_didInitialAutoScroll);
          _didInitialAutoScroll = true;
        }
      }

      _lastRenderedLatestMessageId = latestId;
      _lastRenderedMessageCount = docs.length;
    } else {
      _lastRenderedLatestMessageId = null;
      _lastRenderedMessageCount = 0;
    }

    if (myUid != null && myUid.isNotEmpty && docs.isNotEmpty) {
      _markLatestVisibleMessageAsRead(docs);
    }

    _ensureSenderSummaries(docs);
  }

  DateTime? _messageDate(Map<String, dynamic> data) {
    return (data['timestamp'] as Timestamp?)?.toDate() ??
        (data['createdAt'] as Timestamp?)?.toDate();
  }

  String _resolveSenderName(Map<String, dynamic> data) {
    final senderId = (data['senderId'] as String? ?? '').trim();
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (senderId.isNotEmpty && senderId == currentUid) {
      return 'את/ה';
    }

    final messageSenderName = (data['senderName'] as String? ?? '').trim();
    final cachedName = _summaryForSenderId(senderId)['name'] ?? '';
    final senderIdLooksLikeUid = _looksLikeFirebaseUid(senderId);
    if (cachedName.isNotEmpty &&
        cachedName != 'משתמש' &&
        (!senderIdLooksLikeUid || cachedName != senderId)) {
      return cachedName;
    }

    if (messageSenderName.isNotEmpty &&
        messageSenderName != 'משתמש' &&
        (!senderIdLooksLikeUid || messageSenderName != senderId)) {
      return messageSenderName;
    }

    return 'משתמש';
  }

  String _resolveSenderAvatarUrl(Map<String, dynamic> data) {
    final senderId = (data['senderId'] as String? ?? '').trim();
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final messageAvatarUrl = ((data['senderAvatarUrl'] as String?) ??
            (data['senderProfilePictureUrl'] as String?) ??
            (data['senderPhotoUrl'] as String?) ??
            '')
        .trim();
    if (messageAvatarUrl.isNotEmpty) {
      return messageAvatarUrl;
    }
    final summaryAvatar =
        (_summaryForSenderId(senderId)['avatarUrl'] ?? '').trim();
    if (summaryAvatar.isNotEmpty) {
      return summaryAvatar;
    }

    if (senderId.isNotEmpty && senderId == currentUid) {
      return (FirebaseAuth.instance.currentUser?.photoURL ?? '').trim();
    }

    return '';
  }

  bool _looksLikeFirebaseUid(String value) {
    final trimmed = value.trim();
    if (trimmed.length != 28) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9]+$').hasMatch(trimmed);
  }

  Map<String, String> _summaryForSenderId(String senderId) {
    final normalized = senderId.trim();
    if (normalized.isEmpty) {
      return const <String, String>{};
    }

    final direct = _senderSummaries[normalized];
    if (direct != null) {
      return direct;
    }

    final normalizedUsername = _normalizeUsernameLookupKey(normalized);
    if (normalizedUsername.isNotEmpty) {
      final byUsername = _senderSummaries[normalizedUsername];
      if (byUsername != null) {
        return byUsername;
      }
      final byAtUsername = _senderSummaries['@$normalizedUsername'];
      if (byAtUsername != null) {
        return byAtUsername;
      }
    }

    return const <String, String>{};
  }

  String _normalizeUsernameLookupKey(String raw) {
    var value = raw.trim().toLowerCase();
    if (value.isEmpty) {
      return '';
    }
    if (value.startsWith('@')) {
      value = value.substring(1);
    }
    return value;
  }

  void _markLatestVisibleMessageAsRead(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty || docs.isEmpty) {
      return;
    }

    final latestDoc = docs.first;
    final latestData = latestDoc.data();
    final latestTimestamp = _messageDate(latestData);
    if (latestTimestamp == null) {
      return;
    }

    final markerKey =
        '${latestDoc.id}_${latestTimestamp.microsecondsSinceEpoch}';
    if (_lastReadMarkerKey == markerKey) {
      return;
    }
    _lastReadMarkerKey = markerKey;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _chatService.markChatAsRead(
        chatId: widget.chatId,
        lastReadMessageId: latestDoc.id,
        lastReadAt: latestTimestamp,
      );
    });
  }

  String _formatMessageClock(DateTime? dateTime) {
    if (dateTime == null) {
      return '--:--';
    }

    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, List<String>> _buildReadReceiptMessageMap({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> messages,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> receipts,
    required String currentUid,
  }) {
    final latestReadIndexByUser = <String, int>{};

    for (final receipt in receipts) {
      final data = receipt.data();
      final uid = (data['uid'] as String?) ?? '';
      if (uid.isEmpty || uid == currentUid) {
        continue;
      }

      final lastReadMessageId = (data['lastReadMessageId'] as String?) ?? '';
      final lastReadAt = (data['lastReadAt'] as Timestamp?)?.toDate();
      int? bestIndex;

      if (lastReadMessageId.isNotEmpty) {
        final explicitIndex =
            messages.indexWhere((message) => message.id == lastReadMessageId);
        if (explicitIndex != -1) {
          bestIndex = explicitIndex;
        }
      }

      if (bestIndex == null && lastReadAt != null) {
        for (var i = messages.length - 1; i >= 0; i--) {
          final messageTime = _messageDate(messages[i].data());
          if (messageTime != null && !messageTime.isAfter(lastReadAt)) {
            bestIndex = i;
            break;
          }
        }
      }

      if (bestIndex == null) {
        continue;
      }

      latestReadIndexByUser[uid] = bestIndex;
    }

    final receiptsByMessageId = <String, List<String>>{};
    latestReadIndexByUser.forEach((uid, index) {
      if (index < 0 || index >= messages.length) {
        return;
      }

      final messageId = messages[index].id;
      receiptsByMessageId.putIfAbsent(messageId, () => <String>[]).add(uid);
    });

    return receiptsByMessageId;
  }

  Widget _buildSeenByAvatar(String userId, {required bool isLight}) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return CircleAvatar(
        radius: 8,
        backgroundColor:
            isLight ? const Color(0xFFDCE8FF) : const Color(0xFF2A3445),
      );
    }

    final cachedAvatar =
        (_senderSummaries[normalizedUserId]?['avatarUrl'] ?? '').trim();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users_public')
          .doc(normalizedUserId)
          .snapshots(),
      builder: (context, publicSnapshot) {
        final publicData =
            publicSnapshot.data?.data() ?? const <String, dynamic>{};
        var avatarUrl = ((publicData['profilePictureUrl'] as String?) ??
                (publicData['profileImageUrl'] as String?) ??
                (publicData['avatarUrl'] as String?) ??
                '')
            .trim();

        if (avatarUrl.isEmpty) {
          avatarUrl = cachedAvatar;
        }

        return CircleAvatar(
          radius: 8,
          backgroundColor:
              isLight ? const Color(0xFFDCE8FF) : const Color(0xFF2A3445),
          backgroundImage:
              avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
        );
      },
    );
  }

  @override
  void dispose() {
    unawaited(_closeAttachmentMenu(immediate: true));
    _attachmentMenuController.dispose();
    KeyboardDismissController.resume();
    _markChatAsReadFromServer();
    _scrollController.removeListener(_handleScrollActivity);
    _controller.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = _isLightMode(context);
    final isDirectChat = widget.isDirectChat ?? false;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.66).clamp(190.0, 240.0);
    final orbSizeB = (screenWidth * 0.78).clamp(220.0, 280.0);
    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('chats')
                .doc(widget.chatId)
                .snapshots(),
            builder: (context, chatSnapshot) {
              final chatData = chatSnapshot.data?.data();
              final isDirectChat = _isDirectChat(chatData);
              if (isDirectChat) {
                final resolvedOtherUid = _directChatOtherUid(chatData);
                _latestDirectOtherUid = resolvedOtherUid.isNotEmpty
                    ? resolvedOtherUid
                    : (widget.directOtherUserId ?? '').trim();
              }
              final isDeletedDirectChatProfile =
                  isDirectChat && _isDeletedProfileLabel(widget.chatName);
              final fallbackGroupName =
                  ((chatData?['name'] as String?) ?? widget.chatName).trim();
              final fallbackGroupImage =
                  ((chatData?['groupImageUrl'] as String?) ??
                          widget.avatarUrl ??
                          '')
                      .trim();

              return AppBar(
                backgroundColor:
                    isLight ? const Color(0xFFF4FAFF) : const Color(0xFF1E2632),
                titleSpacing: 0,
                leading: IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: isLight ? Colors.black : Colors.white,
                  ),
                  onPressed: () async {
                    await _markChatAsReadFromServer();
                    if (!mounted) {
                      return;
                    }
                    Navigator.of(this.context).pop();
                  },
                ),
                title: InkWell(
                  onTap: () {
                    if (isDirectChat) {
                      if (isDeletedDirectChatProfile) {
                        return;
                      }
                      final otherUid = _directChatOtherUid(chatData);
                      if (otherUid.isEmpty) {
                        return;
                      }
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  UserProfileScreen(
                            uid: otherUid,
                            currentBottomIndex: 3,
                                    openedFromDirectChat: widget.isDirectChat == true,
                          ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                            return FadeTransition(
                                opacity: animation, child: child);
                          },
                        ),
                      );
                      return;
                    }

                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            GroupDetailsScreen(
                          isAdmin: true,
                          groupId: widget.chatId,
                        ),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                          return FadeTransition(
                              opacity: animation, child: child);
                        },
                      ),
                    );
                  },
                  child: isDirectChat
                      ? Row(
                          children: [
                            GroupAvatar(
                              radius: 18,
                              imageUrl: widget.avatarUrl ?? '',
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.chatName,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        )
                      : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection('groups')
                              .doc(widget.chatId)
                              .snapshots(),
                          builder: (context, groupSnapshot) {
                            final groupData = groupSnapshot.data?.data() ??
                                const <String, dynamic>{};
                            final liveName =
                                ((groupData['groupName'] as String?) ??
                                        (groupData['name'] as String?) ??
                                        fallbackGroupName)
                                    .trim();
                            final liveImageUrl =
                                ((groupData['groupImageUrl'] as String?) ??
                                        fallbackGroupImage)
                                    .trim();

                            return Row(
                              children: [
                                GroupAvatar(
                                  radius: 18,
                                  imageUrl: liveImageUrl,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    liveName.isNotEmpty
                                        ? liveName
                                        : fallbackGroupName,
                                    style: TextStyle(
                                      color:
                                          isLight ? Colors.black : Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              );
            },
          ),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: -90,
                right: -70,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeA,
                    height: orbSizeA,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF53C1F9)
                          .withValues(alpha: isLight ? 0.08 : 0.07),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -120,
                left: -90,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeB,
                    height: orbSizeB,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF9E7CFF)
                          .withValues(alpha: isLight ? 0.07 : 0.08),
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  Expanded(
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) {
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _chatService.streamChatMessages(widget.chatId),
                        builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                                ConnectionState.waiting &&
                            !snapshot.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'שגיאה בטעינת הודעות',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF5C6B88)
                                    : Colors.white70,
                              ),
                            ),
                          );
                        }

                        final descendingDocs = snapshot.data?.docs ??
                            const <QueryDocumentSnapshot<
                                Map<String, dynamic>>>[];
                        final docs = descendingDocs;
                        final myUid = FirebaseAuth.instance.currentUser?.uid;
                        _handleVisibleMessages(descendingDocs);

                        return StreamBuilder<
                            QuerySnapshot<Map<String, dynamic>>>(
                          stream: _chatService
                              .streamChatReadReceipts(widget.chatId),
                          builder: (context, readSnapshot) {
                            final receiptDocs = readSnapshot.data?.docs ??
                                const <QueryDocumentSnapshot<
                                    Map<String, dynamic>>>[];
                            _resolveInitialAnchorIfNeeded(
                              docs: docs,
                              receiptDocs: receiptDocs,
                              myUid: myUid ?? '',
                            );
                            final readReceiptsByMessageId =
                                _buildReadReceiptMessageMap(
                              messages: docs,
                              receipts: receiptDocs,
                              currentUid: myUid ?? '',
                            );

                            return NotificationListener<UserScrollNotification>(
                              onNotification: _handleUserScrollNotification,
                              child: ListView.builder(
                                controller: _scrollController,
                                reverse: true,
                                padding:
                                    const EdgeInsets.only(top: 12, bottom: 12),
                                itemCount: docs.length,
                                itemBuilder: (context, index) {
                                  final data = docs[index].data();
                                  final senderId =
                                      (data['senderId'] as String?) ?? '';
                                  final messageDate = _messageDate(data);

                                  final nextData = index < docs.length - 1
                                      ? docs[index + 1].data()
                                      : null;
                                  final nextSenderId =
                                      (nextData?['senderId'] as String?) ?? '';
                                  final nextDate = nextData == null
                                      ? null
                                      : _messageDate(nextData);

                                  final showDaySeparator = nextData == null ||
                                      !_isSameDay(nextDate, messageDate);
                                  // With reverse=true and descending snapshots,
                                  // the first visible message in a sender/day run
                                  // is compared against the older neighbor (nextData).
                                  final showSenderMeta =
                                      index == docs.length - 1 ||
                                          nextSenderId != senderId ||
                                          !_isSameDay(nextDate, messageDate);
                                  final effectiveShowSenderMeta =
                                      isDirectChat ? false : showSenderMeta;
                                  final isLastInGroup =
                                      index == docs.length - 1 ||
                                          nextSenderId != senderId ||
                                          !_isSameDay(nextDate, messageDate);

                                  final senderName = _resolveSenderName(data);
                                  final senderAvatarUrl =
                                      _resolveSenderAvatarUrl(data);
                                  final text = (data['text'] as String?) ?? '';
                                  final sentAt =
                                      _formatMessageClock(messageDate);
                                  final isMe =
                                      myUid != null && myUid == senderId;
                                  final replyTarget = _buildReplyTarget(
                                    messageId: docs[index].id,
                                    messageData: data,
                                    senderName: senderName,
                                  );

                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (showDaySeparator)
                                        _buildDaySeparator(
                                          _formatDayHeader(messageDate),
                                        ),
                                      Dismissible(
                                        key: ValueKey<String>(
                                            'reply_${docs[index].id}'),
                                        direction: Directionality.of(context) ==
                                                TextDirection.rtl
                                            ? DismissDirection.endToStart
                                            : DismissDirection.startToEnd,
                                        resizeDuration: null,
                                        confirmDismiss: (_) async {
                                          if (!mounted) {
                                            return false;
                                          }
                                          setState(() {
                                            _replyTarget = replyTarget;
                                          });
                                          _inputFocusNode.requestFocus();
                                          return false;
                                        },
                                        background: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 10,
                                              ),
                                              decoration: BoxDecoration(
                                                color: isLight
                                                    ? const Color(0xFFEAF4FF)
                                                    : const Color(0xFF172437),
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                                border: Border.all(
                                                  color: isLight
                                                      ? const Color(0xFFA9C3FF)
                                                      : const Color(0xFF53C1F9)
                                                          .withValues(
                                                              alpha: 0.24),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.reply_rounded,
                                                    size: 18,
                                                    color: isLight
                                                        ? const Color(
                                                            0xFF6B4BB6)
                                                        : const Color(
                                                            0xFF9EDBFF),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    'הגב',
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? const Color(
                                                              0xFF34425D)
                                                          : Colors.white70,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        secondaryBackground: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 10,
                                              ),
                                              decoration: BoxDecoration(
                                                color: isLight
                                                    ? const Color(0xFFEAF4FF)
                                                    : const Color(0xFF172437),
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                                border: Border.all(
                                                  color: isLight
                                                      ? const Color(0xFFA9C3FF)
                                                      : const Color(0xFF53C1F9)
                                                          .withValues(
                                                              alpha: 0.24),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.reply_rounded,
                                                    size: 18,
                                                    color: isLight
                                                        ? const Color(
                                                            0xFF6B4BB6)
                                                        : const Color(
                                                            0xFF9EDBFF),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    'הגב',
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? const Color(
                                                              0xFF34425D)
                                                          : Colors.white70,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        child: _buildMessageBubble(
                                          messageId: docs[index].id,
                                          text: text,
                                          isMe: isMe,
                                          senderId: senderId,
                                          senderName: senderName,
                                          senderAvatarUrl: senderAvatarUrl,
                                          sentAt: sentAt,
                                          seenUserIds: readReceiptsByMessageId[
                                                  docs[index].id] ??
                                              const <String>[],
                                          showSenderMeta:
                                              effectiveShowSenderMeta,
                                          isFirstInGroup:
                                              effectiveShowSenderMeta,
                                          isLastInGroup: isLastInGroup,
                                          messageData: data,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            );
                          },
                        );
                        },
                      ),
                    ),
                  ),
                  TextFieldTapRegion(
                    groupId: _composerTapRegionGroupId,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      color: isLight
                          ? const Color(0xFFCFEFFF)
                          : const Color(0xFF1E2632),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isLight
                              ? Colors.white.withValues(alpha: 0.72)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isLight
                                ? const Color(0xFF8FD2F6)
                                : Colors.transparent,
                          ),
                        ),
                        child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_replyTarget != null)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                              decoration: BoxDecoration(
                                color: isLight
                                    ? const Color(0xFFF4FAFF)
                                    : const Color(0xFF182538),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isLight
                                      ? const Color(0xFFA9C3FF)
                                      : const Color(0xFF53C1F9)
                                          .withValues(alpha: 0.22),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _replyTarget = null;
                                      });
                                    },
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                      color: isLight
                                          ? const Color(0xFF6B4BB6)
                                          : const Color(0xFF9EDBFF),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          'הגב ל: ${_replyTarget!.senderName}',
                                          textDirection: TextDirection.rtl,
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF6B4BB6)
                                                : const Color(0xFF9EDBFF),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _replyTarget!.textPreview,
                                          textDirection: TextDirection.rtl,
                                          textAlign: TextAlign.right,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF34425D)
                                                : Colors.white70,
                                            fontSize: 12,
                                            height: 1.25,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Row(
                            textDirection: TextDirection.ltr,
                            children: [
                              IconButton(
                                icon: _isSendingText
                                    ? SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: isLight
                                              ? const Color(0xFF4DBEEA)
                                              : const Color(0xFF9E7CFF),
                                        ),
                                      )
                                    : Icon(
                                        Icons.send,
                                        color: isLight
                                            ? const Color(0xFF4DBEEA)
                                            : const Color(0xFF9E7CFF),
                                      ),
                                onPressed: _isSendingText ? null : _sendMessage,
                              ),
                              Expanded(
                                child: TextField(
                                  groupId: _composerTapRegionGroupId,
                                  controller: _controller,
                                  focusNode: _inputFocusNode,
                                  onTapOutside: (_) {},
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'הקלד הודעה...',
                                    hintStyle: TextStyle(
                                      color: isLight
                                          ? Colors.black54
                                          : Colors.white54,
                                    ),
                                    border: InputBorder.none,
                                  ),
                                  onSubmitted: (_) => _sendMessage(),
                                ),
                              ),
                              IconButton(
                                key: _attachmentButtonKey,
                                icon: _isSendingMedia
                                    ? SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: isLight
                                              ? const Color(0xFF4DBEEA)
                                              : const Color(0xFF9E7CFF),
                                        ),
                                      )
                                    : Icon(
                                        Icons.add_photo_alternate_rounded,
                                        color: isLight
                                            ? const Color(0xFF4DBEEA)
                                            : const Color(0xFF9E7CFF),
                                      ),
                                onPressed: _isSendingMedia
                                    ? null
                                    : _openAttachmentActions,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatAudioDurationLabel(int durationMs) {
  final totalSeconds = (durationMs / 1000).ceil();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _ChatMediaStackSpec {
  const _ChatMediaStackSpec({
    required this.top,
    required this.left,
    required this.right,
    required this.bottom,
    required this.angle,
    required this.scale,
    required this.blurSigma,
  });

  final double top;
  final double left;
  final double right;
  final double bottom;
  final double angle;
  final double scale;
  final double blurSigma;
}

class _ChatMediaViewerPage extends StatefulWidget {
  const _ChatMediaViewerPage({
    required this.mediaItem,
    required this.caption,
  });

  final PostMediaItem mediaItem;
  final String caption;

  @override
  State<_ChatMediaViewerPage> createState() => _ChatMediaViewerPageState();
}

class _ChatMediaViewerPageState extends State<_ChatMediaViewerPage> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;

  @override
  void initState() {
    super.initState();
    if (widget.mediaItem.isVideo) {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(widget.mediaItem.url),
      )..initialize().then((_) async {
          if (!mounted) return;
          await _videoController?.setLooping(true);
          await _videoController?.setVolume(1);
          await _videoController?.play();
          setState(() {
            _isVideoInitialized = true;
          });
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.mediaItem;
    final isVideo = item.isVideo;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: widget.caption.isNotEmpty
            ? Text(
                widget.caption,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              )
            : null,
      ),
      body: SafeArea(
        child: Center(
          child: isVideo ? _buildVideoViewer() : _buildImageViewer(),
        ),
      ),
    );
  }

  Widget _buildImageViewer() {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Image.network(
        widget.mediaItem.url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 42,
          ),
        ),
      ),
    );
  }

  Widget _buildVideoViewer() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox(
        width: 42,
        height: 42,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: Colors.white70,
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        if (!_isVideoInitialized) return;
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
        setState(() {});
      },
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            if (!controller.value.isPlaying)
              Container(
                color: Colors.black.withValues(alpha: 0.18),
                child: const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 72,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
