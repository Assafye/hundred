class PostScoreCalculator {
  PostScoreCalculator._();

  static int calculate({
    required int scoreAwarded,
    required int likesCount,
    required int commentsCount,
    required int sharesCount,
    required int savesCount,
  }) {
    return scoreAwarded +
        likesCount +
        (commentsCount * 2) +
        (sharesCount * 3) +
        savesCount;
  }

  static int calculateFromData(Map<String, dynamic> data) {
    return calculate(
      scoreAwarded: _intValue(data['scoreAwarded']),
      likesCount: _intValue(
        data['likesCount'] ??
            (data['likes'] is List ? (data['likes'] as List).length : 0),
      ),
      commentsCount: _intValue(
        data['commentsCount'] ??
            (data['comments'] is List ? (data['comments'] as List).length : 0),
      ),
      sharesCount: _intValue(data['sharesCount']),
      savesCount: _intValue(
        data['savesCount'] ??
            (data['savedBy'] is List ? (data['savedBy'] as List).length : 0),
      ),
    );
  }

  static int taggedBonusForPostScore(int postScore) {
    if (postScore <= 0) {
      return 0;
    }
    return (postScore + 4) ~/ 5;
  }

  static int _intValue(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}