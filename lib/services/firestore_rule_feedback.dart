import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreRuleFeedback {
  const FirestoreRuleFeedback._();

  static bool isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  static String actionMessage(Object error, String fallback) {
    if (error is! FirebaseException) return fallback;

    if (error.code == 'permission-denied') {
      return 'הפעולה נשמרה מקומית ותסונכרן דרך הנתיב המאובטח בהמשך.';
    }

    if (error.code == 'unavailable') {
      return 'שירות הנתונים לא זמין כרגע. נסה שוב בעוד רגע.';
    }

    if (error.code == 'failed-precondition') {
      return 'לא ניתן להשלים את הפעולה כרגע בגלל מצב נתונים לא תקין.';
    }

    return fallback;
  }
}
