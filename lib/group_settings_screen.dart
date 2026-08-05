import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'age_restrictions.dart';
import 'app_categories.dart';
import 'services/group_service.dart';
import 'services/public_user_profile_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class GroupSettingsScreen extends StatefulWidget {
  final bool isAdmin;
  final String groupId;
  final Map<String, dynamic> initialGroupData;

  const GroupSettingsScreen({
    super.key,
    required this.isAdmin,
    required this.groupId,
    required this.initialGroupData,
  });

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  final GroupService _groupService = GroupService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();

  String _existingImageUrl = '';

  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _meetingRegionController =
      TextEditingController();
  final TextEditingController _minScoreController = TextEditingController();

  String? _mainCategory;
  String? _subCategory;
  DateTime? _executionDate;
  bool _isPublic = true;
  bool _adminApproval = false;
  bool _minScoreRequired = false;
  RangeValues _ageRange = RangeValues(
    minimumUserAge.toDouble(),
    maximumAgeRange.toDouble(),
  );
  bool _isSaving = false;
  final Set<String> _removingUids = <String>{};

  @override
  void initState() {
    super.initState();
    _hydrateFromGroupData(widget.initialGroupData);
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _descriptionController.dispose();
    _meetingRegionController.dispose();
    _minScoreController.dispose();
    super.dispose();
  }

  void _hydrateFromGroupData(Map<String, dynamic> groupData) {
    _groupNameController.text = ((groupData['groupName'] as String?) ??
            (groupData['name'] as String?) ??
            '')
        .trim();
    _descriptionController.text =
        ((groupData['description'] as String?) ?? '').trim();
    _meetingRegionController.text = ((groupData['location'] as String?) ??
            (groupData['meetingRegion'] as String?) ??
            '')
        .trim();

    _mainCategory = (groupData['category'] as String?)?.trim();
    _subCategory = (groupData['subCategory'] as String?)?.trim();
    _isPublic = (groupData['isPublic'] as bool?) ?? true;
    _adminApproval = (groupData['isAdminApprovalRequired'] as bool?) ?? false;
    final minScore = (groupData['minScore'] as num?)?.toInt() ?? 0;
    _minScoreController.text = minScore.toString();
    _minScoreRequired =
        (groupData['isMinScoreRequired'] as bool?) ?? minScore > 0;

    final ageRangeMap = (groupData['ageRange'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final minAge =
        (ageRangeMap['min'] as num?)?.toDouble() ?? minimumUserAge.toDouble();
    final maxAge =
        (ageRangeMap['max'] as num?)?.toDouble() ?? maximumAgeRange.toDouble();
    _ageRange = RangeValues(
      minAge.clamp(minimumUserAge, maximumAgeRange).toDouble(),
      maxAge.clamp(minimumUserAge, maximumAgeRange).toDouble(),
    );

    _executionDate =
        _parseDate(groupData['date'] ?? groupData['executionDate']);
    _existingImageUrl = (groupData['groupImageUrl'] as String? ?? '').trim();
  }

  DateTime? _parseDate(dynamic raw) {
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

  String _extractUid(dynamic raw) {
    if (raw == null) return '';

    if (raw is String) {
      final value = raw.trim();
      if (value.isEmpty) return '';
      // Ignore serialized map-like strings; accept regular uid strings.
      if (value.startsWith('{') && value.endsWith('}')) {
        return '';
      }
      return value;
    }

    if (raw is Map<String, dynamic>) {
      final uid =
          (raw['uid'] ?? raw['userId'] ?? raw['id'] ?? '').toString().trim();
      return uid;
    }

    if (raw is Map) {
      final uid =
          (raw['uid'] ?? raw['userId'] ?? raw['id'] ?? '').toString().trim();
      return uid;
    }

    return '';
  }

  Future<void> _selectExecutionDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _executionDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_executionDate ?? DateTime.now()),
    );
    if (time == null) return;

    if (!mounted) return;
    setState(() {
      _executionDate =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _saveChanges() async {
    if (!widget.isAdmin || _isSaving) return;

    final groupName = _groupNameController.text.trim();
    if (groupName.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('יש להזין שם קבוצה')));
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _groupService.updateGroupCoreDetails(
        groupId: widget.groupId,
        groupName: groupName,
        description: _descriptionController.text.trim(),
        location: _meetingRegionController.text.trim(),
        date: _executionDate ?? DateTime.now(),
      );

      await _groupService.updateGroupAdvancedSettings(
        groupId: widget.groupId,
        category: (_mainCategory ?? '').trim(),
        subCategory: (_subCategory ?? '').trim(),
        isPublic: _isPublic,
        isAdminApprovalRequired: _adminApproval,
        isMinScoreRequired: _minScoreRequired,
        minScore: int.tryParse(_minScoreController.text.trim()) ?? 0,
        minAge: _ageRange.start.round(),
        maxAge: _ageRange.end.round(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('השינויים נשמרו בהצלחה')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שמירת שינויים נכשלה: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _removeMember(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty || normalizedUid.contains('/')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('מזהה משתמש לא תקין להסרה')),
      );
      return;
    }

    if (_removingUids.contains(normalizedUid)) return;
    setState(() {
      _removingUids.add(normalizedUid);
    });

    try {
      await _groupService.removeMember(widget.groupId, normalizedUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('החבר הוסר מהקבוצה בהצלחה')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('הסרת חבר נכשלה: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _removingUids.remove(normalizedUid);
        });
      }
    }
  }

  Future<bool> _confirmRemoveMember(String name) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
          title: Text(
            'האם אתה בטוח?',
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'להסיר את $name מהקבוצה?',
            style: TextStyle(
              color: isLight ? const Color(0xFF46536D) : Colors.white70,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'לא',
                style: TextStyle(
                  color: isLight ? const Color(0xFF46536D) : Colors.white70,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isLight ? const Color(0xFFE8EEFF) : const Color(0xFFFF3B30),
                foregroundColor:
                    isLight ? const Color(0xFF1E2A45) : Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('כן'),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  Future<String?> _showCategoryChoiceSheet({
    required String title,
    required List<String> options,
    String? selectedValue,
  }) async {
    if (options.isEmpty) {
      return null;
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (sheetContext, _, __) {
        final mediaSize = MediaQuery.of(sheetContext).size;
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
                                      Navigator.of(sheetContext).pop(),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: isLight
                                        ? const Color(0xFF33405B)
                                        : Colors.white70,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
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
                                    final isSelected = option == selectedValue;
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => Navigator.of(sheetContext)
                                            .pop(option),
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
                                                      .withValues(alpha: 0.72),
                                              width: isSelected ? 1.8 : 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF76CFFF)
                                                    .withValues(alpha: isSelected
                                                        ? 0.42
                                                        : 0.32),
                                                blurRadius:
                                                    isSelected ? 18 : 14,
                                                offset: const Offset(0, 7),
                                              ),
                                            ],
                                          ),
                                          child: Stack(
                                            children: [
                                              Positioned(
                                                top: 16,
                                                left: 0,
                                                right: 0,
                                                child: Icon(
                                                  categoryIconFor(option),
                                                  color:
                                                      const Color(0xFF2A2361),
                                                  size: 28,
                                                ),
                                              ),
                                              Center(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                    10,
                                                    52,
                                                    10,
                                                    12,
                                                  ),
                                                  child: Text(
                                                    option,
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

  Widget _buildCategoryPickerTile({
    required IconData icon,
    required String title,
    required String value,
    required String hint,
    required VoidCallback? onTap,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final hasValue = value.trim().isNotEmpty;
    final titleLabel =
        title.contains('תת') ? 'בחירת תת קטגוריה' : 'בחירת קטגוריה';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(1.4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    const Color(0xFF76CFFF).withValues(alpha: isLight ? 0.2 : 0.12),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFF8FCFF) : const Color(0xFF1E2632),
              borderRadius: BorderRadius.circular(19),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: const Color(0xFF2A2361),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          titleLabel,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF223A5C)
                                : Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      hasValue
                          ? Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 38,
                                  minWidth: 140,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: isLight
                                        ? const [
                                            Color(0xFFBEEFFF),
                                            Color(0xFFDDD0FF),
                                          ]
                                        : const [
                                            Color(0xFF89DDFF),
                                            Color(0xFFB69BFF),
                                          ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: isLight
                                        ? const Color(0xFFAAD6FF)
                                        : const Color(0xFFCBB9FF),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF9ECFFF)
                                          .withValues(alpha: isLight ? 0.32 : 0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  value,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF2A3563),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            )
                          : Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                hint,
                                style: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.touch_app_rounded,
                  color: isLight
                      ? const Color(0xFF7B6BE0)
                      : const Color(0xFF9EDBFF),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openRemoveMembersSheet() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'חזרה',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(
                        Icons.arrow_back,
                        color: isLight ? Colors.black87 : Colors.white,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'הסרת חברים מהקבוצה',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .collection('chats')
                        .doc(widget.groupId)
                        .snapshots(),
                    builder: (context, chatSnapshot) {
                      final chatData = chatSnapshot.data?.data() ??
                          const <String, dynamic>{};

                      return StreamBuilder<
                          DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .collection('groups')
                            .doc(widget.groupId)
                            .snapshots(),
                        builder: (context, groupSnapshot) {
                          final groupData = groupSnapshot.data?.data() ??
                              const <String, dynamic>{};
                          final mergedData = <String, dynamic>{
                            ...widget.initialGroupData,
                            ...chatData,
                            ...groupData,
                          };
                          final adminUid =
                              (mergedData['adminUid'] as String? ?? '').trim();

                          return StreamBuilder<
                              QuerySnapshot<Map<String, dynamic>>>(
                            stream: FirebaseFirestore.instance
                                .collection('groups')
                                .doc(widget.groupId)
                                .collection('members')
                                .snapshots(),
                            builder: (context, snapshot) {
                              final docs = snapshot.data?.docs ??
                                  const <QueryDocumentSnapshot<
                                      Map<String, dynamic>>>[];

                              final memberUidsSet = <String>{};
                              for (final doc in docs) {
                                final status =
                                    (doc.data()['status'] as String? ?? '')
                                        .trim();
                                if (status == 'pending' || status == 'denied') {
                                  continue;
                                }
                                final uid = doc.id.trim();
                                if (uid.isNotEmpty) {
                                  memberUidsSet.add(uid);
                                }
                              }

                              final members =
                                  (mergedData['members'] as List<dynamic>? ??
                                          const <dynamic>[])
                                      .map(_extractUid)
                                      .where((uid) => uid.isNotEmpty);
                              memberUidsSet.addAll(members);

                              final membersList = (mergedData['membersList']
                                          as List<dynamic>? ??
                                      const <dynamic>[])
                                  .map(_extractUid)
                                  .where((uid) => uid.isNotEmpty);
                              memberUidsSet.addAll(membersList);

                              final participants = (mergedData['participants']
                                          as List<dynamic>? ??
                                      const <dynamic>[])
                                  .map(_extractUid)
                                  .where((uid) => uid.isNotEmpty);
                              memberUidsSet.addAll(participants);

                              memberUidsSet.remove(adminUid);
                              final memberUids = memberUidsSet.toList(
                                  growable: false)
                                ..sort((a, b) => a.compareTo(b));

                              if (memberUids.isEmpty) {
                                return Center(
                                  child: Text(
                                    'אין חברים להסרה',
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF46536D)
                                          : Colors.white54,
                                    ),
                                  ),
                                );
                              }

                              return ListView.builder(
                                itemCount: memberUids.length,
                                itemBuilder: (context, index) {
                                  final uid = memberUids[index];
                                  final isRemoving =
                                      _removingUids.contains(uid);

                                  return StreamBuilder(
                                    key: ValueKey('member-profile-$uid'),
                                    stream: _publicUserProfileService
                                        .streamProfile(uid),
                                    builder: (context, profileSnapshot) {
                                      final profile = profileSnapshot.data;
                                      final name = (profile?.displayName ?? '')
                                              .trim()
                                              .isNotEmpty
                                          ? profile!.displayName
                                          : ((profile?.username ?? '')
                                                  .trim()
                                                  .isNotEmpty
                                              ? profile!.username
                                              : uid);
                                      final avatarUrl =
                                          (profile?.profilePictureUrl ?? '')
                                              .trim();
                                      final initial =
                                          name.isNotEmpty ? name[0] : 'U';

                                      return ListTile(
                                        key: ValueKey('member-tile-$uid'),
                                        contentPadding: EdgeInsets.zero,
                                        leading: CircleAvatar(
                                          backgroundColor:
                                              const Color(0xFF9E7CFF),
                                          backgroundImage: avatarUrl.isNotEmpty
                                              ? NetworkImage(avatarUrl)
                                              : null,
                                          child: avatarUrl.isEmpty
                                              ? Text(initial,
                                                  style: const TextStyle(
                                                      color: Colors.black))
                                              : null,
                                        ),
                                        title: Text(name,
                                            style: TextStyle(
                                              color: isLight
                                                  ? Colors.black
                                                  : Colors.white,
                                            )),
                                        trailing: TextButton(
                                          onPressed: isRemoving
                                              ? null
                                              : () async {
                                                  final shouldRemove =
                                                      await _confirmRemoveMember(
                                                          name);
                                                  if (!shouldRemove) return;
                                                  await _removeMember(uid);
                                                },
                                          child: isRemoving
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2),
                                                )
                                              : const Text(
                                                  'הסר',
                                                  style: TextStyle(
                                                      color: Colors.redAccent),
                                                ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          );
                        },
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
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final panelColor =
        isLight ? Colors.white.withValues(alpha: 0.86) : const Color(0xFF1E2632);
    final fieldFillColor =
        isLight ? const Color(0xFFF2F7FF) : const Color(0xFF0B1019);
    final fieldBorderColor =
        isLight ? const Color(0xFFA9C3FF) : Colors.transparent;
    final primaryTextColor = isLight ? Colors.black : Colors.white;
    final secondaryTextColor =
        isLight ? const Color(0xFF46536D) : Colors.white70;
    final subCategories = appSubCategories(_mainCategory);

    return SwipeBackWrapper(
      child: Scaffold(
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      appBar: AppBar(
        backgroundColor:
            isLight ? const Color(0xFFBFD9FF) : const Color(0xFF1E2632),
        elevation: 0,
        iconTheme: IconThemeData(color: primaryTextColor),
        title: Text(
          'הגדרות קבוצה',
          style:
              TextStyle(color: primaryTextColor, fontWeight: FontWeight.bold),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isLight
                ? const [Color(0xFFF8FBFF), Colors.white]
                : const [Color(0xFF0B1019), Color(0xFF131B33)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: panelColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color:
                            isLight ? const Color(0xFFA9C3FF) : Colors.white12,
                      ),
                      image: _existingImageUrl.isNotEmpty
                          ? DecorationImage(
                              image: NetworkImage(_existingImageUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: _existingImageUrl.isEmpty
                        ? Icon(
                            Icons.groups_rounded,
                            color: isLight
                                ? const Color(0xFF5A6CFF)
                                : Colors.white54,
                            size: 30,
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _groupNameController,
                  enabled: widget.isAdmin,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                  decoration: InputDecoration(
                    hintText: 'שם הקבוצה',
                    hintStyle: TextStyle(color: secondaryTextColor),
                    filled: true,
                    fillColor: panelColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: fieldBorderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: fieldBorderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: isLight
                            ? const Color(0xFF8EA8FF)
                            : const Color(0xFF53C1F9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  enabled: widget.isAdmin,
                  maxLines: 3,
                  style: TextStyle(color: secondaryTextColor),
                  decoration: InputDecoration(
                    hintText: 'תיאור הקבוצה',
                    hintStyle: TextStyle(color: secondaryTextColor),
                    filled: true,
                    fillColor: panelColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: fieldBorderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: fieldBorderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: isLight
                            ? const Color(0xFF8EA8FF)
                            : const Color(0xFF53C1F9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _buildCategoryPickerTile(
                  icon: Icons.category,
                  title: 'קטגוריה ראשית',
                  value: _mainCategory ?? kGeneralCategory,
                  hint: 'בחר קטגוריה',
                  onTap: !widget.isAdmin
                      ? null
                      : () async {
                          final selected = await _showCategoryChoiceSheet(
                            title: 'בחר קטגוריה ראשית',
                            options: appMainCategories,
                            selectedValue: _mainCategory,
                          );
                          if (!mounted || selected == null) return;
                          setState(() {
                            _mainCategory = selected;
                            _subCategory = null;
                          });
                        },
                ),
                if (_mainCategory != null &&
                    !isGeneralCategory(_mainCategory) &&
                    subCategories.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildCategoryPickerTile(
                    icon: Icons.subdirectory_arrow_right,
                    title: 'תת קטגוריה',
                    value: _subCategory ?? 'אחר',
                    hint: 'בחר תת קטגוריה',
                    onTap: !widget.isAdmin
                        ? null
                        : () async {
                            final selected = await _showCategoryChoiceSheet(
                              title: _mainCategory!,
                              options: subCategories,
                              selectedValue: _subCategory,
                            );
                            if (!mounted || selected == null) return;
                            setState(() {
                              _subCategory = selected;
                            });
                          },
                  ),
                ],
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: widget.isAdmin ? _selectExecutionDate : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 16),
                    decoration: BoxDecoration(
                      color: panelColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isLight
                            ? const Color(0xFFA9C3FF)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _executionDate != null
                              ? 'תאריך ביצוע: ${_executionDate!.day}/${_executionDate!.month}/${_executionDate!.year} ${_executionDate!.hour}:${_executionDate!.minute.toString().padLeft(2, '0')}'
                              : 'תאריך חסר',
                          style: TextStyle(color: secondaryTextColor),
                        ),
                        Icon(
                          Icons.calendar_today,
                          color: isLight
                              ? const Color(0xFF5A6CFF)
                              : Colors.white54,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: panelColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isLight ? const Color(0xFFA9C3FF) : Colors.white12,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'הגדרות מנהל',
                            style: TextStyle(
                              color: primaryTextColor,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Icon(Icons.lock_open, color: Color(0xFF9E7CFF)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('פרטיות:',
                              style: TextStyle(color: primaryTextColor)),
                          const SizedBox(width: 12),
                          ChoiceChip(
                            label: Text(
                              'ציבורית',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF24314F)
                                    : Colors.white,
                              ),
                            ),
                            selected: _isPublic,
                            onSelected: widget.isAdmin
                                ? (value) => setState(() => _isPublic = true)
                                : null,
                            selectedColor: const Color(0xFF9E7CFF),
                            backgroundColor: fieldFillColor,
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: Text(
                              'פרטית',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF24314F)
                                    : Colors.white,
                              ),
                            ),
                            selected: !_isPublic,
                            onSelected: widget.isAdmin
                                ? (value) => setState(() => _isPublic = false)
                                : null,
                            selectedColor: const Color(0xFF9E7CFF),
                            backgroundColor: fieldFillColor,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('דרישת מינימום ניקוד',
                              style: TextStyle(color: primaryTextColor)),
                          Switch(
                            value: _minScoreRequired,
                            activeThumbColor: const Color(0xFF9E7CFF),
                            onChanged: widget.isAdmin
                                ? (value) => setState(() {
                                      _minScoreRequired = value;
                                    })
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _minScoreController,
                        enabled: widget.isAdmin && _minScoreRequired,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: primaryTextColor),
                        decoration: InputDecoration(
                          hintText: 'ניקוד מינימלי להצטרפות',
                          hintStyle: TextStyle(color: secondaryTextColor),
                          filled: true,
                          fillColor: fieldFillColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: fieldBorderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: fieldBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isLight
                                  ? const Color(0xFF8EA8FF)
                                  : const Color(0xFF53C1F9),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('טווח גילאים',
                              style: TextStyle(color: primaryTextColor)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final minAge = _ageRange.start.round();
                                final maxAge = _ageRange.end.round();
                                final isRtl = Directionality.of(context) ==
                                    TextDirection.rtl;
                                const bubbleWidth = 42.0;
                                const thumbRadius = 10.0;
                                final trackWidth =
                                    constraints.maxWidth > thumbRadius * 2
                                        ? constraints.maxWidth - thumbRadius * 2
                                        : 0.0;
                                final maxBubbleLeft =
                                  (constraints.maxWidth - bubbleWidth)
                                    .clamp(0.0, double.infinity);

                                double thumbOffsetFor(int value) {
                                  final normalized = (value - minimumUserAge) /
                                      (maximumAgeRange - minimumUserAge);
                                  final adjusted =
                                      isRtl ? 1 - normalized : normalized;
                                  final thumbCenter = thumbRadius +
                                      trackWidth * adjusted.clamp(0.0, 1.0);
                                  return thumbCenter - (bubbleWidth / 2);
                                }

                                double bubbleLeftFor(int value) {
                                  return thumbOffsetFor(value)
                                    .clamp(0.0, maxBubbleLeft);
                                }

                                final minOffset = bubbleLeftFor(minAge);
                                final maxOffset = bubbleLeftFor(maxAge);

                                Widget valueBubble(int value) {
                                  return Container(
                                    width: bubbleWidth,
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF8DE8FF),
                                          Color(0xFFC6B2FF),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.7),
                                      ),
                                    ),
                                    child: Text(
                                      value.toString(),
                                      style: const TextStyle(
                                        color: Color(0xFF2A2C5A),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  );
                                }

                                return Column(
                                  children: [
                                    SizedBox(
                                      height: 32,
                                      child: Stack(
                                        children: [
                                          Positioned(
                                            left: minOffset,
                                            child: valueBubble(minAge),
                                          ),
                                          Positioned(
                                            left: maxOffset,
                                            child: valueBubble(maxAge),
                                          ),
                                        ],
                                      ),
                                    ),
                                    RangeSlider(
                                      values: _ageRange,
                                      min: minimumUserAge.toDouble(),
                                      max: maximumAgeRange.toDouble(),
                                      divisions:
                                          maximumAgeRange - minimumUserAge,
                                      onChanged: widget.isAdmin
                                          ? (value) =>
                                              setState(() => _ageRange = value)
                                          : null,
                                      activeColor: const Color(0xFF9E7CFF),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _meetingRegionController,
                        enabled: widget.isAdmin,
                        style: TextStyle(color: primaryTextColor),
                        decoration: InputDecoration(
                          hintText: 'אזור המפגש',
                          hintStyle: TextStyle(color: secondaryTextColor),
                          filled: true,
                          fillColor: fieldFillColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: fieldBorderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: fieldBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isLight
                                  ? const Color(0xFF8EA8FF)
                                  : const Color(0xFF53C1F9),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('אישור מנהל',
                              style: TextStyle(color: primaryTextColor)),
                          Switch(
                            value: _adminApproval,
                            activeThumbColor: const Color(0xFF9E7CFF),
                            onChanged: widget.isAdmin
                                ? (value) =>
                                    setState(() => _adminApproval = value)
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isLight
                              ? const Color(0xFFE8EEFF)
                              : const Color(0xFF2A3242),
                          foregroundColor:
                              isLight ? const Color(0xFF1E2A45) : Colors.white,
                          side: isLight
                              ? const BorderSide(color: Color(0xFFA9C3FF))
                              : BorderSide.none,
                        ),
                        onPressed:
                            widget.isAdmin ? _openRemoveMembersSheet : null,
                        icon: const Icon(Icons.person_remove),
                        label: const Text('הסרת חברים'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9E7CFF),
                    foregroundColor: isLight ? Colors.white : Colors.black,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _isSaving ? null : _saveChanges,
                  child: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('שמור שינויים',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
