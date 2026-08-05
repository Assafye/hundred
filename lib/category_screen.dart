import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import 'app_categories.dart';
import 'post_detail_view.dart';
import 'post_media_utils.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

enum _CategorySortMode { newest, topScore }

enum _CategoryAudienceMode { everyone, friendsOnly }

class CategoryScreen extends StatefulWidget {
  final String categoryName;
  final Map<String, dynamic>? initialPost;

  const CategoryScreen({
    super.key,
    required this.categoryName,
    this.initialPost,
  });

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  static const String _allSubCategoriesLabel = 'כל תתי הקטגוריות';
  static const Color _bg = Color(0xFF0B1019);
  static const Color _panel = Color(0xFF131D2E);
  static const Color _cyan = Color(0xFF53C1F9);
  static const Color _purple = Color(0xFF9E7CFF);

  _CategorySortMode _sortMode = _CategorySortMode.newest;
  _CategoryAudienceMode _audienceMode = _CategoryAudienceMode.everyone;
  String _selectedSubCategory = _allSubCategoriesLabel;
  final Set<String> _friendIds = <String>{};
  bool _loadingRelations = true;

  @override
  void initState() {
    super.initState();
    _loadRelations();
  }

  Future<void> _loadRelations() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loadingRelations = false;
      });
      return;
    }

    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data() ?? <String, dynamic>{};
      final friendsRaw =
          (data['friends'] as List<dynamic>?) ?? const <dynamic>[];
      final followingRaw =
          (data['following'] as List<dynamic>?) ?? const <dynamic>[];
      final followersRaw =
          (data['followers'] as List<dynamic>?) ?? const <dynamic>[];

      final parsedFriends = friendsRaw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final following = followingRaw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final followers = followersRaw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet();

      if (!mounted) return;
      setState(() {
        _friendIds
          ..clear()
          ..addAll(parsedFriends.isNotEmpty
              ? parsedFriends
              : following.intersection(followers));
        _loadingRelations = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingRelations = false;
      });
    }
  }

  int _postScore(Map<String, dynamic> post) {
    int intFrom(List<String> keys, {int fallback = 0}) {
      for (final key in keys) {
        final raw = post[key];
        if (raw is num) return raw.toInt();
        if (raw is String) {
          final parsed = int.tryParse(raw.trim());
          if (parsed != null) return parsed;
        }
      }
      return fallback;
    }

    final scoreAwarded = intFrom(const ['scoreAwarded']);
    final likesCount = intFrom(
      const ['likesCount', 'likes_count'],
      fallback: ((post['likes'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final commentsCount = intFrom(
      const ['commentsCount', 'comments_count'],
      fallback:
          ((post['comments'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final sharesCount = intFrom(const ['sharesCount', 'shares_count']);
    final savesCount = intFrom(
      const ['savesCount', 'saves_count'],
      fallback:
          ((post['savedBy'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    return scoreAwarded +
        likesCount +
        (commentsCount * 2) +
        (sharesCount * 3) +
        savesCount;
  }

  DateTime _createdAt(Map<String, dynamic> post) {
    DateTime? parseAny(dynamic raw) {
      if (raw is Timestamp) return raw.toDate();
      if (raw is DateTime) return raw;
      if (raw is String) {
        return DateTime.tryParse(raw);
      }
      return null;
    }

    for (final key in const ['createdAt', 'timestamp', 'publishedAt']) {
      final parsed = parseAny(post[key]);
      if (parsed != null) {
        return parsed;
      }
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _authorId(Map<String, dynamic> post) {
    return (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim();
  }

  String _rawMediaField(Map<String, dynamic> data) {
    bool isLikelyImageUrl(String value) {
      final normalized = value.toLowerCase().split('?').first;
      return normalized.endsWith('.jpg') ||
          normalized.endsWith('.jpeg') ||
          normalized.endsWith('.png') ||
          normalized.endsWith('.webp') ||
          normalized.endsWith('.gif');
    }

    final thumbnailUrl = (data['thumbnailUrl'] as String? ?? '').trim();
    if (thumbnailUrl.isNotEmpty) return thumbnailUrl;

    final mediaThumbnailUrl =
      (data['videoThumbnailUrl'] as String? ?? '').trim();
    if (mediaThumbnailUrl.isNotEmpty) return mediaThumbnailUrl;

    final mediaUrl = (data['mediaUrl'] as String? ?? '').trim();
    if (mediaUrl.isNotEmpty) return mediaUrl;

    final imageUrl = (data['imageUrl'] as String? ?? '').trim();
    if (imageUrl.isNotEmpty) return imageUrl;

    final mediaUrls =
        (data['mediaUrls'] as List<dynamic>?) ?? const <dynamic>[];
    if (mediaUrls.isNotEmpty) {
      final normalized = mediaUrls
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (normalized.isNotEmpty) {
        return normalized.firstWhere(
          isLikelyImageUrl,
          orElse: () => normalized.first,
        );
      }
    }

    return '';
  }

  Future<String?> _resolveMediaUrl(Map<String, dynamic> data) async {
    final rawMedia = _rawMediaField(data);
    final storagePath = (data['storagePath'] as String? ?? '').trim();

    if (rawMedia.isNotEmpty) {
      if (rawMedia.startsWith('http://') || rawMedia.startsWith('https://')) {
        return rawMedia;
      }
      try {
        if (rawMedia.startsWith('gs://')) {
          return await FirebaseStorage.instance
              .refFromURL(rawMedia)
              .getDownloadURL();
        }
        return await FirebaseStorage.instance.ref(rawMedia).getDownloadURL();
      } catch (_) {}
    }

    if (storagePath.isEmpty) return null;
    try {
      return await FirebaseStorage.instance.ref(storagePath).getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  Stream<List<Map<String, dynamic>>> _categoryPostsStream() {
    return FirebaseFirestore.instance
        .collection('posts')
        .where('status', isEqualTo: 'published')
        .where('category', isEqualTo: widget.categoryName)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) {
              final data = Map<String, dynamic>.from(doc.data());
              data['id'] = doc.id;
              data['postId'] = (data['postId'] as String? ?? doc.id).trim();
              return data;
            }).toList(growable: false));
  }

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> posts) {
    var filtered = posts.where((post) {
      if (_selectedSubCategory != _allSubCategoriesLabel) {
        final sub = (post['subCategory'] as String? ?? '').trim();
        if (sub != _selectedSubCategory) return false;
      }
      if (_audienceMode == _CategoryAudienceMode.friendsOnly) {
        final authorId = _authorId(post);
        if (authorId.isEmpty || !_friendIds.contains(authorId)) return false;
      }
      return true;
    }).toList(growable: true);

    filtered.sort((a, b) {
      if (_sortMode == _CategorySortMode.topScore) {
        final scoreCmp = _postScore(b).compareTo(_postScore(a));
        if (scoreCmp != 0) return scoreCmp;
      }
      return _createdAt(b).compareTo(_createdAt(a));
    });

    return filtered;
  }

  Widget _buildFilterDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isLight ? Colors.white.withOpacity( 0.8) : _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLight ? const Color(0xFFA9C3FF) : _cyan.withOpacity( 0.22),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: isLight ? Colors.white : const Color(0xFF162233),
          borderRadius: BorderRadius.circular(14),
          iconEnabledColor: isLight ? Colors.black54 : _cyan,
          style: TextStyle(
            color: isLight ? Colors.black : Colors.white,
            fontSize: 12,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildPostTile(Map<String, dynamic> post,
      List<Map<String, dynamic>> orderedPosts, int index) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final title = (post['title'] as String? ?? '').trim();
    final score = _postScore(post);
    final isFriend = _friendIds.contains(_authorId(post));
    final mediaProbe = _rawMediaField(post);
    final isVideo = isVideoMediaUrl(mediaProbe);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PostDetailView(
              posts: orderedPosts,
              initialIndex: index,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isLight ? Colors.white.withOpacity( 0.76) : null,
          gradient: isLight
              ? null
              : const LinearGradient(
                  colors: [Color(0xFF152337), Color(0xFF241C44)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          border: Border.all(
            color: isLight ? const Color(0xFFA9C3FF) : _cyan.withOpacity( 0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: _cyan.withOpacity( 0.07),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned.fill(
                child: FutureBuilder<String?>(
                  future: _resolveMediaUrl(post),
                  builder: (context, snapshot) {
                    final url = (snapshot.data ?? '').trim();
                    if (url.isEmpty) {
                      return Container(
                        color: isLight
                            ? const Color(0xFFEFF5FF)
                            : const Color(0xFF1A2230),
                        child: Center(
                          child: Icon(Icons.image_not_supported_rounded,
                              color: isLight ? Colors.black26 : Colors.white30,
                              size: 28),
                        ),
                      );
                    }
                    return CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: isLight
                            ? const Color(0xFFEFF5FF)
                            : const Color(0xFF1A2230),
                        child: isVideo
                            ? FutureBuilder<Uint8List?>(
                                future: buildVideoPreviewBytesFromSource(url),
                                builder: (context, bytesSnapshot) {
                                  final bytes = bytesSnapshot.data;
                                  if (bytes == null || bytes.isEmpty) {
                                    return Center(
                                      child: Icon(
                                          Icons.play_circle_fill_rounded,
                                          color: isLight
                                              ? Colors.black26
                                              : Colors.white54,
                                          size: 30),
                                    );
                                  }
                                  return Image.memory(bytes, fit: BoxFit.cover);
                                },
                              )
                            : Center(
                                child: Icon(Icons.broken_image_outlined,
                                    color: isLight
                                        ? Colors.black26
                                        : Colors.white30,
                                    size: 28),
                              ),
                      ),
                    );
                  },
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity( 0.1),
                        Colors.transparent,
                        Colors.black.withOpacity( 0.58),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    color: isLight
                        ? const Color(0xFF4A5E92).withOpacity( 0.78)
                        : const Color(0xFF101A2C).withOpacity( 0.88),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isLight
                          ? Colors.white.withOpacity( 0.72)
                          : _cyan.withOpacity( 0.24),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.stars_rounded,
                        color: isLight ? Colors.white : const Color(0xFF9EDBFF),
                        size: 11,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$score',
                        style: TextStyle(
                          color:
                              isLight ? Colors.white : const Color(0xFF9EDBFF),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isFriend)
                Positioned(
                  top: 34,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: isLight
                          ? const Color(0xFF6C5CB4).withOpacity( 0.78)
                          : const Color(0xFF201B38).withOpacity( 0.9),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isLight
                            ? Colors.white.withOpacity( 0.72)
                            : _purple.withOpacity( 0.28),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.people_alt_rounded,
                          color:
                              isLight ? Colors.white : const Color(0xFFEBDFFF),
                          size: 11,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'חבר',
                          style: TextStyle(
                            color: isLight
                                ? Colors.white
                                : const Color(0xFFEBDFFF),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  title.isNotEmpty ? title : 'פוסט',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final subCategoryOptions = <String>[
      _allSubCategoriesLabel,
      ...appSubCategories(widget.categoryName)
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    ];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
        backgroundColor: isLight ? Colors.white : _bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 42,
          centerTitle: false,
          leading: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ).createShader(bounds),
              child: const Icon(
                Icons.arrow_back_rounded,
                size: 30,
                color: Colors.white,
              ),
            ),
          ),
          title: null,
        ),
        body: Stack(
          children: [
            Builder(
              builder: (context) {
                final screenWidth = MediaQuery.of(context).size.width;
                final orbSizeA = (screenWidth * 0.62).clamp(180.0, 220.0);
                final orbSizeB = (screenWidth * 0.72).clamp(200.0, 260.0);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: isLight
                              ? const LinearGradient(
                                  colors: [
                                    Colors.white,
                                    Color(0xFFF8FBFF),
                                    Colors.white
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                )
                              : const LinearGradient(
                                  colors: [
                                    Color(0xFF0B1019),
                                    Color(0xFF131B33),
                                    Color(0xFF0E1422)
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: -70,
                      right: -50,
                      child: Container(
                        width: orbSizeA,
                        height: orbSizeA,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _cyan.withOpacity( 0.07),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -100,
                      left: -60,
                      child: Container(
                        width: orbSizeB,
                        height: orbSizeB,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _purple.withOpacity( 0.08),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          widget.categoryName,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildFilterDropdown<_CategorySortMode>(
                                value: _sortMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: _CategorySortMode.newest,
                                    child: Text('החדש ביותר'),
                                  ),
                                  DropdownMenuItem(
                                    value: _CategorySortMode.topScore,
                                    child: Text('הניקוד הגבוה ביותר'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _sortMode = value);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child:
                                  _buildFilterDropdown<_CategoryAudienceMode>(
                                value: _audienceMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: _CategoryAudienceMode.everyone,
                                    child: Text('פוסטים של כולם'),
                                  ),
                                  DropdownMenuItem(
                                    value: _CategoryAudienceMode.friendsOnly,
                                    child: Text('רק של חברים'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _audienceMode = value);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildFilterDropdown<String>(
                                value: _selectedSubCategory,
                                items: subCategoryOptions
                                    .map((item) => DropdownMenuItem<String>(
                                          value: item,
                                          child: Text(item),
                                        ))
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _selectedSubCategory = value);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: StreamBuilder<List<Map<String, dynamic>>>(
                      stream: _categoryPostsStream(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                                ConnectionState.waiting ||
                            _loadingRelations) {
                          return const Center(
                            child: CircularProgressIndicator(color: _purple),
                          );
                        }

                        final orderedPosts = _applyFilters(
                            snapshot.data ?? const <Map<String, dynamic>>[]);
                        if (orderedPosts.isEmpty) {
                          return Center(
                            child: Text(
                              'אין פוסטים להצגה במסננים שנבחרו',
                              style: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white70,
                                  fontSize: 14),
                            ),
                          );
                        }

                        return Directionality(
                          textDirection: TextDirection.rtl,
                          child: GridView.builder(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                            physics: const BouncingScrollPhysics(),
                            itemCount: orderedPosts.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: 0.72,
                            ),
                            itemBuilder: (context, index) {
                              return _buildPostTile(
                                  orderedPosts[index], orderedPosts, index);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
