import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'chats_screen.dart';
import 'create_post_screen.dart';
import 'group_settings_screen.dart';
import 'post_detail_view.dart';
import 'post_media_utils.dart';
import 'services/group_service.dart';
import 'services/public_user_profile_service.dart';
import 'user_profile_screen.dart';
import 'widgets/group_avatar.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

class _InvitableFriendOption {
  final String uid;
  final String name;
  final String avatarUrl;

  const _InvitableFriendOption({
    required this.uid,
    required this.name,
    required this.avatarUrl,
  });
}

class GroupDetailsScreen extends StatefulWidget {
  final bool isAdmin;
  final String groupId;

  const GroupDetailsScreen(
      {super.key, required this.isAdmin, required this.groupId});

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  final GroupService _groupService = GroupService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  final ImagePicker _imagePicker = ImagePicker();
  final Set<String> _busyRequestUids = <String>{};
  final Set<String> _busyInviteUids = <String>{};

  bool _isLeavingGroup = false;
  bool _isRsvpLoading = false;
  bool _isImageUpdating = false;
  bool _isClosingGroup = false;
  bool _showAllMembers = false;

  Future<ImageSource?> _selectImageSource() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return showModalBottomSheet<ImageSource>(
      context: context,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                child: Row(
                  children: [
                    Text(
                      'בחירת תמונה',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'סגור',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('בחירה מהגלריה'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: const Text('פתיחת מצלמה'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleLeaveGroup(String groupName) async {
    if (_isLeavingGroup) return;

    final isLight = Theme.of(context).brightness == Brightness.light;
    final shouldLeave = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
              title: Text(
                'יציאה מהקבוצה',
                style: TextStyle(
                  color: isLight ? Colors.black : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                'האם לצאת מהקבוצה "$groupName"?',
                style: TextStyle(
                  color: isLight ? Colors.black54 : Colors.white70,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isLight
                        ? const Color(0xFFE8EEFF)
                        : const Color(0xFFFF3B30),
                    foregroundColor:
                        isLight ? const Color(0xFF1E2A45) : Colors.white,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('יציאה מהקבוצה'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldLeave) return;

    setState(() {
      _isLeavingGroup = true;
    });

    try {
      await _groupService.leaveGroup(widget.groupId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יצאת מהקבוצה בהצלחה')),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const ChatsScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('היציאה מהקבוצה נכשלה: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLeavingGroup = false;
        });
      }
    }
  }

  Future<void> _handleCloseGroup() async {
    if (_isClosingGroup) return;

    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isLight = Theme.of(context).brightness == Brightness.light;
        return AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
          title: Text(
            'סגירת קבוצה',
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'האם לסגור את הקבוצה לצמיתות?\nכל הנתונים יימחקו והקבוצה לא תהיה זמינה יותר.',
            style: TextStyle(
              color: isLight ? Colors.black54 : Colors.white70,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3B30)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('סגור קבוצה',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (shouldClose != true) return;

    setState(() {
      _isClosingGroup = true;
    });

    try {
      await _groupService.closeGroup(widget.groupId);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const ChatsScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('סגירת קבוצה נכשלה: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isClosingGroup = false;
        });
      }
    }
  }

  String _fallbackText(String? value) {
    final normalized = (value ?? '').trim();
    return normalized.isEmpty ? 'נתון חסר' : normalized;
  }

  DateTime? _readGroupDate(Map<String, dynamic> data) {
    final raw = data['date'] ?? data['executionDate'];
    if (raw is Timestamp) {
      return raw.toDate();
    }
    if (raw is DateTime) {
      return raw;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  String _displayDate(DateTime? date) {
    if (date == null) return 'נתון חסר';
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '${date.day}/${date.month}/${date.year} $hh:$mm';
  }

  Future<void> _handleRsvp() async {
    if (_isRsvpLoading) return;
    setState(() {
      _isRsvpLoading = true;
    });

    try {
      await _groupService.confirmAttendance(widget.groupId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('אישור הגעה נכשל: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRsvpLoading = false;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _openBasicEditDialog(Map<String, dynamic> groupData) async {
    final nameController = TextEditingController(
      text: ((groupData['groupName'] as String?) ??
              (groupData['name'] as String?) ??
              '')
          .trim(),
    );
    final descriptionController = TextEditingController(
      text: ((groupData['description'] as String?) ?? '').trim(),
    );
    final locationController = TextEditingController(
      text: ((groupData['location'] as String?) ??
              (groupData['meetingRegion'] as String?) ??
              '')
          .trim(),
    );
    DateTime selectedDate = _readGroupDate(groupData) ?? DateTime.now();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isLight = Theme.of(context).brightness == Brightness.light;
        return AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
          title: Text(
            'עריכת פרטים',
            style: TextStyle(color: isLight ? Colors.black : Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style:
                      TextStyle(color: isLight ? Colors.black : Colors.white),
                  decoration: InputDecoration(
                    labelText: 'שם קבוצה',
                    labelStyle: TextStyle(
                      color: isLight ? Colors.black54 : Colors.white70,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  style:
                      TextStyle(color: isLight ? Colors.black : Colors.white),
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'תיאור קבוצה',
                    labelStyle: TextStyle(
                      color: isLight ? Colors.black54 : Colors.white70,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  style:
                      TextStyle(color: isLight ? Colors.black : Colors.white),
                  decoration: InputDecoration(
                    labelText: 'מיקום מפגש',
                    labelStyle: TextStyle(
                      color: isLight ? Colors.black54 : Colors.white70,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, setLocalState) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'תאריך מפגש: ${_displayDate(selectedDate)}',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                        ),
                      ),
                      trailing: Icon(
                        Icons.calendar_today,
                        color: isLight ? Colors.black45 : Colors.white54,
                      ),
                      onTap: () async {
                        final pickedDate = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime.now()
                              .subtract(const Duration(days: 3650)),
                          lastDate:
                              DateTime.now().add(const Duration(days: 3650)),
                        );
                        if (pickedDate == null) return;
                        if (!context.mounted) return;
                        final pickedTime = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(selectedDate),
                        );
                        if (pickedTime == null) return;
                        setLocalState(() {
                          selectedDate = DateTime(
                            pickedDate.year,
                            pickedDate.month,
                            pickedDate.day,
                            pickedTime.hour,
                            pickedTime.minute,
                          );
                        });
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9E7CFF)),
              onPressed: () async {
                try {
                  await _groupService.updateGroupCoreDetails(
                    groupId: widget.groupId,
                    groupName: nameController.text.trim(),
                    description: descriptionController.text.trim(),
                    location: locationController.text.trim(),
                    date: selectedDate,
                  );
                  if (!context.mounted) return;
                  Navigator.of(context).pop(true);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(content: Text('שמירת פרטים נכשלה: $e')),
                  );
                }
              },
              child: const Text('שמור', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    descriptionController.dispose();
    locationController.dispose();

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הפרטים נשמרו בהצלחה')),
      );
    }
  }

  Future<void> _editGroupImage(Map<String, dynamic> groupData) async {
    if (_isImageUpdating) return;

    final source = await _selectImageSource();
    if (source == null) return;

    XFile? picked;
    Uint8List bytes;
    try {
      picked = await _imagePicker.pickImage(source: source);
      if (picked == null) return;
      bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return;
    } on PlatformException catch (error) {
      if (!mounted) return;
      final code = error.code.toLowerCase();
      final isCameraDenied = code.contains('camera_access_denied') ||
          code.contains('camera_access_restricted');
      final isGalleryDenied = code.contains('photo_access_denied') ||
          code.contains('photo_access_restricted');

      final message = isCameraDenied
          ? 'אין הרשאת מצלמה באייפון. אפשר לאשר בהגדרות > Hundred > Camera.'
          : isGalleryDenied
              ? 'אין הרשאת גלריה באייפון. אפשר לאשר בהגדרות > Hundred > Photos.'
              : 'לא ניתן לפתוח מדיה כרגע. נסה שוב.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    setState(() {
      _isImageUpdating = true;
    });

    try {
      final url = await _groupService.uploadGroupImage(
        groupId: widget.groupId,
        imageBytes: bytes,
        imageFileName: picked.name,
      );
      final status = await _groupService.updateGroupImageAsMember(
        groupId: widget.groupId,
        groupImageUrl: url,
      );
      if (!mounted) return;
      final message = status == 'updated'
          ? 'תמונת הקבוצה עודכנה'
          : 'התמונה נשמרה ותתעדכן לאחר סנכרון מאובטח';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('עדכון תמונה נכשל: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isImageUpdating = false;
        });
      }
    }
  }

  Future<void> _approveRequest(String uid) async {
    if (_busyRequestUids.contains(uid)) return;
    setState(() {
      _busyRequestUids.add(uid);
    });

    try {
      await _groupService.approveMember(widget.groupId, uid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('אישור נכשל: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _busyRequestUids.remove(uid);
        });
      }
    }
  }

  Future<void> _denyRequest(String uid) async {
    if (_busyRequestUids.contains(uid)) return;
    setState(() {
      _busyRequestUids.add(uid);
    });

    try {
      await _groupService.denyMember(widget.groupId, uid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('דחייה נכשלה: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _busyRequestUids.remove(uid);
        });
      }
    }
  }

  Future<List<_InvitableFriendOption>> _loadInvitableFriends(
    Set<String> excludedUids,
  ) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null || myUid.trim().isEmpty) {
      return const <_InvitableFriendOption>[];
    }

    final userDoc =
        await FirebaseFirestore.instance.collection('users').doc(myUid).get();
    final userData = userDoc.data() ?? <String, dynamic>{};
    final friendsRaw =
        (userData['friends'] as List<dynamic>?) ?? const <dynamic>[];
    final followingRaw =
        (userData['following'] as List<dynamic>?) ?? const <dynamic>[];

    final friendIds = (friendsRaw.isNotEmpty ? friendsRaw : followingRaw)
        .map((e) => e.toString().trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();

    friendIds.remove(myUid);
    friendIds.removeWhere(excludedUids.contains);

    final options = <_InvitableFriendOption>[];
    for (final friendUid in friendIds) {
      final profile = await _publicUserProfileService.fetchProfile(friendUid);
      final name = (profile?.displayName ?? '').trim().isNotEmpty
          ? profile!.displayName
          : ((profile?.username ?? '').trim().isNotEmpty
              ? profile!.username
              : friendUid);

      options.add(
        _InvitableFriendOption(
          uid: friendUid,
          name: name,
          avatarUrl: (profile?.profilePictureUrl ?? '').trim(),
        ),
      );
    }

    options.sort((a, b) => a.name.compareTo(b.name));
    return options;
  }

  Future<void> _openInviteFriendsDialog({
    Set<String> currentVisibleMemberUids = const <String>{},
  }) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null || myUid.trim().isEmpty) {
      return;
    }

    final existingMembershipUids =
        await _groupService.fetchMembershipUids(widget.groupId);
    final excludedUids = <String>{
      ...currentVisibleMemberUids,
      ...existingMembershipUids,
      myUid,
    };

    final allFriends = await _loadInvitableFriends(excludedUids);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final isLight = Theme.of(dialogContext).brightness == Brightness.light;
        final allFriendsInDialog =
            List<_InvitableFriendOption>.from(allFriends);
        final filteredFriends = List<_InvitableFriendOption>.from(allFriends);

        final closeButton = IconButton(
          onPressed: () => Navigator.pop(dialogContext),
          icon: Icon(
            Icons.close,
            color: isLight ? Colors.black54 : Colors.white70,
          ),
          tooltip: 'סגור',
        );

        return StatefulBuilder(
          builder: (context, setModalState) {
            final hasFriends = allFriendsInDialog.isNotEmpty;
            final dialogWidth =
                MediaQuery.of(dialogContext).size.width.clamp(280.0, 420.0);
            return AlertDialog(
              backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              titlePadding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'הוספת חברים לקבוצה',
                      style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                  closeButton,
                ],
              ),
              content: hasFriends
                  ? SizedBox(
                      width: dialogWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(
                            onChanged: (value) {
                              final query = value.trim();
                              setModalState(() {
                                final matches =
                                    allFriendsInDialog.where((friend) {
                                  if (query.isEmpty) {
                                    return true;
                                  }
                                  return friend.name.contains(query);
                                }).toList(growable: false);
                                filteredFriends
                                  ..clear()
                                  ..addAll(matches);
                              });
                            },
                            style: TextStyle(
                                color: isLight ? Colors.black : Colors.white),
                            decoration: InputDecoration(
                              hintText: 'חפש חבר',
                              hintStyle: TextStyle(
                                color:
                                    isLight ? Colors.black54 : Colors.white54,
                              ),
                              filled: true,
                              fillColor: isLight
                                  ? Colors.white.withOpacity( 0.72)
                                  : const Color(0xFF0B1019),
                              border: const OutlineInputBorder(
                                  borderSide: BorderSide.none),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Flexible(
                            child: filteredFriends.isEmpty
                                ? Center(
                                    child: Text(
                                      allFriendsInDialog.isEmpty
                                          ? 'אין חברים זמינים להוספה'
                                          : 'אין תוצאות לחיפוש',
                                      style: TextStyle(
                                        color: isLight
                                            ? Colors.black54
                                            : Colors.white54,
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    shrinkWrap: true,
                                    itemCount: filteredFriends.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 6),
                                    itemBuilder: (context, index) {
                                      final friend = filteredFriends[index];
                                      final isBusy =
                                          _busyInviteUids.contains(friend.uid);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: isLight
                                              ? Colors.white
                                                  .withOpacity( 0.8)
                                              : const Color(0xFF0B1019),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: isLight
                                                ? const Color(0xFFA9C3FF)
                                                : Colors.transparent,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 17,
                                              backgroundColor:
                                                  const Color(0xFF9E7CFF),
                                              backgroundImage:
                                                  friend.avatarUrl.isNotEmpty
                                                      ? NetworkImage(
                                                          friend.avatarUrl)
                                                      : null,
                                              child: friend.avatarUrl.isEmpty
                                                  ? Text(
                                                      friend.name.isNotEmpty
                                                          ? friend.name
                                                              .characters.first
                                                          : 'U',
                                                      style: const TextStyle(
                                                          color: Colors.black),
                                                    )
                                                  : null,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                friend.name,
                                                style: TextStyle(
                                                    color: isLight
                                                        ? Colors.black
                                                        : Colors.white),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    const Color(0xFF9E7CFF),
                                              ),
                                              onPressed: isBusy
                                                  ? null
                                                  : () async {
                                                      setModalState(() {
                                                        _busyInviteUids
                                                            .add(friend.uid);
                                                      });

                                                      try {
                                                        final status =
                                                            await _groupService
                                                                .inviteUserToGroup(
                                                          groupId:
                                                              widget.groupId,
                                                          targetUid: friend.uid,
                                                        );
                                                        if (!mounted) return;

                                                        if (status !=
                                                          'queued') {
                                                          setModalState(() {
                                                          filteredFriends
                                                            .removeWhere(
                                                              (item) =>
                                                                item.uid ==
                                                                friend
                                                                  .uid);
                                                          allFriendsInDialog
                                                            .removeWhere(
                                                              (item) =>
                                                                item.uid ==
                                                                friend
                                                                  .uid);
                                                          });
                                                        }

                                                        final statusMessage =
                                                          status == 'approved'
                                                            ? 'החבר צורף לקבוצה'
                                                            : status ==
                                                                'pending'
                                                              ? 'החבר הועבר לרשימת בקשות ההצטרפות'
                                                              : 'הפעולה נשמרה ותתבצע לאחר סנכרון מאובטח';
                                                        ScaffoldMessenger.of(
                                                                this.context)
                                                            .showSnackBar(
                                                          SnackBar(
                                                              content: Text(
                                                                  statusMessage)),
                                                        );
                                                      } catch (e) {
                                                        if (!mounted) return;
                                                        ScaffoldMessenger.of(
                                                                this.context)
                                                            .showSnackBar(
                                                          SnackBar(
                                                              content: Text(
                                                                  'הוספת חבר נכשלה: $e')),
                                                        );
                                                      } finally {
                                                        if (mounted) {
                                                          setModalState(() {
                                                            _busyInviteUids
                                                                .remove(
                                                                    friend.uid);
                                                          });
                                                        }
                                                      }
                                                    },
                                              child: isBusy
                                                  ? const SizedBox(
                                                      width: 14,
                                                      height: 14,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.black,
                                                      ),
                                                    )
                                                  : const Text(
                                                      'צרף',
                                                      style: TextStyle(
                                                          color: Colors.black),
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
                    )
                  : SizedBox(
                      width: dialogWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'אין חברים זמינים להוספה',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black54 : Colors.white54,
                          ),
                        ),
                      ),
                    ),
            );
          },
        );
      },
    );
  }

  void _openAttendanceList() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'חברים שאישרו הגעה',
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _groupService.attendanceStream(widget.groupId),
                      builder: (context, snapshot) {
                        final docs = snapshot.data?.docs ?? [];
                        if (docs.isEmpty) {
                          return Center(
                            child: Text(
                              'עדיין אין אישורי הגעה',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  color: isLight
                                      ? Colors.black54
                                      : Colors.white54),
                            ),
                          );
                        }

                        return ListView.builder(
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final uid = docs[index].id;
                            return _ProfileTile(
                              uid: uid,
                              publicUserProfileService:
                                  _publicUserProfileService,
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
        );
      },
    );
  }

  Widget _buildInfoChip(String label, String value) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withOpacity( 0.8)
            : const Color(0xFF1E2632),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isLight ? const Color(0xFFA9C3FF) : Colors.transparent,
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isLight ? Colors.black54 : Colors.white70,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMemberProfile(String uid) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return;

    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (myUid.isNotEmpty && trimmedUid == myUid) {
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserProfileScreen(uid: trimmedUid)),
    );
  }

  String _extractUid(dynamic raw) {
    if (raw == null) return '';

    if (raw is String) {
      final value = raw.trim();
      if (value.isEmpty) return '';
      if (value.startsWith('{') && value.endsWith('}')) {
        return '';
      }
      return value;
    }

    if (raw is Map<String, dynamic>) {
      return (raw['uid'] ?? raw['userId'] ?? raw['id'] ?? '').toString().trim();
    }

    if (raw is Map) {
      return (raw['uid'] ?? raw['userId'] ?? raw['id'] ?? '').toString().trim();
    }

    return '';
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _groupPostsStream() {
    final linkedStream = FirebaseFirestore.instance
        .collection('posts')
        .where('linkedGroupId', isEqualTo: widget.groupId)
        .snapshots();
    final eventStream = FirebaseFirestore.instance
        .collection('posts')
        .where('eventGroupId', isEqualTo: widget.groupId)
        .snapshots();
    final directGroupStream = FirebaseFirestore.instance
        .collection('posts')
        .where('groupId', isEqualTo: widget.groupId)
        .snapshots();

    return Stream.multi((controller) {
      QuerySnapshot<Map<String, dynamic>>? linkedSnapshot;
      QuerySnapshot<Map<String, dynamic>>? eventSnapshot;
      QuerySnapshot<Map<String, dynamic>>? directGroupSnapshot;

      void emitMerged() {
        if (linkedSnapshot == null ||
            eventSnapshot == null ||
            directGroupSnapshot == null) {
          return;
        }

        final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final doc in linkedSnapshot!.docs) {
          merged[doc.id] = doc;
        }
        for (final doc in eventSnapshot!.docs) {
          merged[doc.id] = doc;
        }
        for (final doc in directGroupSnapshot!.docs) {
          merged[doc.id] = doc;
        }

        controller.add(merged.values.toList(growable: false));
      }

      final linkedSub = linkedStream.listen(
        (snapshot) {
          linkedSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );
      final eventSub = eventStream.listen(
        (snapshot) {
          eventSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );
      final directGroupSub = directGroupStream.listen(
        (snapshot) {
          directGroupSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      controller.onCancel = () async {
        await linkedSub.cancel();
        await eventSub.cancel();
        await directGroupSub.cancel();
      };
    });
  }

  void _openLinkedPost(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int initialIndex,
  ) {
    if (docs.isEmpty || initialIndex < 0 || initialIndex >= docs.length) {
      return;
    }

    final posts = docs
        .map((doc) => <String, dynamic>{
              ...doc.data(),
              'id': doc.id,
              'postId': (doc.data()['postId'] as String? ?? doc.id).trim(),
            })
        .toList(growable: false);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: posts,
          initialIndex: initialIndex,
          enableEditAction: false,
          useDraftPublishEditAction: false,
        ),
      ),
    );
  }

  Map<String, dynamic> _mergeGroupAndChatData({
    required Map<String, dynamic> groupData,
    required Map<String, dynamic> chatData,
  }) {
    final merged = <String, dynamic>{...chatData, ...groupData};

    // Keep legacy/new key aliases in sync for UI and editors.
    merged['groupName'] = ((groupData['groupName'] as String?) ??
            (chatData['name'] as String?) ??
            '')
        .trim();
    merged['description'] = ((groupData['description'] as String?) ??
            (chatData['description'] as String?) ??
            '')
        .trim();
    merged['groupImageUrl'] = ((groupData['groupImageUrl'] as String?) ??
            (chatData['groupImageUrl'] as String?) ??
            '')
        .trim();

    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SwipeBackWrapper(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.groupId)
            .snapshots(),
        builder: (context, chatSnapshot) {
          final chatData = chatSnapshot.data?.data() ?? <String, dynamic>{};

          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('groups')
                .doc(widget.groupId)
                .snapshots(),
            builder: (context, groupSnapshot) {
              if (groupSnapshot.connectionState == ConnectionState.waiting &&
                  !groupSnapshot.hasData &&
                  !chatSnapshot.hasData) {
                return const Scaffold(
                  backgroundColor: Colors.white,
                  body: SafeArea(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }

              final rawGroupData =
                  groupSnapshot.data?.data() ?? <String, dynamic>{};
              final groupData = _mergeGroupAndChatData(
                groupData: rawGroupData,
                chatData: chatData,
              );
              final groupName = _fallbackText(
                  (groupData['groupName'] as String?) ??
                      (groupData['name'] as String?));
              final description =
                  _fallbackText(groupData['description'] as String?);
              final location = _fallbackText(
                  (groupData['location'] as String?) ??
                      (groupData['meetingRegion'] as String?));
              final date = _readGroupDate(groupData);
              final imageUrl =
                  (groupData['groupImageUrl'] as String? ?? '').trim();
              final adminUid = (groupData['adminUid'] as String? ?? '').trim();
              final myUid = FirebaseAuth.instance.currentUser?.uid;
              final isActualAdmin = myUid != null && myUid == adminUid;
              final isPublicGroup = (groupData['isPublic'] as bool?) ?? true;
              final approvalRequired =
                  (groupData['isAdminApprovalRequired'] as bool?) ?? false;
              final mainCategory = ((groupData['category'] as String?) ??
                      (groupData['mainCategory'] as String?) ??
                      '')
                  .trim();
              final subCategory =
                  (groupData['subCategory'] as String? ?? '').trim();
              final hasMainCategory = mainCategory.isNotEmpty;
              final hasSubCategory = subCategory.isNotEmpty;

              return Scaffold(
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF0B1019),
                appBar: AppBar(
                  backgroundColor: isLight
                      ? const Color(0xFFCFEFFF)
                      : const Color(0xFF1E2632),
                  elevation: 0,
                  leading: IconButton(
                    icon: Icon(
                      Icons.arrow_back,
                      color: isLight ? Colors.black : Colors.white,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: Text(
                    'פרטי קבוצה',
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  actions: [
                    IconButton(
                      onPressed: () {
                        if (isActualAdmin) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GroupSettingsScreen(
                                isAdmin: true,
                                groupId: widget.groupId,
                                initialGroupData: groupData,
                              ),
                            ),
                          );
                          return;
                        }

                        showDialog<void>(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              backgroundColor: isLight
                                  ? Colors.white
                                  : const Color(0xFF1E2632),
                              title: Text('הרשאה נדרשת',
                                  style: TextStyle(
                                      color: isLight
                                          ? Colors.black
                                          : Colors.white)),
                              content: Text(
                                'רק המנהל יכול לערוך',
                                style: TextStyle(
                                    color: isLight
                                        ? Colors.black54
                                        : Colors.white70),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('סגור'),
                                ),
                              ],
                            );
                          },
                        );
                      },
                      icon: Icon(Icons.edit,
                          color: isLight ? Colors.black : Colors.white),
                      tooltip: 'עריכת פרטים',
                    ),
                  ],
                ),
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListView(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.white.withOpacity( 0.82)
                                : const Color(0xFF1E2632),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isLight
                                  ? const Color(0xFFA9C3FF)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Column(
                            children: [
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final isCompact = constraints.maxWidth < 390;
                                  final avatarWidget = GestureDetector(
                                    onTap: () => _editGroupImage(groupData),
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        GroupAvatar(
                                          radius: 34,
                                          imageUrl: imageUrl,
                                        ),
                                        if (_isImageUpdating)
                                          const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        else
                                          Positioned(
                                            bottom: 1,
                                            child: Container(
                                              padding: const EdgeInsets.all(5),
                                              decoration: BoxDecoration(
                                                color: isLight
                                                    ? Colors.white
                                                        .withOpacity( 0.94)
                                                    : const Color(0xFF1E2632),
                                                shape: BoxShape.circle,
                                              ),
                                              child: Icon(
                                                Icons.camera_alt_rounded,
                                                color: isLight
                                                    ? const Color(0xFF7B6BE0)
                                                    : const Color(0xFF9EDBFF),
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );

                                  if (isCompact) {
                                    return Column(
                                      children: [
                                        avatarWidget,
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _buildInfoChip(
                                                  'מיקום המפגש', location),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: _buildInfoChip(
                                                'תאריך מפגש',
                                                _displayDate(date),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      Expanded(
                                        child: _buildInfoChip(
                                            'מיקום המפגש', location),
                                      ),
                                      const SizedBox(width: 12),
                                      avatarWidget,
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: _buildInfoChip(
                                          'תאריך מפגש',
                                          _displayDate(date),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 20),
                              Text(
                                groupName,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                description,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14, horizontal: 16),
                                decoration: BoxDecoration(
                                  color: isLight
                                      ? const Color(0xFFEFF5FF)
                                      : const Color(0xFF18181E),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isLight
                                        ? const Color(0xFFA9C3FF)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: StreamBuilder<
                                    QuerySnapshot<Map<String, dynamic>>>(
                                  stream: _groupService
                                      .attendanceStream(widget.groupId),
                                  builder: (context, attendanceSnapshot) {
                                    final attendanceDocs =
                                        attendanceSnapshot.data?.docs ?? [];
                                    final attendees = attendanceDocs.length;

                                    return Directionality(
                                      textDirection: TextDirection.rtl,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '$attendees אישרו הגעה',
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(
                                                    color: isLight
                                                        ? Colors.black
                                                        : Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  'לחץ אישור הגעה ואז תוכל לצפות ברשימת המאשרים',
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(
                                                    color: isLight
                                                        ? Colors.black54
                                                        : Colors.white54,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          StreamBuilder<bool>(
                                            stream: _groupService
                                                .myAttendanceStream(
                                                    widget.groupId),
                                            builder: (context,
                                                myAttendanceSnapshot) {
                                              final isAttending =
                                                  myAttendanceSnapshot.data ??
                                                      false;

                                              if (isAttending) {
                                                return ElevatedButton(
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    backgroundColor: isLight
                                                        ? const Color(
                                                            0xFFE9F0FF)
                                                        : Colors.white12,
                                                  ),
                                                  onPressed:
                                                      _openAttendanceList,
                                                  child: Text(
                                                    'צפה במאשרים',
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? Colors.black
                                                          : Colors.white,
                                                    ),
                                                  ),
                                                );
                                              }

                                              return ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        const Color(0xFF9E7CFF),
                                                    foregroundColor:
                                                        Colors.black),
                                                onPressed: _isRsvpLoading
                                                    ? null
                                                    : _handleRsvp,
                                                child: _isRsvpLoading
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child:
                                                            CircularProgressIndicator(
                                                                strokeWidth: 2,
                                                                color: Colors
                                                                    .black),
                                                      )
                                                    : const Text('אישור הגעה'),
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              if (hasMainCategory || hasSubCategory) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 18, horizontal: 16),
                                  decoration: BoxDecoration(
                                    gradient: isLight
                                        ? const LinearGradient(
                                            colors: [
                                              Color(0xFFFFFFFF),
                                              Color(0xFFF1E8FF),
                                              Color(0xFFEAF8FF),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          )
                                        : const LinearGradient(
                                            colors: [
                                              Color(0xFF2B1652),
                                              Color(0xFF4D2A91)
                                            ],
                                            begin: Alignment.topRight,
                                            end: Alignment.bottomLeft,
                                          ),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: isLight
                                            ? const Color(0xFF9EDBFF)
                                            : const Color(0xFF9E7CFF),
                                        width: 1.2),
                                    boxShadow: isLight
                                        ? [
                                            BoxShadow(
                                              color: const Color(0xFF9EDBFF)
                                                  .withOpacity( 0.14),
                                              blurRadius: 16,
                                              offset: const Offset(0, 8),
                                            ),
                                          ]
                                        : const [
                                            BoxShadow(
                                              color: Color(0x339E7CFF),
                                              blurRadius: 18,
                                              offset: Offset(0, 8),
                                            ),
                                          ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      if (hasSubCategory)
                                        Text(
                                          _fallbackText(subCategory),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF2A3352)
                                                : Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.3,
                                            shadows: isLight
                                                ? const []
                                                : const [
                                                    Shadow(
                                                      color: Color(0x669E7CFF),
                                                      blurRadius: 10,
                                                      offset: Offset(0, 2),
                                                    ),
                                                  ],
                                          ),
                                        ),
                                      if (hasSubCategory && hasMainCategory)
                                        const SizedBox(height: 8),
                                      if (hasMainCategory)
                                        Text(
                                          _fallbackText(mainCategory),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF6A5BFF)
                                                : const Color(0xFFE4DAFF),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 1.4,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (isActualAdmin &&
                            (approvalRequired || !isPublicGroup)) ...[
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isLight
                                  ? Colors.white.withOpacity( 0.82)
                                  : const Color(0xFF1E2632),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isLight
                                    ? const Color(0xFFA9C3FF)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'בקשות הצטרפות',
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                StreamBuilder<
                                    QuerySnapshot<Map<String, dynamic>>>(
                                  stream: _groupService
                                      .pendingMembersStream(widget.groupId),
                                  builder: (context, snapshot) {
                                    final docs = snapshot.data?.docs ?? [];
                                    if (docs.isEmpty) {
                                      return Text(
                                        'אין בקשות כרגע',
                                        style: TextStyle(
                                          color: isLight
                                              ? Colors.black54
                                              : Colors.white54,
                                        ),
                                      );
                                    }

                                    return Column(
                                      children: docs.map((doc) {
                                        final uid = doc.id;
                                        final busy =
                                            _busyRequestUids.contains(uid);
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 6),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: _ProfileTile(
                                                  uid: uid,
                                                  publicUserProfileService:
                                                      _publicUserProfileService,
                                                ),
                                              ),
                                              TextButton(
                                                onPressed: busy
                                                    ? null
                                                    : () => _denyRequest(uid),
                                                child: const Text('דחייה',
                                                    style: TextStyle(
                                                        color:
                                                            Colors.redAccent)),
                                              ),
                                              ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        const Color(
                                                            0xFF9E7CFF)),
                                                onPressed: busy
                                                    ? null
                                                    : () =>
                                                        _approveRequest(uid),
                                                child: busy
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child:
                                                            CircularProgressIndicator(
                                                                strokeWidth: 2,
                                                                color: Colors
                                                                    .black),
                                                      )
                                                    : const Text('אישור',
                                                        style: TextStyle(
                                                            color:
                                                                Colors.black)),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(growable: false),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.white.withOpacity( 0.96)
                                : const Color(0xFF1E2632),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isLight
                                  ? const Color(0xFFB9D4FF)
                                  : Colors.transparent,
                            ),
                            boxShadow: isLight
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFF9EDBFF)
                                          .withOpacity( 0.10),
                                      blurRadius: 18,
                                      offset: const Offset(0, 8),
                                    ),
                                  ]
                                : const [],
                          ),
                          child: Directionality(
                            textDirection: TextDirection.rtl,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'חברי קבוצה',
                                      style: TextStyle(
                                        color: isLight
                                            ? Colors.black
                                            : Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _openInviteFriendsDialog,
                                      icon: const Icon(Icons.group_add,
                                          color: Color(0xFF9E7CFF)),
                                      tooltip: 'הוספת חברים',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                StreamBuilder<
                                    QuerySnapshot<Map<String, dynamic>>>(
                                  stream: FirebaseFirestore.instance
                                      .collection('groups')
                                      .doc(widget.groupId)
                                      .collection('members')
                                      .snapshots(),
                                  builder: (context, membersSnapshot) {
                                    return StreamBuilder<
                                        QuerySnapshot<Map<String, dynamic>>>(
                                      stream: FirebaseFirestore.instance
                                          .collection('chats')
                                          .doc(widget.groupId)
                                          .collection('members')
                                          .snapshots(),
                                      builder: (context, chatMembersSnapshot) {
                                        final docs =
                                            membersSnapshot.data?.docs ??
                                                const <QueryDocumentSnapshot<
                                                    Map<String, dynamic>>>[];
                                        final chatDocs =
                                            chatMembersSnapshot.data?.docs ??
                                                const <QueryDocumentSnapshot<
                                                    Map<String, dynamic>>>[];

                                        final memberUidsSet = <String>{};

                                        for (final doc in docs) {
                                          final uid = doc.id.trim();
                                          if (uid.isNotEmpty) {
                                            memberUidsSet.add(uid);
                                          }
                                        }
                                        for (final doc in chatDocs) {
                                          final uid = doc.id.trim();
                                          if (uid.isNotEmpty) {
                                            memberUidsSet.add(uid);
                                          }
                                        }

                                        // Keep already-joined members visible even when legacy/member docs
                                        // are partially missing.
                                        final members = (groupData['members']
                                                    as List<dynamic>? ??
                                                const <dynamic>[])
                                            .map(_extractUid)
                                            .where((uid) => uid.isNotEmpty);
                                        memberUidsSet.addAll(members);

                                        final membersList =
                                            (groupData['membersList']
                                                        as List<dynamic>? ??
                                                    const <dynamic>[])
                                                .map(_extractUid)
                                                .where((uid) => uid.isNotEmpty);
                                        memberUidsSet.addAll(membersList);

                                        final participants =
                                            (groupData['participants']
                                                        as List<dynamic>? ??
                                                    const <dynamic>[])
                                                .map(_extractUid)
                                                .where((uid) => uid.isNotEmpty);
                                        memberUidsSet.addAll(participants);

                                        final memberUids = memberUidsSet.toList(
                                            growable: false);

                                        if (adminUid.isNotEmpty &&
                                            !memberUids.contains(adminUid)) {
                                          memberUids.insert(0, adminUid);
                                        }

                                        final sortedUids = <String>[];
                                        if (myUid != null &&
                                            myUid.trim().isNotEmpty) {
                                          final normalizedMyUid = myUid.trim();
                                          if (memberUids
                                              .contains(normalizedMyUid)) {
                                            sortedUids.add(normalizedMyUid);
                                          }
                                        }
                                        if (adminUid.isNotEmpty &&
                                            !sortedUids.contains(adminUid) &&
                                            memberUids.contains(adminUid)) {
                                          sortedUids.add(adminUid);
                                        }
                                        for (final uid in memberUids) {
                                          if (!sortedUids.contains(uid)) {
                                            sortedUids.add(uid);
                                          }
                                        }

                                        if (sortedUids.isEmpty) {
                                          return const Center(
                                            child: Text('אין חברים להצגה כרגע',
                                                style: TextStyle(
                                                    color: Colors.black54)),
                                          );
                                        }

                                        final visibleUids = _showAllMembers
                                            ? sortedUids
                                            : sortedUids
                                                .take(7)
                                                .toList(growable: false);

                                        return ListView(
                                          shrinkWrap: true,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          children: [
                                            ListView.builder(
                                              shrinkWrap: true,
                                              physics:
                                                  const NeverScrollableScrollPhysics(),
                                              itemCount: visibleUids.length,
                                              itemBuilder: (context, index) {
                                                final uid = visibleUids[index];
                                                final isAdminMember =
                                                    uid == adminUid;
                                                final isCurrentUser =
                                                    myUid != null &&
                                                        uid == myUid;
                                                return _ProfileTile(
                                                  uid: uid,
                                                  publicUserProfileService:
                                                      _publicUserProfileService,
                                                  onTap: isCurrentUser
                                                      ? null
                                                      : () =>
                                                          _openMemberProfile(
                                                              uid),
                                                  badgeText: isAdminMember
                                                      ? 'מנהל'
                                                      : null,
                                                );
                                              },
                                            ),
                                            if (sortedUids.length > 7)
                                              Align(
                                                alignment: Alignment.center,
                                                child: TextButton(
                                                  onPressed: () {
                                                    setState(() {
                                                      _showAllMembers =
                                                          !_showAllMembers;
                                                    });
                                                  },
                                                  child: Text(
                                                    _showAllMembers
                                                        ? 'הצג פחות'
                                                        : 'הצג יותר',
                                                  ),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    );
                                  },
                                ),
                                const SizedBox(height: 6),
                                Divider(
                                    color: isLight
                                        ? const Color(0xFFA9C3FF)
                                        : Colors.white12),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      'פוסטים מקושרים לקבוצה',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const Spacer(),
                                    StreamBuilder<
                                        List<
                                            QueryDocumentSnapshot<
                                                Map<String, dynamic>>>>(
                                      stream: _groupPostsStream(),
                                      builder: (context, scoreSnapshot) {
                                        final docs = scoreSnapshot.data ??
                                            const <QueryDocumentSnapshot<
                                                Map<String, dynamic>>>[];

                                        final totalScore =
                                            docs.fold<int>(0, (total, postDoc) {
                                          final data = postDoc.data();
                                          final status =
                                              (data['status'] as String? ??
                                                      'published')
                                                  .trim()
                                                  .toLowerCase();
                                          if (status != 'published') {
                                            return total;
                                          }

                                          final rawScore = data['scoreAwarded'];
                                          if (rawScore is num) {
                                            return total + rawScore.toInt();
                                          }
                                          return total +
                                              (int.tryParse(
                                                      rawScore?.toString() ??
                                                          '') ??
                                                  0);
                                        });

                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? const Color(0xFFEDE7FF)
                                                : const Color(0xFF9E7CFF)
                                                    .withOpacity( 0.18),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFF8F79E8)
                                                  : const Color(0xFF9E7CFF),
                                            ),
                                          ),
                                          child: Text(
                                            'ניקוד מצטבר: $totalScore',
                                            style: TextStyle(
                                              color: isLight
                                                  ? const Color(0xFF4B3FA4)
                                                  : Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                StreamBuilder<
                                    List<
                                        QueryDocumentSnapshot<
                                            Map<String, dynamic>>>>(
                                  stream: _groupPostsStream(),
                                  builder: (context, postsSnapshot) {
                                    if (postsSnapshot.connectionState ==
                                            ConnectionState.waiting &&
                                        !postsSnapshot.hasData) {
                                      return const Center(
                                        child: CircularProgressIndicator(),
                                      );
                                    }

                                    if (postsSnapshot.hasError) {
                                      return Center(
                                        child: Text(
                                          'שגיאה בטעינת פוסטים: ${postsSnapshot.error}',
                                          style: TextStyle(
                                            color: isLight
                                                ? Colors.black54
                                                : Colors.white70,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      );
                                    }

                                    final allDocs = postsSnapshot.data ??
                                        const <QueryDocumentSnapshot<
                                            Map<String, dynamic>>>[];
                                    final docs = allDocs.where((doc) {
                                      final data = doc.data();
                                      final status =
                                          (data['status'] as String? ??
                                                  'published')
                                              .trim()
                                              .toLowerCase();
                                      final isDeleted =
                                          (data['isDeleted'] as bool?) ?? false;
                                      return status == 'published' &&
                                          !isDeleted;
                                    }).toList(growable: false)
                                      ..sort((a, b) {
                                        final rawA = a.data()['createdAt'];
                                        final rawB = b.data()['createdAt'];
                                        final dateA = rawA is Timestamp
                                            ? rawA.toDate()
                                            : DateTime
                                                .fromMillisecondsSinceEpoch(0);
                                        final dateB = rawB is Timestamp
                                            ? rawB.toDate()
                                            : DateTime
                                                .fromMillisecondsSinceEpoch(0);
                                        return dateB.compareTo(dateA);
                                      });

                                    if (docs.isEmpty) {
                                      return Container(
                                        decoration: BoxDecoration(
                                          color: isLight
                                              ? const Color(0xFFF4F8FF)
                                              : const Color(0xFF171F2D),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isLight
                                                ? const Color(0xFFA9C3FF)
                                                : Colors.white12,
                                          ),
                                        ),
                                        child: SingleChildScrollView(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                'אין עדיין פוסטים מקושרים לקבוצה',
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black54
                                                      : Colors.white70,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                              const SizedBox(height: 10),
                                              ElevatedButton.icon(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFF9E7CFF),
                                                  foregroundColor: Colors.black,
                                                ),
                                                onPressed: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (_) =>
                                                          const CreatePostScreen(),
                                                    ),
                                                  );
                                                },
                                                icon: const Icon(
                                                    Icons.add_rounded),
                                                label: const Text(
                                                    'הוסף את הפוסט הראשון'),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }

                                    return GridView.builder(
                                      shrinkWrap: true,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      itemCount: docs.length,
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 3,
                                        mainAxisSpacing: 10,
                                        crossAxisSpacing: 10,
                                        childAspectRatio: 3 / 4,
                                      ),
                                      itemBuilder: (context, index) {
                                        final doc = docs[index];
                                        final data = doc.data();
                                        final title =
                                            ((data['title'] as String?) ?? '')
                                                .trim();
                                        final mediaItems =
                                            postMediaItemsFromData(data);
                                        final primaryMediaUrl =
                                            postPrimaryMediaUrl(data);
                                        final mediaUrls = (data['mediaUrls']
                                                    as List<dynamic>? ??
                                                const <dynamic>[])
                                            .map((value) =>
                                                value.toString().trim())
                                            .where((value) => value.isNotEmpty)
                                            .toList(growable: false);
                                        final directPreviewCandidates =
                                            <String>[
                                          (data['thumbnailUrl'] as String? ??
                                                  '')
                                              .trim(),
                                          (data['videoThumbnailUrl']
                                                      as String? ??
                                                  '')
                                              .trim(),
                                          (data['imageUrl'] as String? ?? '')
                                              .trim(),
                                          (data['mediaUrl'] as String? ?? '')
                                              .trim(),
                                        ];
                                        final itemPreviewCandidates = mediaItems
                                            .map((item) => item.url.trim())
                                            .toList(growable: false);
                                        final previewSource = <String>[
                                          ...directPreviewCandidates,
                                          ...itemPreviewCandidates,
                                          ...mediaUrls,
                                          primaryMediaUrl,
                                        ].firstWhere(
                                          (url) => url.isNotEmpty,
                                          orElse: () => '',
                                        );
                                        final isVideoPost = mediaItems.any(
                                              (item) => item.isVideo,
                                            ) ||
                                            (primaryMediaUrl.isNotEmpty &&
                                                isVideoMediaUrl(
                                                    primaryMediaUrl));

                                        return GestureDetector(
                                          onTap: () =>
                                              _openLinkedPost(docs, index),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  child: Container(
                                                    color: isLight
                                                        ? const Color(
                                                            0xFFEAF1FF)
                                                        : const Color(
                                                            0xFF0F1522),
                                                    child: Stack(
                                                      fit: StackFit.expand,
                                                      children: [
                                                        if (previewSource
                                                            .isEmpty)
                                                          Icon(
                                                            Icons
                                                                .image_not_supported_rounded,
                                                            color: isLight
                                                                ? Colors.black38
                                                                : Colors
                                                                    .white38,
                                                          )
                                                        else if (isVideoMediaUrl(
                                                            previewSource))
                                                          FutureBuilder<
                                                              Uint8List?>(
                                                            future:
                                                                buildVideoPreviewBytesFromSource(
                                                                    previewSource),
                                                            builder: (context,
                                                                bytesSnapshot) {
                                                              final bytes =
                                                                  bytesSnapshot
                                                                      .data;
                                                              return Stack(
                                                                fit: StackFit
                                                                    .expand,
                                                                children: [
                                                                  if (bytes !=
                                                                      null)
                                                                    Image
                                                                        .memory(
                                                                      bytes,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                    )
                                                                  else
                                                                    Container(
                                                                      color: isLight
                                                                          ? const Color(
                                                                              0xFFEAF1FF)
                                                                          : const Color(
                                                                              0xFF0F1522),
                                                                    ),
                                                                  const Center(
                                                                    child: Icon(
                                                                      Icons
                                                                          .play_circle_fill_rounded,
                                                                      color: Colors
                                                                          .white,
                                                                      size: 30,
                                                                    ),
                                                                  ),
                                                                ],
                                                              );
                                                            },
                                                          )
                                                        else
                                                          Image.network(
                                                            previewSource,
                                                            fit: BoxFit.cover,
                                                          ),
                                                        if (isVideoPost)
                                                          Align(
                                                            alignment: Alignment
                                                                .bottomRight,
                                                            child: Container(
                                                              margin:
                                                                  const EdgeInsets
                                                                      .all(6),
                                                              padding:
                                                                  const EdgeInsets
                                                                      .all(4),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .black45,
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            999),
                                                              ),
                                                              child: const Icon(
                                                                Icons
                                                                    .videocam_rounded,
                                                                size: 13,
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                title.isNotEmpty
                                                    ? title
                                                    : 'פוסט ללא כותרת',
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.right,
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                bottomNavigationBar: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isLight ? Colors.white : const Color(0xFF1E2632),
                    boxShadow: isLight
                        ? [
                            BoxShadow(
                              color: const Color(0xFF9EDBFF)
                                  .withOpacity( 0.12),
                              blurRadius: 16,
                              offset: const Offset(0, -2),
                            ),
                          ]
                        : const [],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: isLight
                                  ? const Color(0xFFE8EEFF)
                                  : const Color(0xFFFF3B30),
                              foregroundColor: isLight
                                  ? const Color(0xFF1E2A45)
                                  : Colors.white),
                          onPressed: isActualAdmin
                              ? (_isClosingGroup ? null : _handleCloseGroup)
                              : (_isLeavingGroup
                                  ? null
                                  : () => _handleLeaveGroup(groupName)),
                          child: isActualAdmin
                              ? (_isClosingGroup
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('סגור קבוצה'))
                              : (_isLeavingGroup
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('יציאה מהקבוצה')),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final String uid;
  final PublicUserProfileService publicUserProfileService;
  final VoidCallback? onTap;
  final String? badgeText;

  const _ProfileTile({
    required this.uid,
    required this.publicUserProfileService,
    this.onTap,
    this.badgeText,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return StreamBuilder(
      stream: publicUserProfileService.streamProfile(uid),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final displayName = (profile?.displayName ?? '').trim().isNotEmpty
            ? profile!.displayName
            : ((profile?.username ?? '').trim().isNotEmpty
                ? profile!.username
                : uid);
        final imageUrl = (profile?.profilePictureUrl ?? '').trim();
        final initial =
            displayName.isNotEmpty ? displayName.characters.first : 'U';

        return ListTile(
          onTap: onTap,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF9E7CFF),
            backgroundImage:
                imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
            child: imageUrl.isEmpty
                ? Text(initial, style: const TextStyle(color: Colors.black))
                : null,
          ),
          title: Text(
            displayName,
            style: TextStyle(color: isLight ? Colors.black : Colors.white),
          ),
          trailing: (badgeText == null)
              ? null
              : Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9E7CFF).withOpacity( 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF9E7CFF)),
                  ),
                  child: Text(
                    badgeText!,
                    style: const TextStyle(
                      color: Color(0xFF9E7CFF),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
        );
      },
    );
  }
}
