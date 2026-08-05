import 'package:flutter/material.dart';

import 'models/post.dart';
import 'widgets/swipe_back_wrapper.dart';

class PostDetailScreen extends StatelessWidget {
  final Post post;

  const PostDetailScreen({
    super.key,
    required this.post,
  });

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'לא ידוע';
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  String _formatRelativeTime(DateTime? dt) {
    if (dt == null) return 'לא ידוע';

    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'עכשיו';
    if (diff.inHours < 1) return 'לפני ${diff.inMinutes} דקות';
    if (diff.inDays < 1) return 'לפני ${diff.inHours} שעות';
    if (diff.inDays < 7) return 'לפני ${diff.inDays} ימים';
    return _formatDate(dt);
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SwipeBackWrapper(
      child: Scaffold(
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      appBar: AppBar(
        backgroundColor:
            isLight ? const Color(0xFFCFEFFF) : const Color(0xFF1E2632),
        elevation: 0,
        iconTheme: IconThemeData(color: isLight ? Colors.black : Colors.white),
        title: Text(
          'פוסט מלא',
          style: TextStyle(
            color: isLight ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Hero(
              tag: 'post_${post.postId}',
              child: AspectRatio(
                aspectRatio: 1,
                child: Image.network(
                  post.mediaUrl,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: isLight ? const Color(0xFFEFF5FF) : const Color(0xFF111927),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: isLight ? Colors.black45 : Colors.white54,
                        size: 34,
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isLight
                      ? Colors.white.withOpacity( 0.84)
                      : const Color(0xFF1E2632),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isLight ? const Color(0xFFA9C3FF) : Colors.white10,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.caption.isNotEmpty ? post.caption : 'ללא תיאור',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'קטגוריה: ${post.category.isNotEmpty ? post.category : 'לא ידוע'}',
                      style: TextStyle(
                        color: isLight ? Colors.black54 : Colors.grey[300],
                        fontSize: 13,
                      ),
                    ),
                    if (post.subCategory.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'תת-קטגוריה: ${post.subCategory}',
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.grey[300],
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'פורסם: ${_formatRelativeTime(post.createdAt)}',
                      style: TextStyle(
                        color: isLight ? Colors.black45 : Colors.grey[400],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
