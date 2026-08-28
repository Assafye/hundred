import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReportReasonOption {
  final String key;
  final String label;

  const ReportReasonOption({required this.key, required this.label});
}

class ReportService {
  ReportService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  static const List<ReportReasonOption> commonReasons =
      <ReportReasonOption>[
    ReportReasonOption(key: 'harassment', label: 'הטרדה או בריונות'),
    ReportReasonOption(key: 'hate_or_abuse', label: 'שיח פוגעני או שיח שנאה'),
    ReportReasonOption(key: 'violence', label: 'אלימות או איום'),
    ReportReasonOption(key: 'sexual_content', label: 'תוכן מיני לא הולם'),
    ReportReasonOption(key: 'spam', label: 'ספאם או הטעיה'),
    ReportReasonOption(key: 'impersonation', label: 'התחזות'),
    ReportReasonOption(key: 'privacy', label: 'פגיעה בפרטיות'),
    ReportReasonOption(key: 'other', label: 'אחר'),
  ];

  String _requireCurrentUid() {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'יש להתחבר כדי לדווח.',
      );
    }
    return uid;
  }

  Future<void> submitUserReport({
    required String targetUserUid,
    required ReportReasonOption reason,
    required String details,
  }) async {
    final reporterUid = _requireCurrentUid();
    final normalizedTargetUserUid = targetUserUid.trim();
    final normalizedDetails = details.trim();
    if (normalizedTargetUserUid.isEmpty || normalizedDetails.isEmpty) {
      throw ArgumentError('Missing required report fields.');
    }

    await _db.collection('reports').add(<String, dynamic>{
      'reporterUid': reporterUid,
      'targetType': 'user',
      'targetUserUid': normalizedTargetUserUid,
      'targetPostId': '',
      'targetCommentId': '',
      'reasonKey': reason.key,
      'reasonLabel': reason.label,
      'details': normalizedDetails,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> submitPostReport({
    required String targetPostId,
    required String targetUserUid,
    required ReportReasonOption reason,
    required String details,
  }) async {
    final reporterUid = _requireCurrentUid();
    final normalizedPostId = targetPostId.trim();
    final normalizedTargetUserUid = targetUserUid.trim();
    final normalizedDetails = details.trim();
    if (normalizedPostId.isEmpty ||
        normalizedTargetUserUid.isEmpty ||
        normalizedDetails.isEmpty) {
      throw ArgumentError('Missing required report fields.');
    }

    await _db.collection('reports').add(<String, dynamic>{
      'reporterUid': reporterUid,
      'targetType': 'post',
      'targetUserUid': normalizedTargetUserUid,
      'targetPostId': normalizedPostId,
      'targetCommentId': '',
      'reasonKey': reason.key,
      'reasonLabel': reason.label,
      'details': normalizedDetails,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<Set<String>> streamReportedMeetNowPostIds() {
    final reporterUid = _auth.currentUser?.uid.trim() ?? '';
    if (reporterUid.isEmpty) {
      return Stream<Set<String>>.value(const <String>{});
    }

    return _db
        .collection('users')
        .doc(reporterUid)
        .collection('hidden_meet_now_posts')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) => document.id.trim())
              .where((postId) => postId.isNotEmpty)
              .toSet(),
        );
  }

  Future<void> submitMeetNowPostReport({
    required String targetPostId,
    required String targetUserUid,
    required ReportReasonOption reason,
    required String details,
  }) async {
    final reporterUid = _requireCurrentUid();
    final normalizedPostId = targetPostId.trim();
    final normalizedTargetUserUid = targetUserUid.trim();
    final normalizedDetails = details.trim();
    if (normalizedPostId.isEmpty ||
        normalizedTargetUserUid.isEmpty ||
        normalizedDetails.isEmpty) {
      throw ArgumentError('Missing required report fields.');
    }

    final batch = _db.batch();
    batch.set(
      _db.collection('reports').doc(),
      <String, dynamic>{
        'reporterUid': reporterUid,
        'targetType': 'meet_now_post',
        'targetUserUid': normalizedTargetUserUid,
        'targetPostId': normalizedPostId,
        'targetCommentId': '',
        'reasonKey': reason.key,
        'reasonLabel': reason.label,
        'details': normalizedDetails,
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
    );
    batch.set(
      _db
          .collection('users')
          .doc(reporterUid)
          .collection('hidden_meet_now_posts')
          .doc(normalizedPostId),
      <String, dynamic>{
        'postId': normalizedPostId,
        'reportedAt': FieldValue.serverTimestamp(),
      },
    );
    await batch.commit();
  }

  Future<void> submitCommentReport({
    required String targetPostId,
    required String targetCommentId,
    required String targetUserUid,
    required ReportReasonOption reason,
    required String details,
  }) async {
    final reporterUid = _requireCurrentUid();
    final normalizedPostId = targetPostId.trim();
    final normalizedCommentId = targetCommentId.trim();
    final normalizedTargetUserUid = targetUserUid.trim();
    final normalizedDetails = details.trim();
    if (normalizedPostId.isEmpty ||
        normalizedCommentId.isEmpty ||
        normalizedTargetUserUid.isEmpty ||
        normalizedDetails.isEmpty) {
      throw ArgumentError('Missing required report fields.');
    }

    await _db.collection('reports').add(<String, dynamic>{
      'reporterUid': reporterUid,
      'targetType': 'comment',
      'targetUserUid': normalizedTargetUserUid,
      'targetPostId': normalizedPostId,
      'targetCommentId': normalizedCommentId,
      'reasonKey': reason.key,
      'reasonLabel': reason.label,
      'details': normalizedDetails,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
