import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/chat_service.dart';

void main() {
  test('builds a normalized group join announcement', () {
    expect(
      ChatService.buildGroupJoinAnnouncementText('יואב'),
      'תגידו שלום ליואב',
    );
  });

  test('detects a group join announcement message', () {
    final message = <String, dynamic>{
      'messageType': 'system',
      'eventType': 'group_member_joined',
      'joinedDisplayName': 'יואב',
    };

    expect(ChatService.isGroupJoinAnnouncement(message), isTrue);
  });
}
