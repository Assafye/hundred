class PublicUserProfile {
  final String userId;
  final String username;
  final String displayName;
  final String profilePictureUrl;
  final List<String> profileImageUrls;
  final String bio;
  final bool isPrivate;
  final bool isDeleted;
  final int followerCount;
  final int followingCount;
  final int score;
  final bool exists;

  const PublicUserProfile({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.profilePictureUrl,
    required this.profileImageUrls,
    required this.bio,
    required this.isPrivate,
    required this.isDeleted,
    required this.followerCount,
    required this.followingCount,
    required this.score,
    required this.exists,
  });

  factory PublicUserProfile.fromMap(
      String documentId, Map<String, dynamic> data) {
    final resolvedUserId =
        _readString(data, const ['uid', 'userId'], fallback: documentId);
    final normalizedUsername = _normalizeUsername(
      _readString(data, const ['username']),
      fallbackUserId: resolvedUserId,
    );
    final firstName = _readString(data, const ['firstName']);
    final lastName = _readString(data, const ['lastName']);
    final explicitDisplayName =
        _readString(data, const ['displayName', 'fullName']);
    final combinedName =
        [firstName, lastName].where((part) => part.isNotEmpty).join(' ').trim();
    final fallbackDisplayName =
        normalizedUsername.isNotEmpty ? normalizedUsername : 'משתמש';
    final profilePictureUrl = _readString(
      data,
      const ['profilePictureUrl', 'profileImageUrl', 'avatarUrl'],
    );
    final profileImageUrls = _readImageUrls(data);
    final isPrivate = (data['isPrivate'] as bool?) ?? false;
    final isDeleted = (data['isDeleted'] as bool?) ?? false;
    final resolvedDisplayName = isDeleted
        ? 'משתמש מחוק'
        : (explicitDisplayName.isNotEmpty
            ? explicitDisplayName
            : (combinedName.isNotEmpty ? combinedName : fallbackDisplayName));
    final resolvedProfilePictureUrl = isDeleted ? '' : profilePictureUrl;

    return PublicUserProfile(
      userId: resolvedUserId,
      username: normalizedUsername,
      displayName: resolvedDisplayName,
      profilePictureUrl: resolvedProfilePictureUrl,
      profileImageUrls: isDeleted ? const <String>[] : profileImageUrls,
      bio: _readString(data, const ['bio']),
      isPrivate: isPrivate,
      isDeleted: isDeleted,
      followerCount: _readCount(data,
          primaryKey: 'followerCount', legacyKey: 'followersCount'),
      followingCount: _readCount(data,
          primaryKey: 'followingCount', legacyKey: 'followingCount'),
      score: (data['score'] as num?)?.toInt() ?? 0,
      exists: true,
    );
  }

  factory PublicUserProfile.fallback({
    required String userId,
    String username = '',
    String displayName = '',
    String profilePictureUrl = '',
    String bio = '',
    bool isPrivate = false,
    bool isDeleted = false,
    int followerCount = 0,
    int followingCount = 0,
    int score = 0,
    bool exists = false,
  }) {
    final normalizedUsername =
        _normalizeUsername(username, fallbackUserId: userId);
    final resolvedDisplayName = displayName.trim().isNotEmpty
        ? displayName.trim()
        : (normalizedUsername.isNotEmpty
            ? normalizedUsername
            : 'משתמש לא נמצא');

    return PublicUserProfile(
      userId: userId.trim(),
      username: normalizedUsername,
      displayName: isDeleted ? 'משתמש מחוק' : resolvedDisplayName,
      profilePictureUrl: isDeleted ? '' : profilePictureUrl.trim(),
      profileImageUrls: const <String>[],
      bio: bio.trim(),
      isPrivate: isPrivate,
      isDeleted: isDeleted,
      followerCount: followerCount,
      followingCount: followingCount,
      score: score,
      exists: exists,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': userId,
      'userId': userId,
      'username': username,
      'displayName': displayName,
      'profilePictureUrl': profilePictureUrl,
      'profileImageUrl': profilePictureUrl,
      'avatarUrl': profilePictureUrl,
      'profileImageUrls': profileImageUrls,
      'images': profileImageUrls,
      'bio': bio,
      'isPrivate': isPrivate,
      'isDeleted': isDeleted,
      'followerCount': followerCount,
      'followersCount': followerCount,
      'followingCount': followingCount,
      'score': score,
    };
  }

  String get handle {
    if (isDeleted) {
      return 'משתמש מחוק';
    }
    if (username.isNotEmpty) {
      return username.startsWith('@') ? username : '@$username';
    }
    if (userId.isEmpty) {
      return '@unknown';
    }
    final shortUserId =
        userId.substring(0, userId.length > 6 ? 6 : userId.length);
    return '@$shortUserId';
  }

  static int _readCount(
    Map<String, dynamic> data, {
    required String primaryKey,
    required String legacyKey,
  }) {
    return (data[primaryKey] as num?)?.toInt() ??
        (data[legacyKey] as num?)?.toInt() ??
        0;
  }

  static String _readString(
    Map<String, dynamic> data,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final raw = data[key];
      if (raw == null) continue;
      final value = raw.toString().trim();
      if (value.isNotEmpty) return value;
    }
    return fallback.trim();
  }

  static String _normalizeUsername(String raw,
      {required String fallbackUserId}) {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      return trimmed.startsWith('@') ? trimmed : '@$trimmed';
    }
    if (fallbackUserId.isEmpty) {
      return '';
    }
    final shortUserId = fallbackUserId.substring(
      0,
      fallbackUserId.length > 6 ? 6 : fallbackUserId.length,
    );
    return '@$shortUserId';
  }

  static List<String> _readImageUrls(Map<String, dynamic> data) {
    final urls = <String>[];
    final seen = <String>{};

    void addUrl(String raw) {
      final url = raw.trim();
      if (url.isEmpty) return;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) return;
      if (!seen.add(url)) return;
      urls.add(url);
      if (urls.length >= 6) return;
    }

    final primary = _readString(
      data,
      const ['profilePictureUrl', 'profileImageUrl', 'avatarUrl'],
    );
    if (primary.isNotEmpty) {
      addUrl(primary);
    }

    for (final key in const ['profileImageUrls', 'images']) {
      final list = data[key];
      if (list is! List) continue;
      for (final item in list) {
        addUrl(item.toString());
        if (urls.length >= 6) {
          return urls;
        }
      }
    }

    return urls;
  }
}
