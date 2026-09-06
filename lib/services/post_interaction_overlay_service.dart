import 'dart:async';

class PostInteractionOverlayService {
  PostInteractionOverlayService._();

  static final Map<String, Map<String, int>> _deltaByPostId =
      <String, Map<String, int>>{};
  static final Map<String, Map<String, bool>> _intentByPostId =
      <String, Map<String, bool>>{};
  static final Map<String, Map<String, int>> _lastRawValueByPostId =
      <String, Map<String, int>>{};
  static final Map<String, DateTime> _lastActionAtByKey = <String, DateTime>{};
  static final StreamController<String> _changesController =
      StreamController<String>.broadcast();

  static Stream<String> get changes => _changesController.stream;

  /// Guards against a single user gesture reaching the toggle handler twice
  /// (e.g. an overlapping double-tap-to-like recognizer firing alongside a
  /// direct tap on the like button). Returns true the first time an action
  /// is requested for a given post+action within [cooldown]; subsequent
  /// calls within the window return false so the caller can skip the repeat.
  static bool shouldAllowAction({
    required String postId,
    required String action,
    Duration cooldown = const Duration(milliseconds: 500),
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return true;

    final key = '$normalizedPostId::$action';
    final now = DateTime.now();
    final lastAt = _lastActionAtByKey[key];
    if (lastAt != null && now.difference(lastAt) < cooldown) {
      return false;
    }
    _lastActionAtByKey[key] = now;
    return true;
  }

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

  /// Reads the pending optimistic delta for [postId]/[metric], reconciling
  /// it first against the latest known real value ([rawValue]) from
  /// Firestore. If the real value has changed since the last time this was
  /// called for the same post+metric, the backend has already applied a
  /// real update (e.g. via the secure-actions worker), so the pending
  /// delta is stale and is cleared instead of being double-counted on top
  /// of the now-authoritative value. Without this, a like/comment/share/
  /// save whose direct write is rejected by Firestore rules and falls back
  /// to the secure-actions queue would show up twice once the queued write
  /// lands: once for real in [rawValue], and once more from the delta that
  /// was never cleared.
  static int reconcileAndGetDelta({
    required String postId,
    required String metric,
    required int rawValue,
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return 0;

    final lastRawByMetric =
        _lastRawValueByPostId.putIfAbsent(normalizedPostId, () => <String, int>{});
    final lastRaw = lastRawByMetric[metric];
    if (lastRaw != null && lastRaw != rawValue) {
      final deltas = _deltaByPostId[normalizedPostId];
      if (deltas != null && (deltas[metric] ?? 0) != 0) {
        deltas[metric] = 0;
        final allZero = (deltas['likes'] ?? 0) == 0 &&
            (deltas['comments'] ?? 0) == 0 &&
            (deltas['saves'] ?? 0) == 0 &&
            (deltas['shares'] ?? 0) == 0;
        if (allZero) {
          _deltaByPostId.remove(normalizedPostId);
        }
      }
    }
    lastRawByMetric[metric] = rawValue;

    return _deltaByPostId[normalizedPostId]?[metric] ?? 0;
  }

  static void setInteractionIntent({
    required String postId,
    bool? likedByMe,
    bool? savedByMe,
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return;

    final current = _intentByPostId.putIfAbsent(
      normalizedPostId,
      () => <String, bool>{},
    );

    var changed = false;
    if (likedByMe != null && current['likedByMe'] != likedByMe) {
      current['likedByMe'] = likedByMe;
      changed = true;
    }
    if (savedByMe != null && current['savedByMe'] != savedByMe) {
      current['savedByMe'] = savedByMe;
      changed = true;
    }

    if (!changed) return;
    _changesController.add(normalizedPostId);
  }

  static bool? interactionIntentFor({
    required String postId,
    required String intent,
  }) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return null;
    return _intentByPostId[normalizedPostId]?[intent];
  }

  /// Clears all locally cached optimistic state. This is a process-wide
  /// static cache with no notion of "which signed-in user" set it, so it
  /// MUST be wiped whenever the signed-in Firebase user changes (sign-out,
  /// switching accounts on the same device) — otherwise a like/save/comment
  /// intent recorded for one uid can leak and appear as already-applied for
  /// the next uid that opens the same post on the same device.
  static void resetAll() {
    _deltaByPostId.clear();
    _intentByPostId.clear();
    _lastRawValueByPostId.clear();
    _lastActionAtByKey.clear();
  }
}
