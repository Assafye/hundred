import 'package:flutter/material.dart';

import 'models/post_media_item.dart';

// 👤 מודל משתמש (עבור החברים המתוייגים)
class UserModel {
  final String id;
  final String username;
  final String profileImageUrl;

  UserModel({
    required this.id,
    required this.username,
    required this.profileImageUrl,
  });
}

// 📄 מודל הנתונים המאוחד של הפוסט
class PostModel {
  final String id;
  final String authorId;
  final DateTime? createdAt;
  final String category;
  final String status;
  final String subCategory;
  final String audience;
  final List<Color> colors;
  final bool isDraft;
  final String content;
  final String imageUrl;
  final List<String> mediaUrls;
  final List<PostMediaItem> mediaItems;
  final String eventGroupId;
  final String linkedGroupId;

  // שדות שנדרשים עבור מסך הבית:
  final String authorName;
  final String authorProfileImg;
  final String title;
  final String description;
  final String location;
  final int scoreAwarded;
  final List<String> participantUids;
  final int likesCount;
  final int commentsCount;
  final int sharesCount;
  final int savesCount;
  final bool likedByCurrentUser;
  final bool savedByCurrentUser;
  final List<UserModel> taggedFriends;
  final bool isFollowingFeed;
  final bool authorIsPrivate;

  PostModel({
    required this.id,
    this.authorId = '',
    this.createdAt,
    required this.category,
    this.status = 'published',
    this.subCategory = '',
    this.audience = 'public',
    required this.colors,
    this.isDraft = false,
    this.content = '',
    this.imageUrl = '',
    this.mediaUrls = const [],
    this.mediaItems = const [],
    this.eventGroupId = '',
    this.linkedGroupId = '',
    this.authorName = 'itay_pastel',
    this.authorProfileImg = 'https://placeholder.com/150',
    this.title = '',
    this.description = '',
    this.location = '',
    this.scoreAwarded = 0,
    this.participantUids = const [],
    this.likesCount = 0,
    this.commentsCount = 0,
    this.sharesCount = 0,
    this.savesCount = 0,
    this.likedByCurrentUser = false,
    this.savedByCurrentUser = false,
    this.taggedFriends = const [],
    this.isFollowingFeed = false,
    this.authorIsPrivate = false,
  });
}

// 🗄️ בסיס נתונים זמני (Mock DB) כדי שהאפליקציה לא תהיה ריקה
class MockPostDatabase {
  static List<PostModel> getMockPosts() {
    return [
      PostModel(
        id: '3',
        category: 'אקסטרים',
        subCategory: 'צניחה חופשית',
        audience: 'public',
        colors: [const Color(0xFFFF5722), const Color(0xFFFF9800)],
        content: 'צניחה חופשית מטורפת בחוף הבונים! 🪂',
        title: 'צניחה חופשית!',
        description: 'חוויה מטורפת של פעם בחיים.',
        isFollowingFeed: true,
      ),
      PostModel(
        id: '5',
        category: 'אוכל',
        subCategory: 'מסעדה',
        audience: 'public',
        colors: [const Color(0xFFFFD166), const Color(0xFFFFFCBB)],
        content: 'ההמבורגר הכי טוב שאכלתי בחיים השבוע 🍔',
        title: 'המבורגר מושחת',
        description: 'חובה לנסות, מקום מדהים.',
        isFollowingFeed: false,
      ),
      PostModel(
        id: '7',
        category: 'עבודה',
        subCategory: 'אחר',
        audience: 'public',
        colors: [const Color(0xFF2196F3), const Color(0xFF00BCD4)],
        content: 'סיימנו פרויקט ענק במשרד! קמפיין חדש באוויר 🚀',
        title: 'קמפיין חדש באוויר',
        description: 'עבודה קשה שמשתלמת.',
        isFollowingFeed: true,
      ),
    ];
  }
}
