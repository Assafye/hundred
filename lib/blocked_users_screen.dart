import 'package:flutter/material.dart';

import 'services/block_user_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final BlockUserService _blockUserService = BlockUserService();
  final Set<String> _unblockingUids = <String>{};

  Future<void> _confirmAndUnblock(BlockedUserEntry entry) async {
    final shouldUnblock = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: const Text('ביטול חסימה'),
                content: Text('לבטל חסימה עבור ${entry.name}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('כן, בטל חסימה'),
                  ),
                ],
              ),
            );
          },
        ) ??
        false;

    if (!shouldUnblock) {
      return;
    }

    setState(() {
      _unblockingUids.add(entry.uid);
    });

    try {
      await _blockUserService.unblockUser(entry.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('החסימה בוטלה בהצלחה.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ביטול חסימה נכשל: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _unblockingUids.remove(entry.uid);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('משתמשים חסומים'),
            centerTitle: true,
          ),
          body: StreamBuilder<List<BlockedUserEntry>>(
            stream: _blockUserService.streamBlockedUsers(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final entries = snapshot.data ?? const <BlockedUserEntry>[];
              if (entries.isEmpty) {
                return Center(
                  child: Text(
                    'לא חסמת משתמשים עדיין',
                    style: TextStyle(
                      color: isLight ? Colors.black54 : Colors.white70,
                      fontSize: 15,
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final isUnblocking = _unblockingUids.contains(entry.uid);
                  return Container(
                    decoration: BoxDecoration(
                      color: isLight ? Colors.white : const Color(0xFF151D2B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isLight
                            ? const Color(0xFFD9E3FF)
                            : const Color(0xFF53C1F9).withValues(alpha: 0.2),
                      ),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF9E7CFF),
                          backgroundImage: entry.avatarUrl.isNotEmpty
                              ? NetworkImage(entry.avatarUrl)
                              : null,
                          child: entry.avatarUrl.isEmpty
                              ? Text(
                                  entry.name.characters.first,
                                  style: const TextStyle(color: Colors.white),
                                )
                              : null,
                        ),
                        title: Text(
                          entry.name,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        trailing: OutlinedButton(
                          onPressed: isUnblocking
                              ? null
                              : () => _confirmAndUnblock(entry),
                          child: isUnblocking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('בטל חסימה'),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
