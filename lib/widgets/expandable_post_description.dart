import 'package:flutter/material.dart';

class ExpandablePostDescription extends StatefulWidget {
  const ExpandablePostDescription({
    super.key,
    required this.text,
    this.maxLines = 2,
    this.textAlign = TextAlign.right,
    this.style,
    this.expandText = 'קרא עוד...',
    this.collapseText = 'הצג פחות',
    this.toggleStyle,
    this.textDirection = TextDirection.rtl,
  });

  final String text;
  final int maxLines;
  final TextAlign textAlign;
  final TextStyle? style;
  final String expandText;
  final String collapseText;
  final TextStyle? toggleStyle;
  final TextDirection textDirection;

  @override
  State<ExpandablePostDescription> createState() =>
      _ExpandablePostDescriptionState();
}

class _ExpandablePostDescriptionState extends State<ExpandablePostDescription> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final defaultToggleStyle = const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      height: 1.2,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final textSpan = TextSpan(text: text, style: widget.style);
        final painter = TextPainter(
          text: textSpan,
          textAlign: widget.textAlign,
          textDirection: widget.textDirection,
          maxLines: widget.maxLines,
          ellipsis: '...',
        )..layout(maxWidth: constraints.maxWidth);

        final needsToggle = painter.didExceedMaxLines;

        return AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                textDirection: widget.textDirection,
                textAlign: widget.textAlign,
                style: widget.style,
                maxLines: _isExpanded ? null : widget.maxLines,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
              if (needsToggle)
                GestureDetector(
                  onTap: () => setState(() => _isExpanded = !_isExpanded),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _isExpanded ? widget.collapseText : widget.expandText,
                      textDirection: widget.textDirection,
                      textAlign: widget.textAlign,
                      style: (widget.toggleStyle ?? defaultToggleStyle),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
