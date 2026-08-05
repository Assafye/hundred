import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform. '
          'Run flutterfire configure to add platform-specific Firebase options.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCf32TzdL1FykPVjyVjxt72-XMckPzx2xk',
    appId: '1:240612337536:web:5e92598ce9723b34b44365',
    messagingSenderId: '240612337536',
    projectId: 'hundred-6c680',
    authDomain: 'hundred-6c680.firebaseapp.com',
    storageBucket: 'hundred-6c680.firebasestorage.app',
    measurementId: 'G-G91QXB8KHD',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDgVQvRF_kh7GEHH4Af2XYuexAqeJQlEIo',
    appId: '1:240612337536:android:1fe21501bbf8658bb44365',
    messagingSenderId: '240612337536',
    projectId: 'hundred-6c680',
    storageBucket: 'hundred-6c680.firebasestorage.app',
  );
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyClX5esGUcFNyd0cNHPqDg6zFFrpQqT6-k',
    appId: '1:240612337536:ios:82203174141d7e5cb44365',
    messagingSenderId: '240612337536',
    projectId: 'hundred-6c680',
    storageBucket: 'hundred-6c680.firebasestorage.app',
    iosBundleId: 'com.example.hundredVersion1',
  );
}
