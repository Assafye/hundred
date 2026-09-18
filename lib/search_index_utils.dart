String normalizeDirectorySearchText(String input) {
  return input
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\u200e\u200f]'), '')
      .replaceAll(RegExp(r'^@+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

List<String> buildDirectorySearchPrefixes(Iterable<String> values) {
  final searchableValues = <String>{};
  for (final value in values) {
    final normalized = normalizeDirectorySearchText(value);
    if (normalized.isEmpty) continue;
    searchableValues.add(normalized);
    searchableValues.addAll(
      normalized.split(' ').where((part) => part.isNotEmpty),
    );
  }

  final prefixes = <String>{};
  for (final value in searchableValues) {
    final codePoints = value.runes.toList(growable: false);
    for (var length = 1; length <= codePoints.length; length++) {
      prefixes.add(String.fromCharCodes(codePoints.take(length)));
    }
  }
  final sorted = prefixes.toList(growable: false)..sort();
  return sorted;
}
