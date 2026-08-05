import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'services/notification_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  final NotificationService _notificationService = NotificationService();

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _setAll(bool value) async {
    final payload = <String, bool>{
      for (final key in NotificationService.defaultSettings.keys) key: value,
    };
    await _notificationService.updateCurrentUserSettings(payload);
  }

  Future<void> _toggle(String key, bool value) async {
    await _notificationService.updateCurrentUserSettings(<String, bool>{
      key: value,
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final scaffoldBg =
        isLight ? const Color(0xFFF5F8FF) : const Color(0xFF0B1019);
    final appBarBg = isLight ? Colors.white : const Color(0xFF131E31);
    final titleColor = isLight ? const Color(0xFF101826) : Colors.white;
    final mutedText = isLight ? const Color(0xFF5B6D85) : Colors.white70;
    final quickCardGradient = isLight
        ? const [Color(0xFFEAF2FF), Color(0xFFF8EEFF)]
        : const [Color(0xFF16243B), Color(0xFF221D41)];
    final optionCard = isLight ? Colors.white : const Color(0xFF1A2435);
    final optionBorder = isLight
        ? const Color(0xFFA9C3FF)
        : const Color(0xFF53C1F9).withOpacity( 0.13);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: scaffoldBg,
          appBar: AppBar(
            backgroundColor: appBarBg,
            elevation: 0,
            title: Text(
              'הגדרות התראות',
              style: TextStyle(color: titleColor, fontWeight: FontWeight.w800),
            ),
          ),
          body: uid == null || uid.isEmpty
              ? Center(
                  child: Text(
                    'נדרש משתמש מחובר כדי לערוך התראות',
                    style: TextStyle(color: mutedText),
                  ),
                )
              : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(uid)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final data = snapshot.data?.data() ?? <String, dynamic>{};
                    final rawSettings = (data['notificationSettings']
                            as Map<String, dynamic>?) ??
                        const <String, dynamic>{};

                    final settings = <String, bool>{
                      ...NotificationService.defaultSettings,
                    };
                    for (final entry in rawSettings.entries) {
                      if (entry.value is bool) {
                        settings[entry.key] = entry.value as bool;
                      }
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: LinearGradient(
                              colors: quickCardGradient,
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                            ),
                            border: Border.all(
                              color: isLight
                                  ? const Color(0xFFA9C3FF)
                                  : const Color(0xFF53C1F9)
                                      .withOpacity( 0.2),
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                'שליטה מהירה',
                                style: TextStyle(
                                  color: titleColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _setAll(true),
                                      child: const Text('הפעל הכל'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _setAll(false),
                                      child: const Text('כבה הכל'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ..._notificationOptions.map((option) {
                          final value = settings[option.key] ?? true;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: optionCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: optionBorder,
                              ),
                            ),
                            child: SwitchListTile.adaptive(
                              value: value,
                              onChanged: (next) => _toggle(option.key, next),
                              activeColor: const Color(0xFF53C1F9),
                              title: Text(
                                option.title,
                                style: TextStyle(
                                  color: titleColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                option.subtitle,
                                style: TextStyle(color: mutedText),
                              ),
                            ),
                          );
                        }),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _NotificationOption {
  final String key;
  final String title;
  final String subtitle;

  const _NotificationOption({
    required this.key,
    required this.title,
    required this.subtitle,
  });
}

const List<_NotificationOption> _notificationOptions = <_NotificationOption>[
  _NotificationOption(
    key: NotificationSettingKeys.postLikes,
    title: 'לייקים לפוסטים שלי',
    subtitle: 'כשמישהו עושה לייק לפוסט שלך',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.newMessages,
    title: 'הודעות חדשות',
    subtitle: 'הודעות מקבוצות או צאטים אישיים',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.postComments,
    title: 'תגובות על הפוסט שלי',
    subtitle: 'כשמגיבים לפוסט שלך',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.commentReplies,
    title: 'תגובות לתגובה שלי',
    subtitle: 'כשמגיבים לתגובה שכתבת',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.popJoins,
    title: 'הצטרפות לפופ שיצרתי',
    subtitle: 'כשמשתמש מצטרף לפופ שלך',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.groupJoins,
    title: 'הצטרפות לקבוצה שלי',
    subtitle: 'כשמשתמש מצטרף לקבוצה שיצרת',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.addedToGroups,
    title: 'הוספה לקבוצה חדשה',
    subtitle: 'כשמוסיפים אותך לקבוצה',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.weeklyChallengeUpdates,
    title: 'עדכון אתגר שבועי',
    subtitle: 'התראה כשהאתגר השבועי משתנה',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.discoveryReminders,
    title: 'תזכורת פעם ביומיים',
    subtitle: 'בא לך לעשות משהו? היכנס לחפש סביבך',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.weeklyStars,
    title: 'כוכבי השבוע',
    subtitle: 'כשפוסט שלך נכנס לכוכבי השבוע',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.newFollowers,
    title: 'עוקבים חדשים',
    subtitle: 'כשמשתמש מתחיל לעקוב אחריך',
  ),
  _NotificationOption(
    key: NotificationSettingKeys.newFriends,
    title: 'חברים חדשים',
    subtitle: 'כשמשתמש הופך לחבר שלך',
  ),
];
