import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/chats_screen.dart';
import 'package:hundred_version1/feed_screen.dart';
import 'package:hundred_version1/post_model.dart';
import 'package:hundred_version1/services/app_home_service.dart';
import 'package:hundred_version1/services/block_user_service.dart';
import 'package:hundred_version1/stars_screen.dart';

void main() {
  test('filters out stale and already-seen feed posts only', () {
    final now = DateTime(2026, 8, 24, 12, 0, 0);

    final oldPost = PostModel(
      id: 'old-post',
      category: 'general',
      createdAt: now.subtract(const Duration(days: 45)),
      colors: const [Color(0xFF8C62FF), Color(0xFF46D3FF)],
    );

    final seenPost = PostModel(
      id: 'seen-post',
      category: 'general',
      createdAt: now.subtract(const Duration(days: 3)),
      colors: const [Color(0xFF8C62FF), Color(0xFF46D3FF)],
    );

    final freshPost = PostModel(
      id: 'fresh-post',
      category: 'general',
      createdAt: now.subtract(const Duration(days: 1)),
      colors: const [Color(0xFF8C62FF), Color(0xFF46D3FF)],
    );

    final filtered = filterFeedPostsForFreshnessAndSeen(
      [oldPost, seenPost, freshPost],
      seenPostIds: const {'seen-post'},
      now: now,
    );

    expect(filtered.map((post) => post.id), ['fresh-post']);
  });

  test('drops expired public groups from chats display', () {
    final now = DateTime(2026, 8, 24, 12, 0, 0);

    final active = {
      'date': Timestamp.fromDate(now.add(const Duration(hours: 2))),
    };
    final expired = {
      'date': Timestamp.fromDate(now.subtract(const Duration(hours: 1))),
    };

    expect(isPublicGroupStillActive(active, now: now), isTrue);
    expect(isPublicGroupStillActive(expired, now: now), isFalse);
  });

  test('upcoming public groups exclude same-day events that already started', () {
    final now = DateTime(2026, 8, 24, 18, 0, 0);
    final start = DateTime(2026, 8, 24, 0, 0, 0);
    final endExclusive = start.add(const Duration(days: 7));

    expect(
      isUpcomingPublicGroupDateWithinWindow(
        groupDate: DateTime(2026, 8, 24, 17, 30, 0),
        now: now,
        windowStart: start,
        windowEndExclusive: endExclusive,
      ),
      isFalse,
    );

    expect(
      isUpcomingPublicGroupDateWithinWindow(
        groupDate: DateTime(2026, 8, 24, 19, 0, 0),
        now: now,
        windowStart: start,
        windowEndExclusive: endExclusive,
      ),
      isTrue,
    );
  });

  test('meet-now groups default to a 24h execution window', () {
    final now = DateTime(2026, 8, 24, 12, 0, 0);

    expect(
      defaultPublicGroupExecutionDate(now: now),
      now.add(const Duration(hours: 24)),
    );
  });

  test('search text matches user and group names across real field aliases', () {
    final userData = {
      'displayName': 'דיכבר',
      'username': '@dichbar',
      'firstName': 'דיכבר',
    };
    final groupData = {
      'groupName': 'שלום לכם',
      'name': 'שלום לכם',
      'description': 'פגישה חברתית',
    };

    expect(
      buildGlobalSearchText(userData, isGroup: false),
      contains('דיכבר'),
    );
    expect(
      buildGlobalSearchText(groupData, isGroup: true),
      contains('שלום לכם'),
    );
  });

  test('stars viewer filters out posts from blocked users', () {
    final posts = [
      {'authorId': 'u1', 'id': 'keep', 'audience': 'public'},
      {'authorId': 'u2', 'id': 'blocked', 'audience': 'public'},
      {'authorId': 'u3', 'id': 'self', 'audience': 'public'},
    ];

    final filtered = filterBlockedUserPostsForViewer(
      posts,
      blockedUserIds: {'u2'},
      currentUserId: 'u3',
    );

    expect(filtered.map((post) => post['id']), ['keep', 'self']);
  });

  test('meet-now viewer filters out posts from blocked users', () {
    final entries = [
      MeetNowPostEntry(
        id: 'keep',
        authorUid: 'u1',
        authorName: 'Alice',
        authorHandle: '@alice',
        authorAvatarUrl: '',
        authorProfileImageUrls: const [],
        authorScore: 0,
        authorLocation: '',
        authorGeo: null,
        title: 'Keep',
        details: '',
        category: 'general',
        subCategory: 'general',
        meetingLocation: '',
        meetingGeo: null,
        desiredParticipants: null,
        timePreference: '',
        minAge: null,
        maxAge: null,
        createdAt: DateTime.now(),
        linkedGroupId: '',
        linkedGroupMembersCount: 0,
        linkedGroupIsPublic: true,
        participantProfileImageUrls: const [],
        distanceMetersFromCurrentUser: null,
      ),
      MeetNowPostEntry(
        id: 'blocked',
        authorUid: 'u2',
        authorName: 'Bob',
        authorHandle: '@bob',
        authorAvatarUrl: '',
        authorProfileImageUrls: const [],
        authorScore: 0,
        authorLocation: '',
        authorGeo: null,
        title: 'Blocked',
        details: '',
        category: 'general',
        subCategory: 'general',
        meetingLocation: '',
        meetingGeo: null,
        desiredParticipants: null,
        timePreference: '',
        minAge: null,
        maxAge: null,
        createdAt: DateTime.now(),
        linkedGroupId: '',
        linkedGroupMembersCount: 0,
        linkedGroupIsPublic: true,
        participantProfileImageUrls: const [],
        distanceMetersFromCurrentUser: null,
      ),
    ];

    final filtered = filterBlockedMeetNowEntries(
      entries,
      blockedUserIds: {'u2'},
    );

    expect(filtered.map((entry) => entry.id), ['keep']);
  });

  test('merges direct and reverse block sources for the same user', () {
    final merged = BlockUserService.mergeBlockedUidSets(
      {'u2', 'u3'},
      {'u3', 'u4'},
    );

    expect(merged, {'u2', 'u3', 'u4'});
  });
}
