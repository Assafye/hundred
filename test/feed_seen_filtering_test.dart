import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/chats_screen.dart';
import 'package:hundred_version1/feed_screen.dart';
import 'package:hundred_version1/post_model.dart';
import 'package:hundred_version1/services/app_home_service.dart';

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
}
