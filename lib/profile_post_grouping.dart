import 'package:cloud_firestore/cloud_firestore.dart';

class ProfilePostGridEntry {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final String eventGroupId;

  const ProfilePostGridEntry({
    required this.docs,
    required this.eventGroupId,
  });

  QueryDocumentSnapshot<Map<String, dynamic>> get primaryDoc => docs.first;

  bool get isFolder => eventGroupId.isNotEmpty;
}

List<ProfilePostGridEntry> groupProfilePostsByEvent(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
  required bool enableFolders,
  int minPostsPerFolder = 1,
}) {
  if (!enableFolders) {
    return docs
        .map(
          (doc) => ProfilePostGridEntry(
            docs: <QueryDocumentSnapshot<Map<String, dynamic>>>[doc],
            eventGroupId: '',
          ),
        )
        .toList(growable: false);
  }

  final entries = <ProfilePostGridEntry>[];
  final groupedIndexes = <String, int>{};
  final referencedEventGroupIds = docs
      .map((doc) => (doc.data()['eventGroupId'] as String? ?? '').trim())
      .where((id) => id.isNotEmpty)
      .toSet();

  for (final doc in docs) {
    final data = doc.data();
    final rawEventGroupId = (data['eventGroupId'] as String? ?? '').trim();
    final docPostId = (data['postId'] as String? ?? doc.id).trim();
    final eventGroupId = rawEventGroupId.isNotEmpty
        ? rawEventGroupId
        : (referencedEventGroupIds.contains(doc.id)
            ? doc.id
            : (docPostId.isNotEmpty && referencedEventGroupIds.contains(docPostId)
                ? docPostId
                : ''));

    if (eventGroupId.isEmpty) {
      entries.add(
        ProfilePostGridEntry(
          docs: <QueryDocumentSnapshot<Map<String, dynamic>>>[doc],
          eventGroupId: '',
        ),
      );
      continue;
    }

    final existingIndex = groupedIndexes[eventGroupId];
    if (existingIndex == null) {
      groupedIndexes[eventGroupId] = entries.length;
      entries.add(
        ProfilePostGridEntry(
          docs: <QueryDocumentSnapshot<Map<String, dynamic>>>[doc],
          eventGroupId: eventGroupId,
        ),
      );
      continue;
    }

    final existing = entries[existingIndex];
    entries[existingIndex] = ProfilePostGridEntry(
      docs: <QueryDocumentSnapshot<Map<String, dynamic>>>[
        ...existing.docs,
        doc,
      ],
      eventGroupId: eventGroupId,
    );
  }

  if (minPostsPerFolder <= 1) {
    return entries;
  }

  return entries
      .map((entry) {
        if (!entry.isFolder || entry.docs.length >= minPostsPerFolder) {
          return entry;
        }

        return ProfilePostGridEntry(
          docs: entry.docs,
          eventGroupId: '',
        );
      })
      .toList(growable: false);
}
