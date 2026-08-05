import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'app_categories.dart';
import 'category_points.dart';
import 'models/post_media_item.dart';
import 'post_media_utils.dart';
import 'post_model.dart';
import 'profile_screen.dart';
import 'services/post_service.dart';
import 'services/public_user_profile_service.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

class _FriendOption {
  final String uid;
  final String name;
  final String avatarUrl;

  const _FriendOption({
    required this.uid,
    required this.name,
    required this.avatarUrl,
  });
}

class _EventPickerPreviewMedia {
  final String thumbnailUrl;
  final String videoUrl;

  const _EventPickerPreviewMedia({
    required this.thumbnailUrl,
    required this.videoUrl,
  });

  bool get hasThumbnail => thumbnailUrl.trim().isNotEmpty;
  bool get hasVideo => videoUrl.trim().isNotEmpty;
}

Widget _buildEventPickerVideoPoster({required bool isLight}) {
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: isLight
            ? const [Color(0xFFEFF5FF), Color(0xFFDDEBFF)]
            : const [Color(0xFF1A2435), Color(0xFF121A28)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity( isLight ? 0.12 : 0.26),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.play_arrow_rounded,
          color: Colors.white,
          size: 34,
        ),
      ),
    ),
  );
}

class PostEditScreen extends StatefulWidget {
  final XFile? selectedMedia;
  final Uint8List? mediaBytes;
  final List<PostUploadMediaItem>? selectedMediaItems;
  final bool isEdit;
  final PostModel? post;
  final String? initialCategory;
  final String? initialSubCategory;
  final String? initialLocation;
  final List<String>? initialParticipantUids;

  const PostEditScreen({
    super.key,
    this.selectedMedia,
    this.mediaBytes,
    this.selectedMediaItems,
    this.isEdit = false,
    this.post,
    this.initialCategory,
    this.initialSubCategory,
    this.initialLocation,
    this.initialParticipantUids,
  });

  @override
  State<PostEditScreen> createState() => _PostEditScreenState();
}

class _PostEditScreenState extends State<PostEditScreen> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _locationController = TextEditingController();
  final PageController _mediaPageController = PageController();

  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  final List<_FriendOption> _allFriends = <_FriendOption>[];
  final List<String> _selectedFriendUids = <String>[];
  final PostService _postService = PostService();

  List<_FriendOption> _filteredFriends = <_FriendOption>[];
  List<PostUploadMediaItem> _draftMediaItems = <PostUploadMediaItem>[];
  List<String> _editableExistingMediaUrls = <String>[];
  final Map<String, Future<Uint8List?>> _videoPreviewFutureByUrl = {};
  final Map<String, Future<String?>> _resolvedPreviewUrlFutureBySource = {};
  bool _friendsLoading = false;
  bool _isPublishing = false;
  bool _isDeleting = false;
  int _currentMediaIndex = 0;

  String? _mainCategory;
  String? _subCategory;
  bool _linkToExistingEvent = false;
  String _selectedEventGroupId = '';
  String _selectedEventSourcePostId = '';
  String _selectedEventLabel = '';
  String _linkedGroupId = '';
  String _linkedGroupLabel = '';
  bool _linkedGroupIsPublic = false;
  String _audience = 'public';

  bool _isLight(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light;
  }

  Color _screenBackground(BuildContext context) {
    return _isLight(context)
        ? const Color(0xFFF2F7FF)
        : const Color(0xFF0B1019);
  }

  Color _surfaceColor(BuildContext context) {
    return _isLight(context) ? Colors.white : const Color(0xFF1E2632);
  }

  Color _primaryTextColor(BuildContext context) {
    return _isLight(context) ? Colors.black : Colors.white;
  }

  Color _secondaryTextColor(BuildContext context) {
    return _isLight(context) ? Colors.black54 : Colors.white70;
  }

  Color _borderColor(BuildContext context) {
    return _isLight(context) ? const Color(0xFF53C1F9) : Colors.white24;
  }

  @override
  void initState() {
    super.initState();
    _loadFriends();
    _seedDraftMediaItems();
    _hydrateMissingVideoPreviews();

    final initialCategory = widget.initialCategory;
    if (initialCategory != null && initialCategory.trim().isNotEmpty) {
      _mainCategory = initialCategory;
      final subCategories = appSubCategories(_mainCategory);
      final initialSubCategory = widget.initialSubCategory;
      if (initialSubCategory != null &&
          subCategories.contains(initialSubCategory)) {
        _subCategory = initialSubCategory;
      } else if (subCategories.isNotEmpty) {
        _subCategory = subCategories.first;
      }
    } else {
      _mainCategory = kGeneralCategory;
      final subCategories = appSubCategories(_mainCategory);
      if (subCategories.isNotEmpty) {
        _subCategory = subCategories.first;
      }
    }

    if (widget.isEdit && widget.post != null) {
      final post = widget.post!;
      _titleController.text = post.title;
      _descController.text = post.description;
      _locationController.text = widget.initialLocation?.trim() ?? '';
      if (isGeneralCategory(post.category)) {
        _mainCategory = kGeneralCategory;
      } else {
        _mainCategory =
            appCategories.containsKey(post.category) ? post.category : null;
      }
      _subCategory = post.subCategory.trim().isEmpty ? null : post.subCategory;
      _selectedFriendUids
        ..clear()
        ..addAll(
          (widget.initialParticipantUids ?? post.participantUids)
              .map((uid) => uid.trim())
              .where((uid) => uid.isNotEmpty),
        );
      _selectedEventGroupId = post.eventGroupId.trim();
      _linkedGroupId = post.linkedGroupId.trim();
      if (_linkedGroupId.isNotEmpty) {
        _hydrateLinkedGroupLabel(_linkedGroupId);
      }
      _audience =
          (post.audience.trim().isNotEmpty ? post.audience : 'public').trim();

      _editableExistingMediaUrls = _existingMediaUrlsForEdit();
    }
  }

  Future<void> _hydrateLinkedGroupLabel(String groupId) async {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(normalizedGroupId)
          .get();
      if (!mounted || !doc.exists) {
        return;
      }

      final data = doc.data() ?? <String, dynamic>{};
      final name = ((data['groupName'] as String?) ?? '').trim();
      final isPublic = (data['isPublic'] as bool?) ?? false;

      setState(() {
        if (_linkedGroupId != normalizedGroupId) {
          return;
        }
        _linkedGroupLabel = name;
        _linkedGroupIsPublic = isPublic;
      });
    } catch (_) {
      // Keep silent: group name is optional in editor UI.
    }
  }

  Future<void> _hydrateMissingVideoPreviews() async {
    for (var index = 0; index < _draftMediaItems.length; index++) {
      final item = _draftMediaItems[index];
      if (!item.isVideo || item.previewBytes != null) {
        continue;
      }

      final previewBytes = await buildVideoPreviewBytes(item.file);
      if (!mounted) {
        return;
      }
      if (previewBytes == null) {
        continue;
      }
      setState(() {
        _draftMediaItems[index] = item.copyWith(previewBytes: previewBytes);
      });
    }
  }

  void _goToMediaIndex(int index) {
    if (index < 0 || index >= _draftMediaItems.length) {
      return;
    }
    setState(() {
      _currentMediaIndex = index;
    });
    _mediaPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _seedDraftMediaItems() {
    if (widget.selectedMediaItems != null &&
        widget.selectedMediaItems!.isNotEmpty) {
      _draftMediaItems =
          List<PostUploadMediaItem>.from(widget.selectedMediaItems!);
      return;
    }

    if (widget.selectedMedia != null) {
      _draftMediaItems = <PostUploadMediaItem>[
        PostUploadMediaItem(
          file: widget.selectedMedia!,
          previewBytes: widget.mediaBytes,
          type: _isVideoFile(widget.selectedMedia!) ? 'video' : 'image',
        ),
      ];
    }

    _editableExistingMediaUrls = _existingMediaUrlsForEdit();
  }

  bool _isVideoFile(XFile file) {
    final lower =
        (file.name.isNotEmpty ? file.name : file.path).trim().toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv');
  }

  Future<void> _loadFriends() async {
    setState(() {
      _friendsLoading = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        if (!mounted) return;
        setState(() {
          _allFriends.clear();
          _filteredFriends = const <_FriendOption>[];
          _friendsLoading = false;
        });
        return;
      }

      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? <String, dynamic>{};
      final friendsRaw =
          (userData['friends'] as List<dynamic>?) ?? const <dynamic>[];
      final followingRaw =
          (userData['following'] as List<dynamic>?) ?? const <dynamic>[];

      final ids = (friendsRaw.isNotEmpty ? friendsRaw : followingRaw)
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);

      final loaded = <_FriendOption>[];
      for (final friendUid in ids) {
        final profile = await _publicUserProfileService.fetchProfile(friendUid);
        final name = (profile?.displayName ?? '').trim().isNotEmpty
            ? profile!.displayName
            : ((profile?.username ?? '').trim().isNotEmpty
                ? profile!.username
                : friendUid);
        loaded.add(
          _FriendOption(
            uid: friendUid,
            name: name,
            avatarUrl: (profile?.profilePictureUrl ?? '').trim(),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _allFriends
          ..clear()
          ..addAll(loaded);
        _filteredFriends = List<_FriendOption>.from(loaded);
        _friendsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _allFriends.clear();
        _filteredFriends = const <_FriendOption>[];
        _friendsLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _locationController.dispose();
    _mediaPageController.dispose();
    super.dispose();
  }

  void _openAddFriends() async {
    final isLight = _isLight(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: MediaQuery.of(context).viewInsets,
              child: Container(
                height: 420,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isLight ? Colors.white : const Color(0xFF0B1019),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      color: isLight ? const Color(0xFFA9C3FF) : Colors.white12,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) {
                        final query = value.trim();
                        setModalState(() {
                          _filteredFriends = _allFriends.where((friend) {
                            if (query.isEmpty) {
                              return true;
                            }
                            return friend.name.contains(query);
                          }).toList(growable: false);
                        });
                      },
                      style: TextStyle(
                          color: isLight ? Colors.black : Colors.white),
                      decoration: InputDecoration(
                        hintText: 'חפש חברים',
                        hintStyle: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white54,
                        ),
                        border: const OutlineInputBorder(
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: isLight
                            ? const Color(0xFFF4F8FF)
                            : const Color(0xFF1E2632),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _friendsLoading
                          ? const Center(child: CircularProgressIndicator())
                          : (_filteredFriends.isEmpty
                              ? const Center(
                                  child: Text(
                                    'אין חברים להצגה',
                                    style: TextStyle(color: Colors.black54),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _filteredFriends.length,
                                  itemBuilder: (context, index) {
                                    final friend = _filteredFriends[index];
                                    final selected = _selectedFriendUids
                                        .contains(friend.uid);
                                    final initial = friend.name.isNotEmpty
                                        ? friend.name[0]
                                        : 'U';
                                    return ListTile(
                                      tileColor: isLight
                                          ? const Color(0xFFF9FBFF)
                                          : null,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: BorderSide(
                                          color: isLight
                                              ? const Color(0xFFA9C3FF)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      leading: CircleAvatar(
                                        backgroundColor: (isLight
                                            ? const Color(0xFFE6EEFF)
                                            : const Color(0xFF9E7CFF)),
                                        backgroundImage:
                                            friend.avatarUrl.isNotEmpty
                                                ? NetworkImage(friend.avatarUrl)
                                                : null,
                                        child: friend.avatarUrl.isEmpty
                                            ? Text(
                                                initial,
                                                style: const TextStyle(
                                                    color: Colors.black),
                                              )
                                            : null,
                                      ),
                                      title: Text(
                                        friend.name,
                                        style: TextStyle(
                                            color: isLight
                                                ? Colors.black
                                                : Colors.white),
                                      ),
                                      trailing: IconButton(
                                        icon: Icon(
                                          selected
                                              ? Icons.check_box
                                              : Icons.check_box_outline_blank,
                                          color: selected
                                              ? const Color(0xFF9E7CFF)
                                              : (isLight
                                                  ? Colors.black38
                                                  : Colors.white30),
                                        ),
                                        onPressed: () {
                                          setModalState(() {
                                            setState(() {
                                              if (selected) {
                                                _selectedFriendUids
                                                    .remove(friend.uid);
                                              } else {
                                                _selectedFriendUids
                                                    .add(friend.uid);
                                              }
                                            });
                                          });
                                        },
                                      ),
                                    );
                                  },
                                )),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9E7CFF),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'בוצע',
                        style: TextStyle(
                            color: isLight ? Colors.white : Colors.black),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openCropEditor() async {
    if (_draftMediaItems.isEmpty ||
        _currentMediaIndex < 0 ||
        _currentMediaIndex >= _draftMediaItems.length) {
      return;
    }

    final currentItem = _draftMediaItems[_currentMediaIndex];
    if (currentItem.isVideo || currentItem.previewBytes == null) {
      return;
    }

    var draftScale = currentItem.cropScale;
    var draftAlignmentX = currentItem.cropAlignmentX;
    var draftAlignmentY = currentItem.cropAlignmentY;
    var draftFrameScale = 1.0;
    final isLight = _isLight(context);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return FractionallySizedBox(
              heightFactor: 0.86,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'חתוך את המדיה',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            double frameHeight = constraints.maxHeight;
                            double frameWidth = frameHeight * 9 / 16;
                            final maxAllowedWidth = constraints.maxWidth;
                            if (frameWidth > maxAllowedWidth) {
                              frameWidth = maxAllowedWidth;
                              frameHeight = frameWidth * 16 / 9;
                            }

                            frameWidth *= draftFrameScale;
                            frameHeight *= draftFrameScale;

                            final maxDx =
                                ((constraints.maxWidth - frameWidth) / 2)
                                    .clamp(0.0, double.infinity);
                            final maxDy = (constraints.maxHeight - frameHeight)
                                .clamp(0.0, double.infinity);

                            final frameOffset = Offset(
                              maxDx == 0 ? 0 : draftAlignmentX * maxDx,
                              maxDy == 0
                                  ? 0
                                  : ((draftAlignmentY + 1) / 2) * maxDy,
                            );

                            Rect frameRectFor(Offset offset) {
                              final left =
                                  ((constraints.maxWidth - frameWidth) / 2) +
                                      offset.dx;
                              return Rect.fromLTWH(
                                left,
                                offset.dy,
                                frameWidth,
                                frameHeight,
                              );
                            }

                            final frameRect = frameRectFor(frameOffset);

                            return ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: const BoxDecoration(
                                        color: Colors.black,
                                      ),
                                      child: Transform.scale(
                                        scale: draftScale,
                                        child: Image.memory(
                                          currentItem.previewBytes!,
                                          fit: BoxFit.cover,
                                          alignment: const Alignment(0, 0),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    right: 0,
                                    height: frameRect.top,
                                    child: Container(
                                      color:
                                          Colors.black.withOpacity( 0.48),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    top: frameRect.bottom,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      color:
                                          Colors.black.withOpacity( 0.48),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    top: frameRect.top,
                                    width: frameRect.left,
                                    height: frameRect.height,
                                    child: Container(
                                      color:
                                          Colors.black.withOpacity( 0.48),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: frameRect.top,
                                    width:
                                        constraints.maxWidth - frameRect.right,
                                    height: frameRect.height,
                                    child: Container(
                                      color:
                                          Colors.black.withOpacity( 0.48),
                                    ),
                                  ),
                                  Positioned(
                                    left: frameRect.left,
                                    top: frameRect.top,
                                    width: frameRect.width,
                                    height: frameRect.height,
                                    child: GestureDetector(
                                      onPanUpdate: (details) {
                                        setModalState(() {
                                          final nextDx = (frameOffset.dx +
                                                  details.delta.dx)
                                              .clamp(-maxDx, maxDx);
                                          final nextDy = (frameOffset.dy +
                                                  details.delta.dy)
                                              .clamp(0.0, maxDy);
                                          draftAlignmentX = maxDx == 0
                                              ? 0
                                              : (nextDx / maxDx)
                                                  .clamp(-1.0, 1.0);
                                          draftAlignmentY = maxDy == 0
                                              ? 0
                                              : ((nextDy / maxDy) * 2 - 1)
                                                  .clamp(-1.0, 1.0);
                                        });
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 2,
                                          ),
                                        ),
                                        child: Stack(
                                          children: [
                                            const Positioned(
                                              top: 10,
                                              right: 10,
                                              child: Icon(
                                                Icons.open_with_rounded,
                                                color: Colors.white,
                                                size: 18,
                                              ),
                                            ),
                                            Positioned(
                                              left: 12,
                                              right: 12,
                                              bottom: 12,
                                              child: Container(
                                                height: 2,
                                                color: Colors.white54,
                                              ),
                                            ),
                                            Positioned(
                                              top: 12,
                                              bottom: 12,
                                              left: frameRect.width / 2,
                                              child: Container(
                                                width: 2,
                                                color: Colors.white54,
                                              ),
                                            ),
                                            Positioned(
                                              top: frameRect.height / 3,
                                              left: 12,
                                              right: 12,
                                              child: Container(
                                                height: 2,
                                                color: Colors.white24,
                                              ),
                                            ),
                                            Positioned(
                                              bottom: frameRect.height / 3,
                                              left: 12,
                                              right: 12,
                                              child: Container(
                                                height: 2,
                                                color: Colors.white24,
                                              ),
                                            ),
                                            Positioned(
                                              top: 12,
                                              bottom: 12,
                                              right: frameRect.width / 3,
                                              child: Container(
                                                width: 2,
                                                color: Colors.white24,
                                              ),
                                            ),
                                            Positioned(
                                              top: 12,
                                              bottom: 12,
                                              left: frameRect.width / 3,
                                              child: Container(
                                                width: 2,
                                                color: Colors.white24,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'זום: ${draftScale.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                        ),
                      ),
                      Slider(
                        value: draftScale,
                        min: 1,
                        max: 4,
                        activeColor: const Color(0xFF9E7CFF),
                        onChanged: (value) {
                          setModalState(() {
                            draftScale = value;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'גודל מסגרת: ${(draftFrameScale * 100).round()}%',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                        ),
                      ),
                      Slider(
                        value: draftFrameScale,
                        min: 0.45,
                        max: 1,
                        activeColor: const Color(0xFF53C1F9),
                        onChanged: (value) {
                          setModalState(() {
                            draftFrameScale = value;
                          });
                        },
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: isLight
                                      ? const Color(0xFFA9C3FF)
                                      : Colors.white24,
                                ),
                                foregroundColor:
                                    isLight ? Colors.black : Colors.white,
                              ),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: const Text('ביטול'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF9E7CFF),
                                foregroundColor:
                                    isLight ? Colors.white : Colors.black,
                              ),
                              onPressed: () {
                                setState(() {
                                  _draftMediaItems[_currentMediaIndex] =
                                      currentItem.copyWith(
                                    cropScale: (draftScale / draftFrameScale)
                                        .clamp(1, 8),
                                    cropAlignmentX: draftAlignmentX,
                                    cropAlignmentY: draftAlignmentY,
                                  );
                                });
                                Navigator.of(sheetContext).pop();
                              },
                              child: const Text('שמור חיתוך'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _pickExistingEvent() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return;
    }

    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (sheetContext) {
        final isLight = _isLight(sheetContext);
        final scrollController = ScrollController();
        final items = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
        var isLoading = false;
        var hasMore = true;
        var isScrollListenerAttached = false;

        Future<void> loadMore(StateSetter setModalState) async {
          if (isLoading || !hasMore) {
            return;
          }
          setModalState(() {
            isLoading = true;
          });

          try {
            while (hasMore) {
              Query<Map<String, dynamic>> query = FirebaseFirestore.instance
                  .collection('posts')
                  .where('authorId', isEqualTo: currentUser.uid)
                  .orderBy('createdAt', descending: true)
                  .limit(18);
              if (cursor != null) {
                query = query.startAfterDocument(cursor!);
              }

              final snapshot = await query.get();
              if (snapshot.docs.isEmpty) {
                hasMore = false;
                break;
              }

              cursor = snapshot.docs.last;
              if (snapshot.docs.length < 18) {
                hasMore = false;
              }

              final filtered = snapshot.docs.where((doc) {
                final data = doc.data();
                final status = (data['status'] as String? ?? 'published')
                    .trim()
                    .toLowerCase();
                return status == 'published';
              }).toList(growable: false);

              if (filtered.isNotEmpty) {
                setModalState(() {
                  items.addAll(filtered);
                });
                break;
              }
            }
          } finally {
            setModalState(() {
              isLoading = false;
            });
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!isScrollListenerAttached) {
              isScrollListenerAttached = true;
              scrollController.addListener(() {
                if (scrollController.position.pixels >=
                    scrollController.position.maxScrollExtent - 320) {
                  if (sheetContext.mounted) {
                    loadMore(setModalState);
                  }
                }
              });
            }

            if (items.isEmpty && !isLoading) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (sheetContext.mounted) {
                  loadMore(setModalState);
                }
              });
            }

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 760),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.all(1.8),
                child: Container(
                  height: MediaQuery.of(sheetContext).size.height * 0.78,
                  decoration: BoxDecoration(
                    color: isLight ? Colors.white : const Color(0xFF0B1019),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton(
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.black,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'תבחר לאיזה אירוע לצרף את הפוסט שלך',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width:
                                    MediaQuery.of(sheetContext).size.width < 390
                                        ? 32
                                        : 48,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: items.isEmpty && isLoading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : items.isEmpty
                                    ? Center(
                                        child: Text(
                                          'לא נמצאו פוסטים תואמים לאירוע קיים',
                                          style: TextStyle(
                                            color: isLight
                                                ? Colors.black54
                                                : Colors.white,
                                          ),
                                        ),
                                      )
                                    : GridView.builder(
                                        controller: scrollController,
                                        itemCount:
                                            items.length + (hasMore ? 1 : 0),
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount:
                                              MediaQuery.of(sheetContext)
                                                          .size
                                                          .width <
                                                      390
                                                  ? 2
                                                  : 3,
                                          crossAxisSpacing: 10,
                                          mainAxisSpacing: 10,
                                          childAspectRatio: 0.72,
                                        ),
                                        itemBuilder: (context, index) {
                                          if (index >= items.length) {
                                            return const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            );
                                          }
                                          final doc = items[index];
                                          final data = doc.data();
                                          final title =
                                              (data['title'] as String? ?? '')
                                                  .trim();
                                          return FutureBuilder<
                                              _EventPickerPreviewMedia>(
                                            future:
                                                _eventPickerPreviewMedia(data),
                                            builder: (context, snapshot) {
                                              final previewMedia = snapshot
                                                      .data ??
                                                  const _EventPickerPreviewMedia(
                                                    thumbnailUrl: '',
                                                    videoUrl: '',
                                                  );

                                              return InkWell(
                                                onTap: () {
                                                  Navigator.of(sheetContext)
                                                      .pop(
                                                    <String, dynamic>{
                                                      'postId': doc.id,
                                                      'eventGroupId':
                                                          (data['eventGroupId']
                                                                      as String? ??
                                                                  '')
                                                              .trim(),
                                                      'title': title,
                                                      'category': (data[
                                                                      'category']
                                                                  as String? ??
                                                              '')
                                                          .trim(),
                                                      'subCategory':
                                                          (data['subCategory']
                                                                      as String? ??
                                                                  '')
                                                              .trim(),
                                                    },
                                                  );
                                                },
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                  child: Container(
                                                    color: isLight
                                                        ? const Color(
                                                            0xFFF9FBFF)
                                                        : const Color(
                                                            0xFF171F2D),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .stretch,
                                                      children: [
                                                        Expanded(
                                                          child: Stack(
                                                            fit:
                                                                StackFit.expand,
                                                            children: [
                                                              if (previewMedia
                                                                  .hasThumbnail)
                                                                Image.network(
                                                                  previewMedia
                                                                      .thumbnailUrl,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  errorBuilder:
                                                                      (_, __,
                                                                          ___) {
                                                                    return previewMedia
                                                                            .hasVideo
                                                                        ? _buildEventPickerVideoPoster(
                                                                            isLight:
                                                                                isLight,
                                                                          )
                                                                        : Container(
                                                                            color: isLight
                                                                                ? const Color(0xFFEFF5FF)
                                                                                : const Color(0xFF1E2632),
                                                                          );
                                                                  },
                                                                )
                                                              else if (previewMedia
                                                                  .hasVideo)
                                                                FutureBuilder<
                                                                    Uint8List?>(
                                                                  future:
                                                                      buildVideoPreviewBytesFromSource(
                                                                    previewMedia
                                                                        .videoUrl,
                                                                  ),
                                                                  builder: (
                                                                    context,
                                                                    snapshot,
                                                                  ) {
                                                                    final bytes =
                                                                        snapshot
                                                                            .data;
                                                                    if (bytes !=
                                                                        null) {
                                                                      return Image
                                                                          .memory(
                                                                        bytes,
                                                                        fit: BoxFit
                                                                            .cover,
                                                                      );
                                                                    }

                                                                    return _buildEventPickerVideoPoster(
                                                                      isLight:
                                                                          isLight,
                                                                    );
                                                                  },
                                                                )
                                                              else
                                                                Container(
                                                                  color: isLight
                                                                      ? const Color(
                                                                          0xFFEFF5FF)
                                                                      : const Color(
                                                                          0xFF1E2632),
                                                                ),
                                                              if (previewMedia
                                                                  .hasVideo)
                                                                Positioned(
                                                                  right: 6,
                                                                  bottom: 6,
                                                                  child:
                                                                      Container(
                                                                    padding:
                                                                        const EdgeInsets
                                                                            .all(
                                                                            4),
                                                                    decoration:
                                                                        BoxDecoration(
                                                                      color: Colors
                                                                          .black
                                                                          .withOpacity( 0.58),
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                              999),
                                                                    ),
                                                                    child:
                                                                        const Icon(
                                                                      Icons
                                                                          .videocam_rounded,
                                                                      color: Colors
                                                                          .white,
                                                                      size: 14,
                                                                    ),
                                                                  ),
                                                                ),
                                                            ],
                                                          ),
                                                        ),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(8),
                                                          child: Text(
                                                            title.isNotEmpty
                                                                ? title
                                                                : 'אירוע ללא כותרת',
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color: isLight
                                                                  ? Colors.black
                                                                  : Colors
                                                                      .white,
                                                              fontSize: 12,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          );
                                        },
                                      ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (!mounted || selected == null) {
      return;
    }

    setState(() {
      final eventGroupId = (selected['eventGroupId'] as String? ?? '').trim();
      final postId = (selected['postId'] as String? ?? '').trim();
      _selectedEventGroupId = eventGroupId.isNotEmpty ? eventGroupId : postId;
      _selectedEventSourcePostId = postId;
      _selectedEventLabel = (selected['title'] as String? ?? '').trim();
      _linkToExistingEvent = _selectedEventGroupId.isNotEmpty;
      _applyEventSourceCategory(
        postCategory: (selected['category'] as String? ?? '').trim(),
        postSubCategory: (selected['subCategory'] as String? ?? '').trim(),
      );
    });
  }

  void _applyEventSourceCategory({
    required String postCategory,
    required String postSubCategory,
  }) {
    final normalizedCategory = postCategory.trim();
    final normalizedSubCategory = postSubCategory.trim();

    if (normalizedCategory.isEmpty || isGeneralCategory(normalizedCategory)) {
      _mainCategory = kGeneralCategory;
      _subCategory = null;
      return;
    }

    _mainCategory = normalizedCategory;
    final subCategories = appSubCategories(_mainCategory);
    if (subCategories.isEmpty) {
      _subCategory = null;
      return;
    }

    if (normalizedSubCategory.isNotEmpty &&
        subCategories.contains(normalizedSubCategory)) {
      _subCategory = normalizedSubCategory;
      return;
    }

    _subCategory = subCategories.contains('אחר') ? 'אחר' : subCategories.first;
  }

  Future<String?> _resolvePreviewMediaUrl(String source) async {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      return null;
    }

    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return normalized;
    }

    try {
      if (normalized.startsWith('gs://')) {
        return await FirebaseStorage.instance
            .refFromURL(normalized)
            .getDownloadURL();
      }

      return await FirebaseStorage.instance.ref(normalized).getDownloadURL();
    } catch (_) {
      return normalized;
    }
  }

  Future<String?> _resolvedPreviewUrlFuture(String source) {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      return Future<String?>.value(null);
    }

    return _resolvedPreviewUrlFutureBySource.putIfAbsent(
      normalized,
      () => _resolvePreviewMediaUrl(normalized),
    );
  }

  Future<_EventPickerPreviewMedia> _eventPickerPreviewMedia(
      Map<String, dynamic> data) async {
    String normalized(dynamic value) => (value as String? ?? '').trim();

    final thumbnailUrl = normalized(data['thumbnailUrl']);
    final videoThumbnailUrl = normalized(data['videoThumbnailUrl']);
    final imageUrl = normalized(data['imageUrl']);
    final mediaUrl = normalized(data['mediaUrl']);

    String firstVideoUrl = '';

    final mediaItems = postMediaItemsFromData(data);

    for (final item in mediaItems) {
      final itemUrl = (await _resolvedPreviewUrlFuture(item.url)) ?? item.url;
      final looksLikeVideo = item.isVideo || isVideoMediaUrl(itemUrl);
      if (looksLikeVideo) {
        if (firstVideoUrl.isEmpty && itemUrl.isNotEmpty) {
          firstVideoUrl = itemUrl;
        }
        continue;
      }

      if (itemUrl.isNotEmpty) {
        return _EventPickerPreviewMedia(thumbnailUrl: itemUrl, videoUrl: '');
      }
    }

    for (final candidate in <String>[
      videoThumbnailUrl,
      thumbnailUrl,
      imageUrl,
      mediaUrl,
      ...((data['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)),
    ]) {
      final resolved = await _resolvedPreviewUrlFuture(candidate) ?? candidate;
      if (resolved.isEmpty) {
        continue;
      }

      if (!isVideoMediaUrl(resolved)) {
        return _EventPickerPreviewMedia(thumbnailUrl: resolved, videoUrl: '');
      }

      if (firstVideoUrl.isEmpty) {
        firstVideoUrl = resolved;
      }
    }

    if (firstVideoUrl.isNotEmpty) {
      return _EventPickerPreviewMedia(
          thumbnailUrl: '', videoUrl: firstVideoUrl);
    }

    return const _EventPickerPreviewMedia(thumbnailUrl: '', videoUrl: '');
  }

  Future<void> _ensureSelectedSourcePostInEventGroup() async {
    if (!_linkToExistingEvent) {
      return;
    }

    final eventGroupId = _selectedEventGroupId.trim();
    final sourcePostId = _selectedEventSourcePostId.trim();
    if (eventGroupId.isEmpty || sourcePostId.isEmpty) {
      return;
    }

    try {
      final sourceRef =
          FirebaseFirestore.instance.collection('posts').doc(sourcePostId);
      final sourceSnap = await sourceRef.get();
      if (!sourceSnap.exists) {
        return;
      }

      final data = sourceSnap.data() ?? <String, dynamic>{};
      final current = (data['eventGroupId'] as String? ?? '').trim();
      if (current == eventGroupId) {
        return;
      }

      if (current.isNotEmpty && current != eventGroupId) {
        return;
      }

      await sourceRef.set(
        <String, dynamic>{
          'eventGroupId': eventGroupId,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // Do not block publish if source sync fails.
    }
  }

  Future<void> _pickLinkedGroup() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || currentUser.uid.trim().isEmpty) {
      return;
    }

    Future<List<Map<String, dynamic>>> loadLinkedGroups() async {
      final uid = currentUser.uid.trim();
      bool isDirectChat(Map<String, dynamic> data) {
        final isPublic = (data['isPublic'] as bool?) ?? false;
        final participants = List<String>.from(
          (data['participants'] as List<dynamic>?) ?? const <String>[],
        );
        return (data['isDirect'] as bool?) ??
            (!isPublic && participants.length == 2);
      }

      DateTime activityDate(Map<String, dynamic> data) {
        final lastMessageAt = data['lastMessageAt'];
        if (lastMessageAt is Timestamp) {
          return lastMessageAt.toDate();
        }
        final updatedAt = data['updatedAt'];
        if (updatedAt is Timestamp) {
          return updatedAt.toDate();
        }
        final createdAt = data['createdAt'];
        if (createdAt is Timestamp) {
          return createdAt.toDate();
        }
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      final chatsSnapshot = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: uid)
          .get();

      final groupItems = <Map<String, dynamic>>[];
      for (final chatDoc in chatsSnapshot.docs) {
        final data = chatDoc.data();
        if (isDirectChat(data)) {
          continue;
        }

        final sourceGroupId = (data['sourceGroupId'] as String? ?? '').trim();
        final targetGroupId =
            sourceGroupId.isNotEmpty ? sourceGroupId : chatDoc.id;
        final name = (data['name'] as String? ?? '').trim();

        groupItems.add(<String, dynamic>{
          'id': targetGroupId,
          'groupName': name,
          'name': name,
          'isPublic': (data['isPublic'] as bool?) ?? false,
          'activityDate': activityDate(data),
        });
      }

      groupItems.sort((a, b) {
        final aDate = (a['activityDate'] as DateTime?) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bDate = (b['activityDate'] as DateTime?) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bDate.compareTo(aDate);
      });

      return groupItems;
    }

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isLight = _isLight(sheetContext);
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            decoration: BoxDecoration(
              color: isLight ? Colors.white : const Color(0xFF101826),
              border: Border.all(
                color: isLight ? const Color(0xFFA9C3FF) : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(22),
            ),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.72,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'קישור קבוצה לפוסט',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'בחר קבוצה שאתה חבר בה',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isLight ? Colors.black54 : Colors.white60,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: loadLinkedGroups(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final docs =
                          snapshot.data ?? const <Map<String, dynamic>>[];
                      if (snapshot.hasError) {
                        return Center(
                          child: Text(
                            'שגיאה בטעינת הקבוצות',
                            style: TextStyle(
                              color: isLight ? Colors.black54 : Colors.white70,
                            ),
                          ),
                        );
                      }
                      if (docs.isEmpty) {
                        return Center(
                          child: Text(
                            'אין קבוצות זמינות לקישור',
                            style: TextStyle(
                              color: isLight ? Colors.black54 : Colors.white70,
                            ),
                          ),
                        );
                      }

                      return ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final groupName =
                              ((doc['groupName'] as String?) ?? '').trim();
                          final fallbackName =
                              ((doc['name'] as String?) ?? '').trim();
                          final label =
                              groupName.isNotEmpty ? groupName : fallbackName;
                          final isPublic = (doc['isPublic'] as bool?) ?? false;

                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: isLight
                                    ? const Color(0xFFA9C3FF)
                                    : Colors.transparent,
                              ),
                            ),
                            tileColor: isLight
                                ? const Color(0xFFF8FBFF)
                                : const Color(0xFF1A2435),
                            leading: CircleAvatar(
                              backgroundColor: isLight
                                  ? const Color(0xFFE6EEFF)
                                  : const Color(0xFF9E7CFF),
                              child: Icon(
                                isPublic
                                    ? Icons.public_rounded
                                    : Icons.lock_outline_rounded,
                                color: isLight
                                    ? const Color(0xFF5A6CFF)
                                    : Colors.white,
                              ),
                            ),
                            title: Text(
                              label.isNotEmpty ? label : 'קבוצה ללא שם',
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              isPublic ? 'קבוצה ציבורית' : 'קבוצה פרטית',
                              style: TextStyle(
                                color:
                                    isLight ? Colors.black54 : Colors.white60,
                              ),
                            ),
                            onTap: () {
                              Navigator.of(sheetContext).pop(<String, dynamic>{
                                'groupId': (doc['id'] as String? ?? '').trim(),
                                'groupName': label,
                                'isPublic': isPublic,
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop(<String, dynamic>{
                      'groupId': '',
                      'groupName': '',
                      'isPublic': false,
                    });
                  },
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('הסר קישור קבוצה'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || selected == null) {
      return;
    }

    setState(() {
      _linkedGroupId = (selected['groupId'] as String? ?? '').trim();
      _linkedGroupLabel = (selected['groupName'] as String? ?? '').trim();
      _linkedGroupIsPublic = (selected['isPublic'] as bool?) ?? false;
    });
  }

  Widget _buildLinkedGroupSelector() {
    final isLight = _isLight(context);
    final hasLinkedGroup = _linkedGroupId.isNotEmpty;
    final subtitle = hasLinkedGroup
        ? (_linkedGroupIsPublic ? 'ציבורית' : 'פרטית')
        : 'לא נבחרה קבוצה';

    return ListTile(
      tileColor: _surfaceColor(context),
      leading: Icon(
        hasLinkedGroup ? Icons.link_rounded : Icons.group_work_outlined,
        color: isLight ? Colors.black : Colors.white,
      ),
      title: Text(
        'קישור קבוצה',
        style: TextStyle(color: _primaryTextColor(context)),
      ),
      subtitle: Text(
        hasLinkedGroup
            ? '${_linkedGroupLabel.isNotEmpty ? _linkedGroupLabel : 'קבוצה נבחרה'} • $subtitle'
            : subtitle,
        style: TextStyle(color: _secondaryTextColor(context)),
      ),
      trailing: IconButton(
        icon: Icon(
          Icons.chevron_right,
          color: _secondaryTextColor(context),
        ),
        onPressed: _pickLinkedGroup,
      ),
      onTap: _pickLinkedGroup,
    );
  }

  List<_CategoryChoiceOption> _mainCategoryOptions() {
    return appMainCategories
        .where(
          (category) =>
              category.trim().isNotEmpty && !isGeneralCategory(category),
        )
        .map(
          (category) => _CategoryChoiceOption(
            value: category,
            label: category,
          ),
        )
        .toList(growable: false);
  }

  List<_CategoryChoiceOption> _subCategoryOptionsFor(String category) {
    final options = <_CategoryChoiceOption>[];
    final seenValues = <String>{};

    for (final subCategory in appSubCategories(category)) {
      final normalized = subCategory.trim();
      if (normalized.isEmpty || !seenValues.add(normalized)) {
        continue;
      }
      options.add(
        _CategoryChoiceOption(
          value: normalized,
          label: normalized,
          points: pointsForCategory(
            category: category,
            subCategory: normalized,
          ),
        ),
      );
    }

    if (seenValues.add('אחר')) {
      options.add(
        _CategoryChoiceOption(
          value: 'אחר',
          label: 'אחר',
          points: pointsForCategory(category: category, subCategory: 'אחר'),
        ),
      );
    }

    return options;
  }

  Future<String?> _showChoiceDialog({
    required String title,
    required String subtitle,
    required List<_CategoryChoiceOption> options,
    String? selectedValue,
    bool showPoints = false,
    bool showLeadingIcon = true,
  }) {
    final isLight = _isLight(context);

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) {
        final mediaSize = MediaQuery.of(dialogContext).size;
        final dialogWidth =
            mediaSize.width > 680 ? 620.0 : mediaSize.width - 24;

        return Material(
          color: Colors.transparent,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: dialogWidth,
                    maxHeight: mediaSize.height * 0.82,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(1.8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isLight
                            ? const Color(0xFFF8FBFF)
                            : const Color(0xFF101826),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: isLight
                                        ? const Color(0xFF33405B)
                                        : Colors.white70,
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
                                        title,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF1E2A45)
                                              : Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitle,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF596682)
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 46),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 14,
                                  runSpacing: 14,
                                  children: options.map((option) {
                                    final isSelected =
                                        option.value == selectedValue;
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => Navigator.of(dialogContext)
                                            .pop(option.value),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 160),
                                          curve: Curves.easeOut,
                                          width: 116,
                                          height: 116,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: const LinearGradient(
                                              colors: [
                                                Color(0xFF8DE8FF),
                                                Color(0xFFC9B5FF),
                                              ],
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                            ),
                                            border: Border.all(
                                              color: isSelected
                                                  ? const Color(0xFF8D78FF)
                                                  : Colors.white
                                                      .withOpacity( 0.72),
                                              width: isSelected ? 1.8 : 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF76CFFF)
                                                    .withOpacity(
                                                      isSelected ? 0.42 : 0.32,
                                                ),
                                                blurRadius:
                                                    isSelected ? 18 : 14,
                                                offset: const Offset(0, 7),
                                              ),
                                            ],
                                          ),
                                          child: Stack(
                                            children: [
                                              if (showLeadingIcon)
                                                Positioned(
                                                  top: 16,
                                                  left: 0,
                                                  right: 0,
                                                  child: Icon(
                                                    categoryIconFor(
                                                        option.value),
                                                    color:
                                                        const Color(0xFF2A2361),
                                                    size: 28,
                                                  ),
                                                )
                                              else
                                                const Positioned(
                                                  top: 16,
                                                  left: 0,
                                                  right: 0,
                                                  child: Icon(
                                                    Icons.category_rounded,
                                                    color: Color(0xFF2A2361),
                                                    size: 28,
                                                  ),
                                                ),
                                              if (showPoints &&
                                                  option.points != null)
                                                Positioned(
                                                  top: 10,
                                                  right: 6,
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 8,
                                                      vertical: 4,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
                                                      gradient:
                                                          const LinearGradient(
                                                        colors: [
                                                          Color(0xFFFFA24D),
                                                          Color(0xFFFFF6EA),
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      ),
                                                      border: Border.all(
                                                        color: Colors.white
                                                            .withOpacity( 0.78),
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: const Color(
                                                                  0xFFFFB76A)
                                                              .withOpacity( 0.28),
                                                          blurRadius: 10,
                                                          offset: const Offset(
                                                              0, 4),
                                                        ),
                                                      ],
                                                    ),
                                                    child: Text(
                                                      '${option.points}',
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFF8C4300),
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              Center(
                                                child: Padding(
                                                  padding: EdgeInsets.fromLTRB(
                                                    10,
                                                    showLeadingIcon ? 52 : 52,
                                                    10,
                                                    12,
                                                  ),
                                                  child: Text(
                                                    option.label,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: const Color(
                                                          0xFF2A2361),
                                                      fontSize:
                                                          isLight ? 12 : 11.8,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      height: 1.1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(growable: false),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openMainCategoryPicker() async {
    final selected = await _showChoiceDialog(
      title: 'בחר קטגוריה',
      subtitle: 'הקטגוריה תקבע את תת-הקטגוריה והניקוד',
      options: _mainCategoryOptions(),
      selectedValue: _mainCategory != null && !isGeneralCategory(_mainCategory)
          ? _mainCategory
          : null,
    );

    if (!mounted || selected == null) {
      return;
    }

    _onMainCategoryChanged(selected);

    final subCategoryOptions = _subCategoryOptionsFor(selected);
    if (subCategoryOptions.isEmpty || !mounted) {
      return;
    }

    await _openSubCategoryPicker(category: selected);
  }

  Future<void> _openSubCategoryPicker({required String category}) async {
    final normalizedCategory = category.trim();
    if (normalizedCategory.isEmpty || isGeneralCategory(normalizedCategory)) {
      return;
    }

    final selected = await _showChoiceDialog(
      title: normalizedCategory,
      subtitle: 'בחר תת קטגוריה',
      options: _subCategoryOptionsFor(normalizedCategory),
      selectedValue: _subCategory,
      showPoints: true,
      showLeadingIcon: false,
    );

    if (!mounted || selected == null) {
      return;
    }

    _onSubCategoryChanged(selected);
  }

  Widget _buildCategorySelectionCard({
    required String title,
    required String valueText,
    required String hintText,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final isLight = _isLight(context);
    final hasValue = valueText.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF76CFFF).withOpacity( 0.18),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(1.4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFF8FBFF) : const Color(0xFF101826),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
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
                      color: Colors.white.withOpacity( 0.74),
                    ),
                  ),
                  child: Icon(icon, color: const Color(0xFF2A2361), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasValue ? valueText : hintText,
                        style: TextStyle(
                          color: hasValue
                              ? _primaryTextColor(context)
                              : _secondaryTextColor(context),
                          fontSize: 15,
                          fontWeight:
                              hasValue ? FontWeight.w900 : FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_left_rounded,
                  color: _secondaryTextColor(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onMainCategoryChanged(String? value) {
    setState(() {
      final normalized = value?.trim() ?? '';
      if (normalized.isEmpty || isGeneralCategory(normalized)) {
        _mainCategory = kGeneralCategory;
        _subCategory = null;
      } else {
        _mainCategory = normalized;
        final subCategories = _subCategoryOptionsFor(normalized)
            .map((item) => item.value)
            .toList(growable: false);
        _subCategory = subCategories.contains(_subCategory)
            ? _subCategory
            : (subCategories.contains('אחר')
                ? 'אחר'
                : (subCategories.isNotEmpty ? subCategories.first : null));
      }
      _linkToExistingEvent = false;
      _selectedEventGroupId = '';
      _selectedEventSourcePostId = '';
      _selectedEventLabel = '';
    });
  }

  void _onSubCategoryChanged(String? value) {
    setState(() {
      _subCategory = value;
      _linkToExistingEvent = false;
      _selectedEventGroupId = '';
      _selectedEventSourcePostId = '';
      _selectedEventLabel = '';
    });
  }

  Future<void> _submitPost({required String status}) async {
    void showSnackBar(String message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }

    if (widget.isEdit) {
      final postId = (widget.post?.id ?? '').trim();
      final title = _titleController.text.trim();
      final description = _descController.text.trim();
      final category = (_mainCategory ?? kGeneralCategory).trim();
      final subCategory = (_subCategory?.trim().isNotEmpty ?? false)
          ? _subCategory!.trim()
          : (!isGeneralCategory(category) ? 'אחר' : '');
      final location = _locationController.text.trim();
      final normalizedStatus = status.trim().toLowerCase();
      final isPublishingFlow = normalizedStatus == 'published';

      if (postId.isEmpty) {
        showSnackBar('לא ניתן לערוך פוסט ללא מזהה');
        return;
      }
      if (isPublishingFlow && title.isEmpty) {
        showSnackBar('יש להזין כותרת');
        return;
      }
      if (isPublishingFlow && category.isEmpty) {
        showSnackBar('יש לבחור קטגוריה');
        return;
      }

      if (_isPublishing) return;
      setState(() {
        _isPublishing = true;
      });

      try {
        final existingMediaByUrl = <String, PostMediaItem>{
          for (final item in widget.post?.mediaItems ?? const <PostMediaItem>[])
            item.url.trim(): item,
        };
        final persistedMediaItems = _editableExistingMediaUrls
            .map((url) {
              final normalizedUrl = url.trim();
              final existing = existingMediaByUrl[normalizedUrl];
              if (existing != null) {
                return <String, dynamic>{
                  'type': existing.type,
                  'url': existing.url,
                  'storagePath': existing.storagePath,
                  'cropScale': existing.cropScale,
                  'cropAlignmentX': existing.cropAlignmentX,
                  'cropAlignmentY': existing.cropAlignmentY,
                };
              }

              return <String, dynamic>{
                'type': _looksLikeVideoUrl(normalizedUrl) ? 'video' : 'image',
                'url': normalizedUrl,
                'storagePath': '',
                'cropScale': 1,
                'cropAlignmentX': 0,
                'cropAlignmentY': 0,
              };
            })
            .where((item) => (item['url'] as String? ?? '').trim().isNotEmpty)
            .toList(growable: false);

        await _postService.updatePostDetails(
          postId: postId,
          title: title,
          caption: description,
          category: category,
          subCategory: subCategory,
          audience: _audience,
          location: location,
          status: normalizedStatus,
          participantUids: List<String>.from(_selectedFriendUids),
          linkedGroupId: _linkedGroupId,
        );

        await FirebaseFirestore.instance
            .collection('posts')
            .doc(postId)
            .update({
          'mediaUrls': _editableExistingMediaUrls,
          'mediaItems': persistedMediaItems,
          'imageUrl': _editableExistingMediaUrls.isNotEmpty
              ? _editableExistingMediaUrls.first
              : '',
          'mediaUrl': _editableExistingMediaUrls.isNotEmpty
              ? _editableExistingMediaUrls.first
              : '',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (error) {
        if (mounted) {
          setState(() {
            _isPublishing = false;
          });
        }
        showSnackBar('שגיאה בעדכון הפוסט: $error');
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'draft' ? 'הטיוטה נשמרה' : 'הפוסט עודכן בהצלחה',
          ),
          backgroundColor: const Color(0xFF9E7CFF),
        ),
      );
      final authorId = (widget.post?.authorId ?? '').trim();
      final members = <String>{
        if (authorId.isNotEmpty) authorId,
        ..._selectedFriendUids
            .map((uid) => uid.trim())
            .where((uid) => uid.isNotEmpty && uid != authorId),
      };

      Navigator.pop(context, <String, dynamic>{
        'id': postId,
        'title': title,
        'caption': description,
        'description': description,
        'content': description,
        'category': category,
        'subCategory': subCategory,
        'audience': _audience,
        'location': location,
        'status': normalizedStatus,
        'linkedGroupId': _linkedGroupId,
        'mediaUrls': _editableExistingMediaUrls,
        'imageUrl': _editableExistingMediaUrls.isNotEmpty
            ? _editableExistingMediaUrls.first
            : '',
        'mediaUrl': _editableExistingMediaUrls.isNotEmpty
            ? _editableExistingMediaUrls.first
            : '',
        'members': members.toList(growable: false),
        'participants': _selectedFriendUids
            .map((uid) => uid.trim())
            .where((uid) => uid.isNotEmpty)
            .toList(growable: false),
      });
      return;
    }

    if (_draftMediaItems.isEmpty) {
      showSnackBar('יש לבחור מדיה לפני שמירה');
      return;
    }

    final category = (_mainCategory ?? kGeneralCategory).trim();
    final subCategory = (_subCategory?.trim().isNotEmpty ?? false)
        ? _subCategory!.trim()
        : (!isGeneralCategory(category) ? 'אחר' : '');
    final title = _titleController.text.trim();
    final description = _descController.text.trim();
    final normalizedStatus = status.trim().toLowerCase();
    final isPublishingFlow = normalizedStatus == 'published';

    if (isPublishingFlow && title.isEmpty) {
      showSnackBar('יש להזין כותרת');
      return;
    }
    if (isPublishingFlow && category.isEmpty) {
      showSnackBar('יש לבחור קטגוריה');
      return;
    }
    if (_linkToExistingEvent && _selectedEventGroupId.isEmpty) {
      showSnackBar('בחר אירוע קיים לפני פרסום');
      return;
    }

    if (_isPublishing) return;
    setState(() {
      _isPublishing = true;
    });

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null || currentUser.uid.trim().isEmpty) {
        throw StateError('User must be logged in');
      }

      if (isPublishingFlow && description.isEmpty) {
        throw ArgumentError('caption is required');
      }

      await _ensureSelectedSourcePostInEventGroup();

      await _postService.createPost(
        uploadMediaItems: _draftMediaItems,
        title: title,
        caption: description,
        category: category,
        subCategory: subCategory,
        audience: _audience,
        authorId: currentUser.uid,
        members: _selectedFriendUids,
        status: status,
        eventGroupId: _linkToExistingEvent ? _selectedEventGroupId : null,
        linkedGroupId: _linkedGroupId,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'draft' ? 'הטיוטה נשמרה בהצלחה' : 'הפוסט פורסם בהצלחה',
          ),
          backgroundColor: const Color(0xFF9E7CFF),
        ),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const MainUserProfileScreen()),
        (route) => false,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _isPublishing = false;
        });
        showSnackBar('שגיאה בפרסום: $error');
      }
    }
  }

  Future<void> _confirmAndDeletePost() async {
    if (!widget.isEdit) {
      return;
    }

    final postId = (widget.post?.id ?? '').trim();
    if (postId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן למחוק פוסט ללא מזהה')),
      );
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final isLight = _isLight(dialogContext);
        return AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
          title: Text(
            'מחיקת פוסט',
            style: TextStyle(color: _primaryTextColor(dialogContext)),
          ),
          content: Text(
            'האם למחוק את הפוסט לצמיתות? הפעולה אינה ניתנת לשחזור.',
            style: TextStyle(color: _secondaryTextColor(dialogContext)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD94B4B),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('מחק'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true || _isDeleting) {
      return;
    }

    setState(() {
      _isDeleting = true;
    });

    try {
      await _postService.deletePost(postId: postId);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה במחיקת הפוסט: $error')),
        );
      }
      return;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('הפוסט נמחק בהצלחה'),
        backgroundColor: Color(0xFFD94B4B),
      ),
    );

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const MainUserProfileScreen()),
      (route) => false,
    );
  }

  List<PostMediaItem> _existingMediaItemsForEdit() {
    if (!widget.isEdit || widget.post == null) {
      return const <PostMediaItem>[];
    }

    final items = <PostMediaItem>[];
    final seen = <String>{};

    void addItem(PostMediaItem item) {
      final url = item.url.trim();
      if (url.isEmpty || seen.contains(url)) {
        return;
      }
      seen.add(url);
      items.add(item);
    }

    for (final item in widget.post!.mediaItems) {
      addItem(item);
    }

    for (final url in widget.post!.mediaUrls) {
      final normalized = url.trim();
      if (normalized.isEmpty || seen.contains(normalized)) {
        continue;
      }
      addItem(PostMediaItem(
        url: normalized,
        storagePath: '',
        type: _looksLikeVideoUrl(normalized) ? 'video' : 'image',
      ));
    }

    final imageUrl = widget.post!.imageUrl.trim();
    if (imageUrl.isNotEmpty && !seen.contains(imageUrl)) {
      addItem(PostMediaItem(
        url: imageUrl,
        storagePath: '',
        type: _looksLikeVideoUrl(imageUrl) ? 'video' : 'image',
      ));
    }

    return items;
  }

  List<String> _existingMediaUrlsForEdit() {
    if (!widget.isEdit || widget.post == null) {
      return const <String>[];
    }

    final urls = <String>{
      ...widget.post!.mediaUrls.map((url) => url.trim()),
      ...widget.post!.mediaItems.map((item) => item.url.trim()),
      widget.post!.imageUrl.trim(),
    }..removeWhere((url) => url.isEmpty);

    return urls.toList(growable: false);
  }

  bool _looksLikeVideoUrl(String url) {
    final lower = url.trim().toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv');
  }

  Widget _buildExistingMediaFallback({required double previewHeight}) {
    final isLight = _isLight(context);
    final existingItems = _existingMediaItemsForEdit();
    if (existingItems.isEmpty) {
      return SizedBox(
        height: previewHeight,
        child: Container(
          decoration: BoxDecoration(
            color: isLight ? const Color(0xFFEAF2FF) : Colors.white10,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
            ),
          ),
          child: Center(
            child: Text(
              'אין מדיה בפוסט',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: previewHeight,
          decoration: BoxDecoration(
            color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF111927),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'מדיה קיימת בפוסט',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: _primaryTextColor(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: existingItems.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final mediaItem = existingItems[index];
                    final mediaUrl = mediaItem.url.trim();
                    final isVideo =
                        mediaItem.isVideo || _looksLikeVideoUrl(mediaUrl);
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: 92,
                        color: isLight
                            ? const Color(0xFFF7FAFF)
                            : const Color(0xFF1A2334),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (isVideo)
                              FutureBuilder<String?>(
                                future: _resolvedPreviewUrlFuture(mediaUrl),
                                builder: (context, resolvedSnapshot) {
                                  final resolvedUrl =
                                      resolvedSnapshot.data ?? mediaUrl;
                                  return FutureBuilder<Uint8List?>(
                                    future:
                                        _videoPreviewFutureByUrl.putIfAbsent(
                                      resolvedUrl,
                                      () => buildVideoPreviewBytesFromSource(
                                        resolvedUrl,
                                      ),
                                    ),
                                    builder: (context, snapshot) {
                                      final bytes = snapshot.data;
                                      if (bytes != null && bytes.isNotEmpty) {
                                        return Image.memory(
                                          bytes,
                                          fit: BoxFit.cover,
                                        );
                                      }

                                      return Container(
                                        color: isLight
                                            ? const Color(0xFFE9F1FF)
                                            : const Color(0xFF121B2B),
                                        child: Icon(
                                          Icons.play_circle_fill_rounded,
                                          color: isLight
                                              ? const Color(0xFF6A7A99)
                                              : Colors.white54,
                                          size: 30,
                                        ),
                                      );
                                    },
                                  );
                                },
                              )
                            else
                              FutureBuilder<String?>(
                                future: _resolvedPreviewUrlFuture(mediaUrl),
                                builder: (context, resolvedSnapshot) {
                                  final resolvedUrl =
                                      resolvedSnapshot.data ?? mediaUrl;
                                  return Image.network(
                                    resolvedUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Container(
                                        color: isLight
                                            ? const Color(0xFFE9F1FF)
                                            : const Color(0xFF121B2B),
                                        child: Icon(
                                          Icons.broken_image_rounded,
                                          color: isLight
                                              ? const Color(0xFF6A7A99)
                                              : Colors.white54,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            if (isVideo)
                              const Center(
                                child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        if (widget.isEdit) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed:
                (_isPublishing || _isDeleting) ? null : _confirmAndDeletePost,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFD94B4B),
              side: const BorderSide(color: Color(0xFFD94B4B)),
            ),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: const Text('מחיקת הפוסט'),
          ),
        ],
      ],
    );
  }

  Widget _buildLocalMediaPreview(PostUploadMediaItem item) {
    if (item.isVideo) {
      return _InlineEditableVideoPlayer(
        source: item.file.path.isNotEmpty ? item.file.path : item.file.name,
        previewBytes: item.previewBytes,
        showPlayOverlay: true,
        autoplay: false,
      );
    }

    final bytes = item.previewBytes;
    if (bytes == null) {
      return Container(color: const Color(0xFF121926));
    }

    return Transform.scale(
      scale: item.cropScale,
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        alignment: Alignment(item.cropAlignmentX, item.cropAlignmentY),
      ),
    );
  }

  Widget _buildMediaEditor({required double previewHeight}) {
    if (_draftMediaItems.isEmpty) {
      return _buildExistingMediaFallback(previewHeight: previewHeight);
    }

    return Column(
      children: [
        SizedBox(
          height: previewHeight,
          child: Stack(
            children: [
              PageView.builder(
                controller: _mediaPageController,
                padEnds: false,
                itemCount: _draftMediaItems.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentMediaIndex = index;
                  });
                },
                itemBuilder: (context, index) {
                  final item = _draftMediaItems[index];
                  return AnimatedBuilder(
                    animation: _mediaPageController,
                    builder: (context, child) {
                      double pageValue = _currentMediaIndex.toDouble();
                      if (_mediaPageController.hasClients &&
                          _mediaPageController.position.hasContentDimensions) {
                        pageValue = _mediaPageController.page ?? pageValue;
                      }
                      final distance =
                          (index - pageValue).abs().clamp(0.0, 1.6);
                      final scale = 1 - (distance * 0.18);
                      final rotation = (index - pageValue) * 0.10;
                      final verticalOffset = distance * 34;

                      return Center(
                        child: Transform.translate(
                          offset: Offset(0, verticalOffset),
                          child: Transform.rotate(
                            angle: rotation,
                            child: Transform.scale(
                              scale: scale,
                              child: Opacity(
                                opacity: 1 - (distance * 0.28),
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F1522),
                            border: Border.all(
                              color: index == _currentMediaIndex
                                  ? const Color(0xFF9E7CFF)
                                  : Colors.white12,
                            ),
                          ),
                          child: _buildLocalMediaPreview(item),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (_draftMediaItems.length > 1)
                Positioned(
                  bottom: 14,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _draftMediaItems.length,
                      (index) => Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: index == _currentMediaIndex
                              ? Colors.white
                              : Colors.white38,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 10,
                left: 10,
                child: ElevatedButton.icon(
                  onPressed: _draftMediaItems[_currentMediaIndex].isVideo
                      ? null
                      : _openCropEditor,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black.withOpacity( 0.65),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.crop_rounded, size: 18),
                  label: const Text('חתוך'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 88,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: _draftMediaItems.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) {
                  newIndex -= 1;
                }
                final item = _draftMediaItems.removeAt(oldIndex);
                _draftMediaItems.insert(newIndex, item);
                _currentMediaIndex =
                    newIndex.clamp(0, _draftMediaItems.length - 1);
                _mediaPageController.jumpToPage(_currentMediaIndex);
              });
            },
            itemBuilder: (context, index) {
              final item = _draftMediaItems[index];
              return InkWell(
                key: ValueKey('${item.file.path}-$index'),
                onTap: () => _goToMediaIndex(index),
                child: Container(
                  width: 84,
                  margin: const EdgeInsetsDirectional.only(end: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: index == _currentMediaIndex
                          ? const Color(0xFF9E7CFF)
                          : Colors.white24,
                      width: index == _currentMediaIndex ? 2 : 1,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: item.isVideo
                            ? IgnorePointer(
                                child: _InlineEditableVideoPlayer(
                                  source: item.file.path.isNotEmpty
                                      ? item.file.path
                                      : item.file.name,
                                  previewBytes: item.previewBytes,
                                  autoplay: false,
                                ),
                              )
                            : (item.previewBytes != null
                                ? Image.memory(
                                    item.previewBytes!,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: const Color(0xFF121926),
                                    child: const Icon(
                                      Icons.image_not_supported_rounded,
                                      color: Colors.white,
                                    ),
                                  )),
                      ),
                      if (item.isVideo)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity( 0.62),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Icon(
                              Icons.videocam_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                      Positioned(
                        top: 4,
                        left: 4,
                        child: ReorderableDragStartListener(
                          index: index,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity( 0.6),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Icon(
                              Icons.drag_indicator_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEventSelector() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _surfaceColor(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _borderColor(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'האם כבר פרסמת פוסט מהאירוע הזה?',
                style: TextStyle(
                  color: _primaryTextColor(context),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: !_linkToExistingEvent
                            ? const Color(0xFF53C1F9).withOpacity( 0.12)
                            : Colors.transparent,
                        side: BorderSide(
                          color: !_linkToExistingEvent
                              ? const Color(0xFF53C1F9)
                              : _borderColor(context),
                        ),
                        foregroundColor: _primaryTextColor(context),
                      ),
                      onPressed: () {
                        setState(() {
                          _linkToExistingEvent = false;
                          _selectedEventGroupId = '';
                          _selectedEventSourcePostId = '';
                          _selectedEventLabel = '';
                        });
                      },
                      child: const Text('לא'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: _linkToExistingEvent
                            ? const Color(0xFF9E7CFF).withOpacity( 0.16)
                            : Colors.transparent,
                        side: BorderSide(
                          color: _linkToExistingEvent
                              ? const Color(0xFF9E7CFF)
                              : _borderColor(context),
                        ),
                        foregroundColor: _primaryTextColor(context),
                      ),
                      onPressed: () {
                        setState(() {
                          _linkToExistingEvent = true;
                        });
                        _pickExistingEvent();
                      },
                      child: const Text('כן'),
                    ),
                  ),
                ],
              ),
              if (_linkToExistingEvent) ...[
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _isLight(context)
                        ? Colors.white
                        : const Color(0xFF0F1725),
                    foregroundColor: _isLight(context)
                        ? const Color(0xFF5A6CFF)
                        : Colors.white,
                    side: _isLight(context)
                        ? const BorderSide(color: Color(0xFFA9C3FF))
                        : BorderSide.none,
                  ),
                  onPressed: _pickExistingEvent,
                  icon: const Icon(Icons.folder_copy_rounded),
                  label: Text(
                    _selectedEventLabel.isNotEmpty
                        ? 'אירוע נבחר: $_selectedEventLabel'
                        : 'בחר פוסט מאירוע קודם',
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = _isLight(context);
    final hasSelectedCategory =
        _mainCategory != null && !isGeneralCategory(_mainCategory);
    final selectedCategoryLabel = hasSelectedCategory ? _mainCategory! : '';
    final selectedSubCategoryLabel =
        hasSelectedCategory && _subCategory != null ? _subCategory! : '';

    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: _screenBackground(context),
        appBar: AppBar(
          backgroundColor: _screenBackground(context),
          elevation: 0,
          title: Text(
            widget.isEdit ? 'עריכת פוסט' : 'עריכת פוסט',
            style: TextStyle(color: _primaryTextColor(context)),
          ),
          iconTheme: IconThemeData(color: _primaryTextColor(context)),
          actions: [
            if (widget.isEdit)
              IconButton(
                tooltip: 'מחיקת פוסט',
                onPressed: (_isPublishing || _isDeleting)
                    ? null
                    : _confirmAndDeletePost,
                icon: _isDeleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline_rounded),
              ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screenHeight = MediaQuery.of(context).size.height;
              final mediaPreviewHeight =
                  (screenHeight * 0.38).clamp(228.0, 360.0);
              final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

              return AnimatedPadding(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: keyboardInset),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildMediaEditor(previewHeight: mediaPreviewHeight),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _titleController,
                          maxLength: 60,
                          style: TextStyle(
                            color: _primaryTextColor(context),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          decoration: InputDecoration(
                            counterStyle:
                                TextStyle(color: _secondaryTextColor(context)),
                            hintText: 'כותרת *',
                            hintStyle:
                                TextStyle(color: _secondaryTextColor(context)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: _borderColor(context)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: _borderColor(context)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _descController,
                          maxLength: 300,
                          maxLines: 4,
                          style: TextStyle(color: _primaryTextColor(context)),
                          decoration: InputDecoration(
                            counterStyle:
                                TextStyle(color: _secondaryTextColor(context)),
                            hintText: 'תיאור',
                            hintStyle:
                                TextStyle(color: _secondaryTextColor(context)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: _borderColor(context)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: _borderColor(context)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildEventSelector(),
                        _buildCategorySelectionCard(
                          title: 'קטגוריה',
                          valueText: selectedCategoryLabel,
                          hintText: 'בחר קטגוריה',
                          icon: Icons.category_rounded,
                          onTap: _openMainCategoryPicker,
                        ),
                        const SizedBox(height: 8),
                        if (hasSelectedCategory) ...[
                          _buildCategorySelectionCard(
                            title: 'תת קטגוריה',
                            valueText: selectedSubCategoryLabel,
                            hintText: 'בחר תת קטגוריה',
                            icon: Icons.subdirectory_arrow_right_rounded,
                            onTap: () => _openSubCategoryPicker(
                                category: _mainCategory!),
                          ),
                          const SizedBox(height: 8),
                        ],
                        ListTile(
                          tileColor: _surfaceColor(context),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: _borderColor(context)),
                          ),
                          leading: Icon(
                            Icons.location_on,
                            color: _primaryTextColor(context),
                          ),
                          title: TextField(
                            controller: _locationController,
                            style: TextStyle(color: _primaryTextColor(context)),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: 'מיקום',
                              hintStyle: TextStyle(
                                  color: _secondaryTextColor(context)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          tileColor: _surfaceColor(context),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: _borderColor(context)),
                          ),
                          leading: Icon(
                            Icons.person_add,
                            color: _primaryTextColor(context),
                          ),
                          title: Text(
                            'הוסף חברים (${_selectedFriendUids.length})',
                            style: TextStyle(color: _primaryTextColor(context)),
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.chevron_right,
                              color: _secondaryTextColor(context),
                            ),
                            onPressed: _openAddFriends,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildLinkedGroupSelector(),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        bottomNavigationBar: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: _surfaceColor(context),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: _borderColor(context)),
                      foregroundColor: _primaryTextColor(context),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: (_isPublishing || _isDeleting)
                        ? null
                        : () => _submitPost(status: 'draft'),
                    icon: const Icon(
                      Icons.save_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    label: Text(
                      'שמור טיוטה',
                      style: TextStyle(color: _primaryTextColor(context)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          isLight ? Colors.white : const Color(0xFF9E7CFF),
                      foregroundColor:
                          isLight ? const Color(0xFF9E7CFF) : Colors.black,
                      side: isLight
                          ? const BorderSide(color: Color(0xFF9E7CFF))
                          : BorderSide.none,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _isPublishing || _isDeleting
                        ? null
                        : () => _submitPost(status: 'published'),
                    child: _isPublishing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            'פרסם',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF9E7CFF)
                                  : Colors.white,
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
}

class _InlineEditableVideoPlayer extends StatefulWidget {
  final String source;
  final Uint8List? previewBytes;
  final bool showPlayOverlay;
  final bool autoplay;

  const _InlineEditableVideoPlayer({
    required this.source,
    this.previewBytes,
    // ignore: unused_element
    this.showPlayOverlay = false,
    this.autoplay = true,
  });

  @override
  State<_InlineEditableVideoPlayer> createState() =>
      _InlineEditableVideoPlayerState();
}

class _InlineEditableVideoPlayerState
    extends State<_InlineEditableVideoPlayer> {
  VideoPlayerController? _controller;
  Uint8List? _previewBytes;
  bool _didFailToInitialize = false;

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.setVolume(1);
        await controller.play();
      }
    } catch (_) {
      // Keep current playback state if media APIs fail.
    }

    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _previewBytes = widget.previewBytes;
    if (_previewBytes == null) {
      unawaited(_hydratePreviewBytes());
    }
    _initialize();
  }

  @override
  void didUpdateWidget(covariant _InlineEditableVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewBytes != widget.previewBytes &&
        widget.previewBytes != null) {
      _previewBytes = widget.previewBytes;
    }
    if (oldWidget.source != widget.source) {
      _controller?.dispose();
      _controller = null;
      _didFailToInitialize = false;
      _previewBytes = widget.previewBytes;
      if (_previewBytes == null) {
        unawaited(_hydratePreviewBytes());
      }
      _initialize();
    }
  }

  Future<void> _hydratePreviewBytes() async {
    final normalized = widget.source.trim();
    if (normalized.isEmpty) {
      return;
    }
    final bytes = await buildVideoPreviewBytesFromSource(normalized);
    if (!mounted || bytes == null) {
      return;
    }
    setState(() {
      _previewBytes = bytes;
    });
  }

  Future<void> _initialize() async {
    final normalized = widget.source.trim();
    if (normalized.isEmpty) {
      if (mounted) {
        setState(() {});
      }
      return;
    }

    final isRemote =
        normalized.startsWith('http://') || normalized.startsWith('https://');
    final controller = isRemote
        ? VideoPlayerController.networkUrl(Uri.parse(normalized))
        : (kIsWeb
            ? VideoPlayerController.networkUrl(Uri.parse(normalized))
            : VideoPlayerController.file(File(normalized)));
    _controller = controller;

    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (widget.autoplay) {
        await controller.setVolume(0);
        await controller.play();
      }
    } catch (_) {
      _didFailToInitialize = true;
    }

    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _didFailToInitialize) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_previewBytes != null)
            Image.memory(
              _previewBytes!,
              fit: BoxFit.cover,
            )
          else
            Container(color: const Color(0xFF121926)),
          if (widget.showPlayOverlay || _previewBytes == null)
            const Center(
              child: Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
        ],
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlayback,
              child: VideoPlayer(controller),
            ),
            if (widget.showPlayOverlay && !controller.value.isPlaying)
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlayback,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity( 0.42),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChoiceOption {
  final String value;
  final String label;
  final int? points;

  const _CategoryChoiceOption({
    required this.value,
    required this.label,
    this.points,
  });
}
