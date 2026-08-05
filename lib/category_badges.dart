import 'package:flutter/material.dart';

import 'app_categories.dart';

class CategoryMetalBadge extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final bool vertical;
  final bool showLabel;
  final VoidCallback? onTap;

  const CategoryMetalBadge({
    super.key,
    required this.label,
    this.selected = false,
    this.compact = false,
    this.vertical = false,
    this.showLabel = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final double radius = vertical ? 20 : 22;
    final EdgeInsets padding = EdgeInsets.symmetric(
      horizontal: compact ? 11 : 14,
      vertical: compact ? 8 : 10,
    );

    final Widget iconBox = Container(
      width: compact ? 26 : 30,
      height: compact ? 26 : 30,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1019),
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFF53C1F9).withValues(alpha:  selected ? 1.0 : 0.85),
          width: 1.5,
        ),
      ),
      child: Icon(
        _iconForLabel(label),
        size: compact ? 15 : 17,
        color: Colors.white,
      ),
    );

    final Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1019),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: const Color(0xFF53C1F9).withValues(alpha:  selected ? 1.0 : 0.85),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF53C1F9).withValues(alpha:  selected ? 0.16 : 0.08),
            blurRadius: selected ? 14 : 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: showLabel
          ? Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconBox,
                SizedBox(width: compact ? 8 : 10),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 12.5 : 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            )
          : Center(child: iconBox),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: content,
      ),
    );
  }

  IconData _iconForLabel(String value) {
    if (appMainCategories.contains(value) || isGeneralCategory(value)) {
      return categoryIconFor(value);
    }

    switch (value) {
      case 'אחר':
        return Icons.help_outline;
      default:
        return Icons.circle_outlined;
    }
  }
}