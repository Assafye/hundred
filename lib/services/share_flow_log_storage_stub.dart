Future<void> appendLine(String line) async {
  // Web and other non-IO platforms: keep logs in debugPrint only.
}

String logPath() {
  return 'in-memory-debug-log';
}
