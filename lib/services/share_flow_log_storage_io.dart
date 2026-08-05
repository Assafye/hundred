import 'dart:io';

const String _logFileName = 'hundred_share_flow_trace.log';

Future<void> appendLine(String line) async {
  final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$_logFileName');
  await file.parent.create(recursive: true);
  await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
}

String logPath() {
  return '${Directory.systemTemp.path}${Platform.pathSeparator}$_logFileName';
}
