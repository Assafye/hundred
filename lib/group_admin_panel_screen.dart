import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:hundred_version1/services/group_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class GroupAdminPanelScreen extends StatefulWidget {
  final String groupId;

  const GroupAdminPanelScreen({
    super.key,
    required this.groupId,
  });

  @override
  State<GroupAdminPanelScreen> createState() => _GroupAdminPanelScreenState();
}

class _GroupAdminPanelScreenState extends State<GroupAdminPanelScreen> {
  final GroupService _groupService = GroupService();
  final Set<String> _busyUids = <String>{};

  Future<void> _approve(String uid) async {
    if (_busyUids.contains(uid)) return;
    setState(() {
      _busyUids.add(uid);
    });

    try {
      await _groupService.approveMember(widget.groupId, uid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approve failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyUids.remove(uid);
        });
      }
    }
  }

  Future<void> _deny(String uid) async {
    if (_busyUids.contains(uid)) return;
    setState(() {
      _busyUids.add(uid);
    });

    try {
      await _groupService.denyMember(widget.groupId, uid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deny failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyUids.remove(uid);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBackWrapper(
      child: Scaffold(
      backgroundColor: const Color(0xFF0B1019),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E2632),
        title: const Text('Admin Panel', style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _groupService.pendingMembersStream(widget.groupId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? const [];
          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'No pending requests',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final uid = doc.id;
              final busy = _busyUids.contains(uid);

              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2632),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        uid,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => _deny(uid),
                      child: const Text('Deny', style: TextStyle(color: Colors.redAccent)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF9E7CFF)),
                      onPressed: busy ? null : () => _approve(uid),
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Approve', style: TextStyle(color: Colors.black)),
                    ),
                  ],
                ),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemCount: docs.length,
          );
        },
      ),
      ),
    );
  }
}
