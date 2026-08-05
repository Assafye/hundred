import 'package:flutter/material.dart';

Future<void> showProfileImagesViewerDialog(
  BuildContext context, {
  required List<String> imageUrls,
  int initialIndex = 0,
}) async {
  final normalized = <String>[];
  final seen = <String>{};
  for (final raw in imageUrls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    if (!(url.startsWith('http://') || url.startsWith('https://'))) continue;
    if (!seen.add(url)) continue;
    normalized.add(url);
  }

  if (normalized.isEmpty || !context.mounted) {
    return;
  }

  final startIndex = initialIndex.clamp(0, normalized.length - 1);

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black87,
    builder: (dialogContext) {
      final controller = PageController(initialPage: startIndex);
      var page = startIndex;

      return StatefulBuilder(
        builder: (context, setState) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            child: Container(
              decoration: BoxDecoration(
                color: isLight ? Colors.white : const Color(0xFF0F1725),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'תמונות פרופיל',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                        color: isLight ? Colors.black : Colors.white,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 360,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: PageView.builder(
                        controller: controller,
                        itemCount: normalized.length,
                        onPageChanged: (value) {
                          setState(() {
                            page = value;
                          });
                        },
                        itemBuilder: (context, index) {
                          return InteractiveViewer(
                            minScale: 1,
                            maxScale: 3,
                            child: Image.network(
                              normalized[index],
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) {
                                return Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: isLight ? Colors.black45 : Colors.white54,
                                    size: 42,
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (normalized.length > 1)
                    SizedBox(
                      height: 64,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: normalized.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final isSelected = index == page;
                          return GestureDetector(
                            onTap: () {
                              controller.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                              );
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFF53C1F9)
                                      : (isLight ? const Color(0xFFA9C3FF) : Colors.white24),
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Image.network(
                                normalized[index],
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    color: isLight
                                        ? const Color(0xFFF0F3FA)
                                        : const Color(0xFF1E2632),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: isLight ? Colors.black45 : Colors.white54,
                                      size: 18,
                                    ),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '${page + 1}/${normalized.length}',
                    style: TextStyle(
                      color: isLight ? Colors.black87 : Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
