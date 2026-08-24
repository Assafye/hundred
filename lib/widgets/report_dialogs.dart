import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import '../services/report_service.dart';

bool _tapHitsEditable(PointerDownEvent event) {
  final hitTestResult = HitTestResult();
  GestureBinding.instance.hitTest(hitTestResult, event.position);
  for (final entry in hitTestResult.path) {
    if (entry.target is RenderEditable) {
      return true;
    }
  }
  return false;
}

void _dismissKeyboardOnBackgroundTap(PointerDownEvent event) {
  if (_tapHitsEditable(event)) {
    return;
  }
  FocusManager.instance.primaryFocus?.unfocus();
}

Future<bool> showReportConfirmationDialog(
  BuildContext context, {
  required String targetLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('אישור דיווח'),
          content: Text('רוצה לדווח על ה$targetLabel הזה?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('לא'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('כן'),
            ),
          ],
        ),
      );
    },
  );

  return result == true;
}

Future<ReportReasonOption?> showReportReasonPicker(
  BuildContext context, {
  required String targetLabel,
}) async {
  return showModalBottomSheet<ReportReasonOption>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _dismissKeyboardOnBackgroundTap,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'סיבת דיווח על $targetLabel',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: ReportService.commonReasons.length,
                    itemBuilder: (context, index) {
                      final option = ReportService.commonReasons[index];
                      return ListTile(
                        dense: true,
                        title: Text(option.label, textAlign: TextAlign.right),
                        onTap: () => Navigator.of(sheetContext).pop(option),
                      );
                    },
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      );
    },
  );
}

Future<String?> showReportDetailsDialog(
  BuildContext context, {
  required ReportReasonOption reason,
  required String targetLabel,
}) async {
  final controller = TextEditingController();
  String? errorText;

  final details = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _dismissKeyboardOnBackgroundTap,
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
              title: Text('פירוט דיווח - $targetLabel'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'סיבה שנבחרה: ${reason.label}',
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    onTapOutside: (_) {},
                    minLines: 4,
                    maxLines: 7,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    decoration: InputDecoration(
                      hintText: 'יש לפרט מה קרה כדי לשלוח את הדיווח',
                      errorText: errorText,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) {
                      setState(() {
                        errorText = 'יש להזין פירוט כדי לשלוח דיווח';
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(text);
                  },
                  child: const Text('שלח דיווח'),
                ),
              ],
            ),
            ),
          );
        },
      );
    },
  );

  controller.dispose();
  return details;
}
