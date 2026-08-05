import 'package:cloud_firestore/cloud_firestore.dart';

class Chat {
  final String id;
  final String name;
  final bool isPublic;
  final List<String> participants;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Chat({
    required this.id,
    required this.name,
    required this.isPublic,
    required this.participants,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'isPublic': isPublic,
      'participants': participants,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
    };
  }

  factory Chat.fromMap(Map<String, dynamic> map) {
    final rawParticipants = map['participants'];
    final participants = rawParticipants is List
        ? rawParticipants.map((e) => e.toString()).toList(growable: false)
        : const <String>[];

    return Chat(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      isPublic: (map['isPublic'] as bool?) ?? false,
      participants: participants,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
