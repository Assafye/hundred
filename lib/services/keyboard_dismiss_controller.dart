class KeyboardDismissController {
  static int _suspendCount = 0;

  static bool get suspendGlobalDismiss => _suspendCount > 0;

  static void suspend() {
    _suspendCount += 1;
  }

  static void resume() {
    if (_suspendCount > 0) {
      _suspendCount -= 1;
    }
  }
}
