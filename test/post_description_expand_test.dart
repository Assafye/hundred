import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hundred_version1/widgets/expandable_post_description.dart';

void main() {
  testWidgets('shows more text action and expands long description', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: ExpandablePostDescription(
                text: 'תיאור ארוך מאוד ' * 6,
                maxLines: 2,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('קרא עוד...'), findsOneWidget);

    await tester.tap(find.text('קרא עוד...'));
    await tester.pumpAndSettle();

    expect(find.text('הצג פחות'), findsOneWidget);
    expect(find.textContaining('תיאור ארוך מאוד'), findsWidgets);
  });
}
