import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/create_post_screen.dart';

void main() {
  test('CreatePostScreen accepts spontaneous-task prefill values', () {
    const screen = CreatePostScreen(
      initialCategory: 'ספורט',
      initialSubCategory: 'לרוץ',
    );

    expect(screen.initialCategory, 'ספורט');
    expect(screen.initialSubCategory, 'לרוץ');
  });
}
