import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'age_restrictions.dart';
import 'app_categories.dart';
import 'services/group_service.dart';
import 'services/public_user_profile_service.dart';
import 'widgets/group_avatar.dart';
import 'widgets/swipe_back_wrapper.dart';

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

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final ImagePicker _picker = ImagePicker();
  final GroupService _groupService = GroupService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  Uint8List? _pickedBytes;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();
  final TextEditingController _minScoreController = TextEditingController();

  final List<_FriendOption> _allFriends = <_FriendOption>[];
  final List<String> _selectedFriendUids = <String>[];
  List<_FriendOption> _filteredFriends = <_FriendOption>[];
  bool _friendsLoading = false;

  String? _mainCategory;
  String? _subCategory;

  bool _isPublic = true; // default Public
  bool _adminApproval = false; // default No
  RangeValues _ageRange = RangeValues(
    minimumUserAge.toDouble(),
    maximumAgeRange.toDouble(),
  );
  DateTime? _executionDate;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _regionController.dispose();
    _minScoreController.dispose();
    super.dispose();
  }

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

  Future<void> _pickImage() async {
    final source = await _selectImageSource();
    if (source == null) return;

    try {
      final file = await _picker.pickImage(source: source);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pickedBytes = bytes;
      });
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
    }
  }

  Future<void> _openAddFriends() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
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
                    color: isLight ? Colors.black12 : Colors.white12,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (v) {
                      final query = v.trim();
                      setModalState(() {
                        _filteredFriends = _allFriends.where((friend) {
                          if (query.isEmpty) return true;
                          return friend.name.contains(query);
                        }).toList(growable: false);
                      });
                    },
                    style:
                        TextStyle(color: isLight ? Colors.black : Colors.white),
                    decoration: InputDecoration(
                      hintText: 'חפש חברים',
                      hintStyle: TextStyle(
                        color: isLight ? Colors.black54 : Colors.white54,
                      ),
                      border:
                          const OutlineInputBorder(borderSide: BorderSide.none),
                      filled: true,
                      fillColor: isLight
                          ? Colors.white.withValues(alpha: 0.62)
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
                                  final selected =
                                      _selectedFriendUids.contains(friend.uid);
                                  final initial = friend.name.isNotEmpty
                                      ? friend.name[0]
                                      : 'U';
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: const Color(0xFF9E7CFF),
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
                                    title: Text(friend.name,
                                        style: TextStyle(
                                            color: isLight
                                                ? Colors.black
                                                : Colors.white)),
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
                      backgroundColor:
                          isLight ? Colors.white : const Color(0xFF9E7CFF),
                      foregroundColor:
                          isLight ? const Color(0xFF9E7CFF) : Colors.black,
                      side: isLight
                          ? const BorderSide(color: Color(0xFFB79BFF))
                          : BorderSide.none,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('בוצע'),
                  )
                ],
              ),
            ),
          );
        });
      },
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _selectExecutionDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _executionDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
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
      _executionDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
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
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
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
                                                    .withValues(
                                                        alpha: isSelected
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
    required VoidCallback onTap,
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
                color: const Color(0xFF76CFFF)
                    .withValues(alpha: isLight ? 0.2 : 0.12),
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
                                      color: const Color(0xFF9ECFFF).withValues(
                                          alpha: isLight ? 0.32 : 0.2),
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

  Future<void> _createGroup() async {
    if (_isCreating) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('יש להזין שם לקבוצה')));
      return;
    }

    final selectedMainCategory = (_mainCategory?.trim().isNotEmpty ?? false)
        ? _mainCategory!.trim()
        : kGeneralCategory;
    final selectedSubCategory = isGeneralCategory(selectedMainCategory)
        ? ''
        : ((_subCategory?.trim().isNotEmpty ?? false)
            ? _subCategory!.trim()
            : 'אחר');

    if (_isPublic && _executionDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('יש לבחור תאריך ביצוע לקבוצה ציבורית')));
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final groupId = await _groupService.createGroup(
        groupName: name,
        description: _descriptionController.text.trim(),
        category: selectedMainCategory,
        subCategory: selectedSubCategory,
        location: _regionController.text.trim(),
        date: _isPublic
            ? (_executionDate ?? DateTime.now().add(const Duration(days: 7)))
            : DateTime.now().add(const Duration(days: 7)),
        minAge: _ageRange.start.round(),
        maxAge: _ageRange.end.round(),
        minScore: int.tryParse(_minScoreController.text.trim()) ?? 0,
        isPublic: _isPublic,
        isAdminApprovalRequired: _adminApproval,
        groupImageBytes: _pickedBytes,
        imageFileName: 'group_${DateTime.now().millisecondsSinceEpoch}.jpg',
        invitedFriendUids: List<String>.from(_selectedFriendUids),
      );

      final newGroupData = {
        'id': groupId,
        'name': name,
        'description': _descriptionController.text.trim(),
        'avatarUrl': '',
        'isPublic': _isPublic,
        'adminApproval': _adminApproval,
        'mainCategory': selectedMainCategory,
        'subCategory': selectedSubCategory,
        'selectedFriends': _allFriends
            .where((friend) => _selectedFriendUids.contains(friend.uid))
            .map((friend) => friend.name)
            .toList(growable: false),
        'selectedFriendUids': List<String>.from(_selectedFriendUids),
        'memberCount': 1,
        'mutualFriends': _selectedFriendUids.length,
        'lastMessage': 'קבוצה חדשה נוצרה',
      };

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('הקבוצה נוצרה בהצלחה!')));
      Navigator.pop(context, newGroupData);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('יצירת קבוצה נכשלה: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final subCategories = appSubCategories(_mainCategory);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.78).clamp(220.0, 300.0);
    final orbSizeB = (screenWidth * 0.86).clamp(240.0, 320.0);

    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        appBar: AppBar(
          backgroundColor:
              isLight ? const Color(0xFFCFEFFF) : Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back,
              color: isLight ? Colors.black : Colors.white,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            'קבוצה חדשה',
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        body: Stack(
          children: [
            if (isLight)
              Positioned(
                top: -110,
                right: -90,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeA,
                    height: orbSizeA,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFB9A9FF).withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            if (isLight)
              Positioned(
                bottom: -120,
                left: -90,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeB,
                    height: orbSizeB,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF9EEBFF).withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: _pickImage,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      GroupAvatar(
                                        radius: 39,
                                        memoryBytes: _pickedBytes,
                                        borderColor: isLight
                                            ? const Color(0xFFA9C3FF)
                                            : const Color(0xFF53C1F9)
                                                .withValues(alpha: 0.18),
                                        borderWidth: 1.2,
                                      ),
                                      Positioned(
                                        bottom: 2,
                                        child: Container(
                                          padding: const EdgeInsets.all(5),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? Colors.white
                                                    .withValues(alpha: 0.94)
                                                : const Color(0xFF1E2632),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFFA9C3FF)
                                                  : const Color(0xFF53C1F9)
                                                      .withValues(alpha: 0.18),
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.camera_alt_rounded,
                                            size: 16,
                                            color: isLight
                                                ? const Color(0xFF7B6BE0)
                                                : const Color(0xFF9EDBFF),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: _nameController,
                                    maxLength: 40,
                                    style: TextStyle(
                                        color: isLight
                                            ? Colors.black
                                            : Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16),
                                    decoration: InputDecoration(
                                        counterStyle: TextStyle(
                                            color: isLight
                                                ? Colors.black54
                                                : Colors.white54),
                                        hintText: 'שם הקבוצה',
                                        hintStyle: TextStyle(
                                            color: isLight
                                                ? Colors.black54
                                                : Colors.white54),
                                        border: InputBorder.none),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _descriptionController,
                              maxLines: 3,
                              style: TextStyle(
                                  color: isLight
                                      ? Colors.black87
                                      : Colors.white70),
                              decoration: InputDecoration(
                                  hintText: 'תיאור הקבוצה',
                                  hintStyle: TextStyle(
                                      color: isLight
                                          ? Colors.black54
                                          : Colors.white54),
                                  filled: true,
                                  fillColor: isLight
                                      ? Colors.white.withValues(alpha: 0.62)
                                      : const Color(0xFF1E2632),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : Colors.transparent,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : Colors.transparent,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFF8FAEFF)
                                          : Colors.transparent,
                                      width: 1.2,
                                    ),
                                  )),
                            ),
                            const SizedBox(height: 12),
                            ListTile(
                              onTap: _openAddFriends,
                              tileColor: isLight
                                  ? Colors.white.withValues(alpha: 0.62)
                                  : const Color(0xFF1E2632),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(
                                  color: isLight
                                      ? const Color(0xFFA9C3FF)
                                      : Colors.transparent,
                                ),
                              ),
                              leading: Icon(Icons.person_add,
                                  color: isLight
                                      ? const Color(0xFF9AB0FF)
                                      : Colors.white),
                              title: Text('הוסף חברים (אופציונלי)',
                                  style: TextStyle(
                                      color: isLight
                                          ? Colors.black
                                          : Colors.white)),
                              subtitle: _selectedFriendUids.isEmpty
                                  ? null
                                  : Text(
                                      'נבחרו ${_selectedFriendUids.length} חברים',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black54
                                              : Colors.white54),
                                    ),
                              trailing: Icon(
                                Icons.chevron_right,
                                color:
                                    isLight ? Colors.black54 : Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _buildCategoryPickerTile(
                              icon: Icons.category,
                              title: 'קטגוריה ראשית',
                              value: _mainCategory ?? kGeneralCategory,
                              hint: 'בחר קטגוריה',
                              onTap: () async {
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
                            const SizedBox(height: 8),
                            if (_mainCategory != null &&
                                !isGeneralCategory(_mainCategory) &&
                                subCategories.isNotEmpty)
                              _buildCategoryPickerTile(
                                icon: Icons.subdirectory_arrow_right,
                                title: 'תת קטגוריה',
                                value: _subCategory ?? 'אחר',
                                hint: 'בחר תת קטגוריה',
                                onTap: () async {
                                  final selected =
                                      await _showCategoryChoiceSheet(
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

                            const SizedBox(height: 12),
                            // Privacy selector
                            Row(
                              children: [
                                Text('פרטיות:',
                                    style: TextStyle(
                                        color: isLight
                                            ? Colors.black
                                            : Colors.white)),
                                const SizedBox(width: 12),
                                ChoiceChip(
                                  label: Text('ציבורית',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white)),
                                  selected: _isPublic,
                                  onSelected: (v) =>
                                      setState(() => _isPublic = true),
                                  selectedColor: const Color(0xFF9E7CFF),
                                  backgroundColor: isLight
                                      ? Colors.white.withValues(alpha: 0.62)
                                      : const Color(0xFF1E2632),
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  label: Text('פרטית',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white)),
                                  selected: !_isPublic,
                                  onSelected: (v) =>
                                      setState(() => _isPublic = false),
                                  selectedColor: const Color(0xFF9E7CFF),
                                  backgroundColor: isLight
                                      ? Colors.white.withValues(alpha: 0.62)
                                      : const Color(0xFF1E2632),
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),
                            if (_isPublic) ...[
                              GestureDetector(
                                onTap: _selectExecutionDate,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 16, horizontal: 16),
                                  decoration: BoxDecoration(
                                    color: isLight
                                        ? Colors.white.withValues(alpha: 0.62)
                                        : const Color(0xFF1E2632),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        _executionDate != null
                                            ? 'תאריך ביצוע: ${_executionDate!.day}/${_executionDate!.month}/${_executionDate!.year} ${_executionDate!.hour.toString().padLeft(2, '0')}:${_executionDate!.minute.toString().padLeft(2, '0')}'
                                            : 'תאריך ביצוע',
                                        style: TextStyle(
                                            color: isLight
                                                ? Colors.black87
                                                : Colors.white70),
                                      ),
                                      Icon(Icons.calendar_today,
                                          color: isLight
                                              ? Colors.black54
                                              : Colors.white54,
                                          size: 20),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _regionController,
                                style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white),
                                decoration: InputDecoration(
                                    hintText: 'אזור הקבוצה',
                                    hintStyle: TextStyle(
                                        color: isLight
                                            ? Colors.black54
                                            : Colors.white54),
                                    filled: true,
                                    fillColor: isLight
                                        ? Colors.white.withValues(alpha: 0.62)
                                        : const Color(0xFF1E2632),
                                    border: InputBorder.none),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _minScoreController,
                                keyboardType: TextInputType.number,
                                style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white),
                                decoration: InputDecoration(
                                    hintText: 'ניקוד מינימלי (אופציונלי)',
                                    hintStyle: TextStyle(
                                        color: isLight
                                            ? Colors.black54
                                            : Colors.white54),
                                    filled: true,
                                    fillColor: isLight
                                        ? Colors.white.withValues(alpha: 0.62)
                                        : const Color(0xFF1E2632),
                                    border: InputBorder.none),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text('טווח גילאים',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final minAge =
                                                _ageRange.start.round();
                                            final maxAge =
                                                _ageRange.end.round();
                                            final isRtl =
                                                Directionality.of(context) ==
                                                    TextDirection.rtl;
                                            const bubbleWidth = 42.0;
                                            const thumbRadius = 10.0;
                                            final trackWidth =
                                                constraints.maxWidth >
                                                        thumbRadius * 2
                                                    ? constraints.maxWidth -
                                                        thumbRadius * 2
                                                    : 0.0;
                                            final maxBubbleLeft = (constraints
                                                        .maxWidth -
                                                    bubbleWidth)
                                                .clamp(0.0, double.infinity);
                                            double thumbOffsetFor(int value) {
                                              final normalized =
                                                  (value - minimumUserAge) /
                                                      (maximumAgeRange -
                                                          minimumUserAge);
                                              final adjusted = isRtl
                                                  ? 1 - normalized
                                                  : normalized;
                                              final thumbCenter = thumbRadius +
                                                  trackWidth *
                                                      adjusted.clamp(
                                                        0.0,
                                                        1.0,
                                                      );
                                              return thumbCenter -
                                                  (bubbleWidth / 2);
                                            }

                                            double bubbleLeftFor(int value) {
                                              return thumbOffsetFor(value)
                                                  .clamp(0.0, maxBubbleLeft);
                                            }

                                            final minOffset =
                                                bubbleLeftFor(minAge);
                                            final maxOffset =
                                                bubbleLeftFor(maxAge);

                                            Widget valueBubble(int value) {
                                              return Container(
                                                width: bubbleWidth,
                                                alignment: Alignment.center,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  gradient:
                                                      const LinearGradient(
                                                    colors: [
                                                      Color(0xFF8DE8FF),
                                                      Color(0xFFC6B2FF),
                                                    ],
                                                    begin: Alignment.topLeft,
                                                    end: Alignment.bottomRight,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                  border: Border.all(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.7),
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
                                                        child:
                                                            valueBubble(minAge),
                                                      ),
                                                      Positioned(
                                                        left: maxOffset,
                                                        child:
                                                            valueBubble(maxAge),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                RangeSlider(
                                                  values: _ageRange,
                                                  min:
                                                      minimumUserAge.toDouble(),
                                                  max: maximumAgeRange
                                                      .toDouble(),
                                                  divisions: maximumAgeRange -
                                                      minimumUserAge,
                                                  onChanged: (v) => setState(
                                                      () => _ageRange = v),
                                                  activeColor:
                                                      const Color(0xFF9E7CFF),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('אישור מנהל',
                                      style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white)),
                                  Switch(
                                    value: _adminApproval,
                                    activeThumbColor: const Color(0xFF9E7CFF),
                                    onChanged: (v) =>
                                        setState(() => _adminApproval = v),
                                  ),
                                ],
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _adminApproval
                                      ? 'מצב אישור מנהל פעיל: כל בקשת הצטרפות תמתין לאישור.'
                                      : 'מצב אישור מנהל כבוי: משתמשים מתאימים יצורפו אוטומטית.',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color: isLight
                                        ? Colors.black54
                                        : Colors.white54,
                                    fontSize: 12,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isLight ? Colors.white : const Color(0xFF9E7CFF),
                          foregroundColor:
                              isLight ? const Color(0xFF9E7CFF) : Colors.black,
                          side: isLight
                              ? const BorderSide(color: Color(0xFFB79BFF))
                              : BorderSide.none,
                          minimumSize: const Size.fromHeight(52)),
                      onPressed: _isCreating ? null : _createGroup,
                      child: _isCreating
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: isLight
                                      ? const Color(0xFF9E7CFF)
                                      : Colors.black),
                            )
                          : Text('צור קבוצה!',
                              style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF9E7CFF)
                                      : Colors.black,
                                  fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
