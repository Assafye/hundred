import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

/// Turns Firebase Auth / platform errors from the phone verification flow
/// into short, clear, Hebrew messages. Never surfaces raw SDK codes/messages
/// (e.g. "TOO_LONG", "internal-error") to the user.
String friendlyPhoneAuthErrorMessage(
  Object error, {
  String fallback = 'אירעה שגיאה בשליחת קוד האימות. נסה שוב בעוד רגע.',
}) {
  String code = '';
  String message = '';
  if (error is FirebaseAuthException) {
    code = error.code.trim().toLowerCase();
    message = (error.message ?? '').toUpperCase();
  } else if (error is PlatformException) {
    code = error.code.trim().toLowerCase();
    message = (error.message ?? '').toUpperCase();
  } else {
    message = error.toString().toUpperCase();
  }

  // Firebase sometimes reports invalid-phone-number with the underlying
  // libphonenumber reason embedded in the message text instead of the code.
  if (message.contains('TOO_LONG')) {
    return 'מספר הטלפון ארוך מדי. יש לבדוק ולנסות שוב.';
  }
  if (message.contains('TOO_SHORT')) {
    return 'מספר הטלפון קצר מדי. יש לבדוק ולנסות שוב.';
  }
  if (message.contains('INVALID_COUNTRY_CODE')) {
    return 'קידומת המדינה אינה תקינה.';
  }
  if (message.contains('NOT_A_NUMBER')) {
    return 'יש להזין ספרות בלבד במספר הטלפון.';
  }

  switch (code) {
    case 'invalid-phone-number':
      return 'מספר הטלפון שהוזן אינו תקין.';
    case 'missing-phone-number':
      return 'יש להזין מספר טלפון.';
    case 'too-many-requests':
      return 'יותר מדי ניסיונות. נסה שוב בעוד כמה דקות.';
    case 'quota-exceeded':
      return 'המערכת עמוסה כרגע. נסה שוב מאוחר יותר.';
    case 'user-disabled':
      return 'החשבון הזה הושבת. יש לפנות לתמיכה.';
    case 'operation-not-allowed':
      return 'אימות טלפוני אינו זמין כרגע. נסה שוב מאוחר יותר.';
    case 'invalid-verification-code':
      return 'קוד האימות שגוי.';
    case 'missing-verification-code':
      return 'יש להזין את קוד האימות שהתקבל.';
    case 'invalid-verification-id':
    case 'session-expired':
    case 'code-expired':
      return 'פג תוקף הקוד. יש לבקש קוד חדש.';
    case 'network-request-failed':
      return 'אין חיבור לאינטרנט. יש לבדוק את החיבור ולנסות שוב.';
    case 'internal-error':
    case 'unknown':
      return 'אירעה תקלה זמנית. נסה שוב בעוד רגע.';
    case 'captcha-check-failed':
    case 'app-not-authorized':
    case 'missing-client-identifier':
      return 'לא ניתן לאמת את המכשיר כרגע. נסה שוב מאוחר יותר.';
    case 'credential-already-in-use':
    case 'account-exists-with-different-credential':
      return 'מספר הטלפון הזה כבר משויך לחשבון אחר.';
    case 'weak-password':
      return 'הסיסמה חלשה מדי. יש לבחור סיסמה חזקה יותר.';
    case 'requires-recent-login':
      return 'יש לאמת מחדש את הטלפון לפני המשך ההרשמה.';
    default:
      return fallback;
  }
}
