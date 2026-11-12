import 'package:firebase_core/firebase_core.dart';

abstract final class FirebaseWebOptions {
  static const _apiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
  static const _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );

  static FirebaseOptions get current {
    if (_apiKey.isEmpty ||
        _appId.isEmpty ||
        _messagingSenderId.isEmpty ||
        _projectId.isEmpty) {
      throw StateError(
        'Configura FIREBASE_WEB_API_KEY, FIREBASE_WEB_APP_ID, '
        'FIREBASE_MESSAGING_SENDER_ID y FIREBASE_PROJECT_ID al compilar la web.',
      );
    }

    return FirebaseOptions(
      apiKey: _apiKey,
      appId: _appId,
      messagingSenderId: _messagingSenderId,
      projectId: _projectId,
      authDomain:
          _authDomain.isEmpty ? '$_projectId.firebaseapp.com' : _authDomain,
      storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
    );
  }
}
