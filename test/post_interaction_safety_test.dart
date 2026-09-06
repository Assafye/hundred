import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/post_interaction_overlay_service.dart';
import 'package:hundred_version1/services/public_user_profile_service.dart';

void main() {
  test('shouldAllowAction blocks a repeat call within the cooldown window',
      () {
    const postId = 'post-debounce-1';
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'like',
        cooldown: const Duration(milliseconds: 200),
      ),
      isTrue,
    );
    // A near-simultaneous second invocation (e.g. an overlapping
    // double-tap-to-like gesture firing alongside a direct tap on the like
    // button) must be rejected instead of triggering a second toggle.
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'like',
        cooldown: const Duration(milliseconds: 200),
      ),
      isFalse,
    );
  });

  test('shouldAllowAction allows the action again after the cooldown elapses',
      () async {
    const postId = 'post-debounce-2';
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'like',
        cooldown: const Duration(milliseconds: 30),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'like',
        cooldown: const Duration(milliseconds: 30),
      ),
      isTrue,
    );
  });

  test('shouldAllowAction tracks distinct actions independently', () {
    const postId = 'post-debounce-3';
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'like',
      ),
      isTrue,
    );
    // A different action on the same post (e.g. save) is not affected by
    // the like cooldown.
    expect(
      PostInteractionOverlayService.shouldAllowAction(
        postId: postId,
        action: 'save',
      ),
      isTrue,
    );
  });

  test('scoreDeltaChanges emits the uid whenever its optimistic delta changes',
      () async {
    const uid = 'user-score-delta-stream';
    final events = <String>[];
    final subscription =
        PublicUserProfileService.scoreDeltaChanges.listen(events.add);

    PublicUserProfileService.addOptimisticScoreDelta(uid: uid, delta: 2);
    PublicUserProfileService.addOptimisticScoreDelta(uid: uid, delta: -2);
    await Future<void>.delayed(Duration.zero);

    await subscription.cancel();
    expect(events.where((event) => event == uid).length, 2);
  });

  test(
      'reconcileAndGetDelta stops double-counting once the real value '
      'catches up to a pending optimistic delta', () {
    const postId = 'post-reconcile-1';
    // A like was applied optimistically (e.g. the direct write was denied
    // by strict Firestore rules and fell back to the secure-actions queue).
    PostInteractionOverlayService.addDelta(postId: postId, likes: 1);
    expect(
      PostInteractionOverlayService.reconcileAndGetDelta(
        postId: postId,
        metric: 'likes',
        rawValue: 0,
      ),
      1,
    );
    // The queued action has now landed for real: Firestore's own likesCount
    // reflects the like. The pending delta must be dropped instead of
    // adding +1 on top of the already-updated real value.
    expect(
      PostInteractionOverlayService.reconcileAndGetDelta(
        postId: postId,
        metric: 'likes',
        rawValue: 1,
      ),
      0,
    );
  });

  test('reconcileAndGetDelta only clears the metric whose raw value changed',
      () {
    const postId = 'post-reconcile-2';
    PostInteractionOverlayService.addDelta(
      postId: postId,
      likes: 1,
      comments: 1,
    );
    // Only the real likesCount changes; the comment delta is still pending.
    expect(
      PostInteractionOverlayService.reconcileAndGetDelta(
        postId: postId,
        metric: 'likes',
        rawValue: 0,
      ),
      1,
    );
    PostInteractionOverlayService.reconcileAndGetDelta(
      postId: postId,
      metric: 'likes',
      rawValue: 1,
    );
    expect(
      PostInteractionOverlayService.reconcileAndGetDelta(
        postId: postId,
        metric: 'comments',
        rawValue: 0,
      ),
      1,
    );
  });
}
