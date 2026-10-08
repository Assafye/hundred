import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/post_media_item.dart';
import '../post_media_utils.dart';
import '../video_preview_utils.dart';

class VideoPosterService {
  VideoPosterService._();

  static final LinkedHashMap<String, Future<Uint8List?>> _previewCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  static Future<Uint8List?> previewForLegacyVideo({
    required PostMediaItem media,
    required String postId,
    required String postAuthorId,
  }) {
    final source = media.url.trim().isNotEmpty
        ? media.url.trim()
        : media.storagePath.trim();
    if (source.isEmpty) return Future<Uint8List?>.value();

    final cacheKey = '${postId.trim()}|$source';
    final cached = _previewCache.remove(cacheKey);
    if (cached != null) {
      _previewCache[cacheKey] = cached;
      return cached;
    }

    final future = _createPreview(
      source: source,
      media: media,
      postId: postId.trim(),
      postAuthorId: postAuthorId.trim(),
    );
    _previewCache[cacheKey] = future;
    while (_previewCache.length > 32) {
      _previewCache.remove(_previewCache.keys.first);
    }
    return future;
  }

  static Future<Uint8List?> _createPreview({
    required String source,
    required PostMediaItem media,
    required String postId,
    required String postAuthorId,
  }) async {
    final resolvedSource = await resolveVideoPreviewSource(source);
    if (resolvedSource == null) return null;

    Uint8List? bytes;
    try {
      bytes = await buildVideoPreviewBytesFromSource(resolvedSource);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }

    if (bytes == null || bytes.isEmpty) return null;
    unawaited(
      _persistForOwner(
        bytes: bytes,
        resolvedSource: resolvedSource,
        media: media,
        postId: postId,
        postAuthorId: postAuthorId,
      ),
    );
    return bytes;
  }

  static Future<void> _persistForOwner({
    required Uint8List bytes,
    required String resolvedSource,
    required PostMediaItem media,
    required String postId,
    required String postAuthorId,
  }) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isEmpty || currentUid != postAuthorId || postId.isEmpty) {
      return;
    }

    try {
      final videoRef = media.storagePath.trim().isNotEmpty
          ? FirebaseStorage.instance.ref(media.storagePath.trim())
          : FirebaseStorage.instance.refFromURL(resolvedSource);
      final videoPath = videoRef.fullPath;
      if (videoPath.isEmpty) return;

      final posterRef =
          FirebaseStorage.instance.ref('$videoPath.thumbnail.jpg');
      await posterRef.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final posterPath = posterRef.fullPath;

      final postRef =
          FirebaseFirestore.instance.collection('posts').doc(postId);
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(postRef);
        final data = snapshot.data();
        if (!snapshot.exists || data == null) return;
        if (((data['authorId'] as String?) ?? '').trim() != currentUid) return;

        final rawItems = data['mediaItems'];
        final mediaItems = rawItems is List
            ? rawItems
            : postMediaItemsFromData(data)
                .map((item) => item.toMap())
                .toList(growable: false);
        if (mediaItems.isEmpty) return;
        var found = false;
        final updatedItems = mediaItems.map((raw) {
          if (raw is! Map) return raw;
          final item = raw.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final itemUrl = (item['url'] as String? ?? '').trim();
          final itemPath = (item['storagePath'] as String? ?? '').trim();
          final matches = (itemPath.isNotEmpty && itemPath == videoPath) ||
              itemUrl == media.url.trim() ||
              itemUrl == resolvedSource;
          if (!matches ||
              (item['thumbnailUrl'] as String? ?? '').trim().isNotEmpty) {
            return item;
          }
          found = true;
          return <String, dynamic>{...item, 'thumbnailUrl': posterPath};
        }).toList(growable: false);

        if (found) {
          transaction.update(postRef, <String, dynamic>{
            'mediaItems': updatedItems,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
            '[VideoPosterService] legacy poster backfill failed: $error');
      }
    }
  }
}
