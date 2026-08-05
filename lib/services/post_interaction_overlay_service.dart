import 'dart:async';

class PostInteractionOverlayService {
  PostInteractionOverlayService._();

  static final Map<String, Map<String, int>> _deltaByPostId =
      <String, Map<String, int>>{};
  static final StreamController<String> _changesController =
      StreamController<String>.broadcast();

  static Stream<String> get changes => _changesController.stream;

  static void addDelta({
    required String postId,
    int likes = 0,
    int comments = 0,
    int saves = 0,
    int shares = 0,
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return;

    final incoming = <String, int>{
      'likes': likes,
      'comments': comments,
      'saves': saves,
      'shares': shares,
    };

    var changed = false;
    final current = _deltaByPostId.putIfAbsent(
      normalizedPostId,
      () => <String, int>{'likes': 0, 'comments': 0, 'saves': 0, 'shares': 0},
    );

    incoming.forEach((key, delta) {
      if (delta == 0) return;
      final next = (current[key] ?? 0) + delta;
      current[key] = next;
      changed = true;
    });

    if (!changed) return;

    final allZero = (current['likes'] ?? 0) == 0 &&
        (current['comments'] ?? 0) == 0 &&
        (current['saves'] ?? 0) == 0 &&
        (current['shares'] ?? 0) == 0;
    if (allZero) {
      _deltaByPostId.remove(normalizedPostId);
    }

    _changesController.add(normalizedPostId);
  }

  static int deltaFor({
    required String postId,
    required String metric,
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return 0;
    return _deltaByPostId[normalizedPostId]?[metric] ?? 0;
  }
}
