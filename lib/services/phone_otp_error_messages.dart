import 'phone_otp_service.dart';

String friendlyPhoneOtpErrorMessage(
  Object error, {
  String fallback = 'אירעה תקלה זמנית. נסה שוב בעוד רגע.',
}) {
  final code = error is PhoneOtpException ? error.code : '';
  switch (code) {
    case 'invalid-request':
      return 'לא ניתן להשלים את הבקשה. יש לנסות שוב.';
    case 'invalid-phone-number':
      return 'מספר הטלפון שהוזן אינו תקין.';
    case 'phone-already-registered':
      return 'מספר הטלפון הזה כבר רשום במערכת. יש לעבור למסך ההתחברות.';
    case 'phone-not-registered':
      return 'לא נמצא חשבון עם מספר הטלפון הזה.';
    case 'wrong-code':
      return 'קוד האימות שגוי.';
    case 'code-expired':
      return 'פג תוקף הקוד. יש לבקש קוד חדש.';
    case 'too-many-attempts':
      return 'יותר מדי ניסיונות. יש להמתין ולנסות שוב.';
    case 'send-limit-reached':
      return 'לא ניתן לשלוח קוד נוסף כרגע. יש להמתין ולנסות שוב.';
    case 'network-error':
      return 'אין חיבור לאינטרנט. יש לבדוק את החיבור ולנסות שוב.';
    case 'account-disabled':
      return 'החשבון הזה הושבת. יש לפנות לתמיכה.';
    case 'age-restricted':
      return 'לא ניתן להתחבר לחשבון הזה.';
    case 'account-conflict':
      return 'לא ניתן לאמת את החשבון כרגע. יש לפנות לתמיכה.';
    case 'registration-incomplete':
      return 'יש להשלים את תהליך ההרשמה לפני הכניסה.';
    case 'service-unavailable':
      return 'אירעה תקלה זמנית. נסה שוב בעוד רגע.';
    default:
      return fallback;
  }
}
