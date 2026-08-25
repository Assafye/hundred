import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/post_service.dart';
import 'package:hundred_version1/services/public_user_profile_service.dart';
import 'package:hundred_version1/services/social_service.dart';

void main() {
  test('follower score delta matches 50 points', () {
    expect(SocialService.followerScoreDelta(isAdding: true), 50);
    expect(SocialService.followerScoreDelta(isAdding: false), -50);
  });

  test('comment like and reply score deltas match the reward rules', () {
    expect(PostService.commentLikeScoreDelta(isAdding: true), 1);
    expect(PostService.commentLikeScoreDelta(isAdding: false), -1);
    expect(PostService.commentReplyScoreDelta(isAdding: true), 2);
    expect(PostService.commentReplyScoreDelta(isAdding: false), -2);
  });

  test('comment rewards update the optimistic profile score used by self and other viewers', () {
    PublicUserProfileService.addOptimisticScoreDelta(
      uid: 'user-1',
      delta: PostService.commentLikeScoreDelta(isAdding: true),
    );
    PublicUserProfileService.addOptimisticScoreDelta(
      uid: 'user-1',
      delta: PostService.commentReplyScoreDelta(isAdding: true),
    );

    expect(PublicUserProfileService.optimisticScoreDeltaFor('user-1'), 3);

    PublicUserProfileService.addOptimisticScoreDelta(
      uid: 'user-1',
      delta: -3,
    );
    expect(PublicUserProfileService.optimisticScoreDeltaFor('user-1'), 0);
  });
  test('follow reward uses the same optimistic score delta pattern used by other actions', () {
    PublicUserProfileService.addOptimisticScoreDelta(
      uid: 'user-2',
      delta: SocialService.followerScoreDelta(isAdding: true),
    );
    expect(PublicUserProfileService.optimisticScoreDeltaFor('user-2'), 50);

    PublicUserProfileService.addOptimisticScoreDelta(
      uid: 'user-2',
      delta: SocialService.followerScoreDelta(isAdding: false),
    );
    expect(PublicUserProfileService.optimisticScoreDeltaFor('user-2'), 0);
  });
  test('comment deletion reverses the rewarded value on that comment', () {
    expect(
      PostService.commentDeletionScoreDelta(
        likesCount: 3,
        replyCount: 2,
      ),
      -7,
    );
  });
}
