import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class MediaService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to upload media.',
      );
    }
    return uid;
  }

  Future<String> uploadMediaBytes(Uint8List bytes, {required String fileName}) async {
    final uid = _requireUid();
    final postId = _db.collection('posts').doc().id;
    final ext = _fileExtension(fileName);
    final ref = _storage.ref().child('posts/$uid/$postId.$ext');
    await ref.putData(bytes);
    return ref.getDownloadURL();
  }

  Future<String> createPostDocument({
    required List<String> mediaUrls,
    required String title,
    required String description,
    required String category,
    required String subCategory,
  }) async {
    final uid = _requireUid();
    if (category.trim().isEmpty) {
      throw ArgumentError('category must be selected before upload');
    }
    if (mediaUrls.isEmpty) {
      throw ArgumentError('mediaUrls cannot be empty');
    }
    final docRef = _db.collection('posts').doc();

    await docRef.set({
      'uid': uid,
      'authorId': uid,
      'mediaUrls': mediaUrls,
      'mediaUrl': mediaUrls.first,
      'title': title.trim(),
      'description': description.trim(),
      'caption': description.trim(),
      'category': category.trim(),
      'subCategory': subCategory.trim(),
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'published',
      'likes': <String>[],
    });

    return docRef.id;
  }

  Future<String> uploadPostAndCreateDocument({
    required List<Uint8List> mediaBytes,
    required List<String> fileNames,
    required String title,
    required String description,
    required String category,
    required String subCategory,
  }) async {
    if (mediaBytes.isEmpty) {
      throw ArgumentError('At least one media item is required');
    }
    if (mediaBytes.length != fileNames.length) {
      throw ArgumentError('mediaBytes and fileNames length mismatch');
    }

    final mediaUrls = <String>[];
    for (var i = 0; i < mediaBytes.length; i++) {
      final mediaUrl = await uploadMediaBytes(mediaBytes[i], fileName: fileNames[i]);
      mediaUrls.add(mediaUrl);
    }

    return createPostDocument(
      mediaUrls: mediaUrls,
      title: title,
      description: description,
      category: category,
      subCategory: subCategory,
    );
  }

  String _fileExtension(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == path.length - 1) {
      return 'jpg';
    }
    return path.substring(dotIndex + 1).toLowerCase();
  }
}
