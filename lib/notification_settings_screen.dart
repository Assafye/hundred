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
  final Map<String, bool> _localOverrides = <String, bool>{};
  final Set<String> _savingKeys = <String>{};
  bool _isBulkSaving = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _setAll(bool value) async {
    if (_isBulkSaving) return;
    final keys = NotificationService.defaultSettings.keys.toList(growable: false);
    setState(() {
      _isBulkSaving = true;
      for (final key in keys) {
        _localOverrides[key] = value;
        _savingKeys.add(key);
      }
    });

    final payload = <String, bool>{
      for (final key in NotificationService.defaultSettings.keys) key: value,
    };
    try {
      await _notificationService.updateCurrentUserSettings(payload);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('עדכון הגדרות התראות נכשל: $error')),
      );
      setState(() {
        for (final key in keys) {
          _localOverrides.remove(key);
        }
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isBulkSaving = false;
        _savingKeys.clear();
      });
    }
  }

  Future<void> _toggle(String key, bool value) async {
    if (_isBulkSaving || _savingKeys.contains(key)) return;
    final previous = _localOverrides[key];
    setState(() {
      _localOverrides[key] = value;
      _savingKeys.add(key);
    });

    try {
      await _notificationService.updateCurrentUserSettings(<String, bool>{
        key: value,
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (previous == null) {
          _localOverrides.remove(key);
        } else {
          _localOverrides[key] = previous;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('עדכון הגדרת התראה נכשל: $error')),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _savingKeys.remove(key);
      });
    }
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
        : const Color(0xFF53C1F9).withValues(alpha: 0.13);

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

                    for (final entry in _localOverrides.entries) {
                      settings[entry.key] = entry.value;
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
                                      .withValues(alpha: 0.2),
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
                                      onPressed:
                                          _isBulkSaving ? null : () => _setAll(true),
                                      child: const Text('הפעל הכל'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed:
                                          _isBulkSaving ? null : () => _setAll(false),
                                      child: const Text('כבה הכל'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...NotificationService.settingOptions.map((option) {
                          final value = settings[option.key] ?? true;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Material(
                              color: optionCard,
                              borderRadius: BorderRadius.circular(16),
                              clipBehavior: Clip.antiAlias,
                              child: Ink(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: optionBorder,
                                  ),
                                ),
                                child: SwitchListTile.adaptive(
                                  value: value,
                                  onChanged: _isBulkSaving ||
                                          _savingKeys.contains(option.key)
                                      ? null
                                      : (next) => _toggle(option.key, next),
                                  activeThumbColor: const Color(0xFF53C1F9),
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
