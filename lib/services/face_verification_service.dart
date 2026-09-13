import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class FaceVerificationService {
  FaceVerificationService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    FirebaseFunctions? functions,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west3');

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;

  Future<bool> isCurrentUserVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    final snapshot = await _firestore.collection('users').doc(user.uid).get();
    return snapshot.data()?['isFaceVerified'] == true;
  }

  Future<void> uploadAndFinalize(List<XFile> captures) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be signed in to complete face verification.',
      );
    }
    if (captures.length != 3) {
      throw ArgumentError.value(
        captures.length,
        'captures',
        'Exactly three verification images are required.',
      );
    }

    for (var index = 0; index < captures.length; index++) {
      final bytes = await captures[index].readAsBytes();
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
        throw StateError('Verification image ${index + 1} is invalid.');
      }

      final reference = _storage.ref(
        'users/${user.uid}/verification/image_${index + 1}.jpg',
      );
      await reference.putData(
        bytes,
        SettableMetadata(
          contentType: 'image/jpeg',
          cacheControl: 'private, no-store',
          customMetadata: <String, String>{
            'captureStep': '${index + 1}',
          },
        ),
      );
    }

    final result = await _functions
        .httpsCallable('finalizeFaceVerification')
        .call<Map<String, dynamic>>();
    final data = result.data;
    if (data['verified'] != true) {
      throw StateError('The server did not confirm face verification.');
    }
  }
}
