import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'post_detail_view.dart';
import 'widgets/swipe_back_wrapper.dart';

class SavedPostsScreen extends StatefulWidget {
  const SavedPostsScreen({super.key});

  @override
  State<SavedPostsScreen> createState() => _SavedPostsScreenState();
}

class _SavedPostsScreenState extends State<SavedPostsScreen> {
  static const Color _lightBgTop = Color(0xFFF8FBFF);
  static const Color _lightBgBottom = Color(0xFFFFFFFF);
  static const Color _lightCard = Color(0xFFF3F7FF);
  static const Color _lightAppBar = Color(0xFFBFD9FF);
  static const Color _bgTop = Color(0xFF10162A);
  static const Color _bgBottom = Color(0xFF0B1019);
  static const Color _card = Color(0xFF162238);
  static const Color _accentCyan = Color(0xFF53C1F9);

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get _uid => FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _savedPostsStream() {
    if (_uid.isEmpty) {
      return const Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>.empty();
    }

    return _db
        .collection('users')
        .doc(_uid)
        .collection('saved_posts')
        .orderBy('savedAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.toList(growable: false));
  }

  Map<String, dynamic> _postMapFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> fallback,
  ) {
    final data = <String, dynamic>{...fallback, ...?doc.data()};
    data['id'] = doc.id;
    data['postId'] = (data['postId'] as String? ?? doc.id).trim();
    return data;
  }

  String _relativeTimeFrom(dynamic raw) {
    DateTime? createdAt;
    if (raw is Timestamp) {
      createdAt = raw.toDate();
    } else if (raw is DateTime) {
      createdAt = raw;
    }
    if (createdAt == null) {
      return '';
    }

    final difference = DateTime.now().difference(createdAt);
    if (difference.inMinutes < 1) return 'עכשיו';
    if (difference.inHours < 1) return 'לפני ${difference.inMinutes} דקות';
    if (difference.inDays < 1) return 'לפני ${difference.inHours} שעות';
    return 'לפני ${difference.inDays} ימים';
  }

  Future<List<Map<String, dynamic>>> _loadPostsForSaved(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> savedDocs,
  ) async {
    final posts = <Map<String, dynamic>>[];

    for (final savedDoc in savedDocs) {
      final data = savedDoc.data();
      final postId = (data['postId'] as String? ?? savedDoc.id).trim();
      if (postId.isEmpty) continue;

      final postDoc = await _db.collection('posts').doc(postId).get();
      if (postDoc.exists) {
        final postData = postDoc.data() ?? <String, dynamic>{};
        final isDeleted = (postData['isDeleted'] as bool?) ?? false;
        final status = (postData['status'] as String? ?? '').trim().toLowerCase();
        if (isDeleted || status == 'deleted') {
          continue;
        }
      } else {
        continue;
      }

      final fallback = <String, dynamic>{
        'id': postId,
        'postId': postId,
        'authorId': (data['authorId'] as String? ?? '').trim(),
        'title': (data['title'] as String? ?? 'פופ ללא כותרת').trim(),
        'description': (data['description'] as String? ?? '').trim(),
        'caption': (data['description'] as String? ?? '').trim(),
        'content': (data['description'] as String? ?? '').trim(),
        'imageUrl': (data['imageUrl'] as String? ?? '').trim(),
        'mediaUrl': (data['mediaUrl'] as String? ?? data['imageUrl'] as String? ?? '')
            .trim(),
        'createdAt': data['createdAt'],
      };
      posts.add(_postMapFromDoc(postDoc, fallback));
    }

    return posts;
  }

  Future<bool> _isVisibleSavedPost(
    QueryDocumentSnapshot<Map<String, dynamic>> savedDoc,
  ) async {
    final data = savedDoc.data();
    final postId = (data['postId'] as String? ?? savedDoc.id).trim();
    if (postId.isEmpty) {
      return false;
    }

    try {
      final postDoc = await _db.collection('posts').doc(postId).get();
      if (!postDoc.exists) {
        return false;
      }

      final postData = postDoc.data() ?? <String, dynamic>{};
      final isDeleted = (postData['isDeleted'] as bool?) ?? false;
      final status = (postData['status'] as String? ?? '').trim().toLowerCase();
      return !isDeleted && status != 'deleted';
    } catch (_) {
      // Keep saved posts visible if verification fails due to transient issues.
      return true;
    }
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _filterVisibleSavedDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> savedDocs,
  ) async {
    final visibility = await Future.wait(savedDocs.map(_isVisibleSavedPost));
    final visible = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (var index = 0; index < savedDocs.length; index++) {
      if (visibility[index]) {
        visible.add(savedDocs[index]);
      }
    }
    return visible;
  }

  Future<void> _openSavedPost(
    QueryDocumentSnapshot<Map<String, dynamic>> savedDoc,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allSavedDocs,
  ) async {
    final posts = await _loadPostsForSaved(allSavedDocs);
    if (!mounted || posts.isEmpty) return;

    final tappedIndex = allSavedDocs.indexWhere((doc) => doc.id == savedDoc.id);
    final initialIndex = tappedIndex >= 0 ? tappedIndex : 0;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: posts,
          initialIndex: initialIndex.clamp(0, posts.length - 1),
          enableEditAction: false,
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message, {required bool isLight}) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isLight ? _lightCard : _card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : _accentCyan.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isLight ? const Color(0xFF4D5B76) : Colors.white70,
            fontSize: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildSavedTile(
    QueryDocumentSnapshot<Map<String, dynamic>> savedDoc,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allSavedDocs,
    {required bool isLight}
  ) {
    final data = savedDoc.data();
    final title = (data['title'] as String? ?? 'פופ ללא כותרת').trim();
    final imageUrl =
        (data['imageUrl'] as String? ?? data['mediaUrl'] as String? ?? '').trim();
    final savedAt = _relativeTimeFrom(data['savedAt']);

    return InkWell(
      onTap: () => _openSavedPost(savedDoc, allSavedDocs),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: isLight ? Colors.white : const Color(0xFF1A2435),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : _accentCyan.withValues(alpha: 0.16),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl.isNotEmpty)
                Image.network(imageUrl, fit: BoxFit.cover)
              else
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isLight
                          ? const [Color(0xFFEAF1FF), Color(0xFFDCE8FF)]
                          : const [Color(0xFF24344E), Color(0xFF1A2340)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              Container(
                color: isLight
                    ? Colors.black.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.28),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLight ? const Color(0xFF1E2A45) : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (savedAt.isNotEmpty)
                      Text(
                        savedAt,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF4D5B76)
                              : const Color(0xFFEAF4FF),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
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

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
        backgroundColor: isLight ? _lightBgBottom : _bgBottom,
        appBar: AppBar(
          backgroundColor: isLight ? _lightAppBar : const Color(0xFF131E31),
          elevation: 0,
          centerTitle: true,
          title: Text(
            'שמורים',
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isLight
                  ? const [_lightBgTop, Color(0xFFF2F7FF), _lightBgBottom]
                  : const [_bgTop, Color(0xFF131B33), _bgBottom],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
            stream: _savedPostsStream(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'שגיאה בטעינת שמורים',
                    style: TextStyle(
                      color: isLight ? Colors.black54 : Colors.white70,
                    ),
                  ),
                );
              }

              final savedDocs =
                  snapshot.data ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
              return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                future: _filterVisibleSavedDocs(savedDocs),
                builder: (context, visibleSnapshot) {
                  if (visibleSnapshot.connectionState == ConnectionState.waiting &&
                      !visibleSnapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final visibleSavedDocs =
                      visibleSnapshot.data ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

                  if (visibleSavedDocs.isEmpty) {
                    return _buildEmptyState(
                      'אין פוסטים שמורים עדיין',
                      isLight: isLight,
                    );
                  }

                  return Padding(
                    padding: const EdgeInsets.all(14),
                    child: GridView.builder(
                      itemCount: visibleSavedDocs.length,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.78,
                      ),
                      itemBuilder: (context, index) {
                        return _buildSavedTile(
                          visibleSavedDocs[index],
                          visibleSavedDocs,
                          isLight: isLight,
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
      ),
    );
  }
}
