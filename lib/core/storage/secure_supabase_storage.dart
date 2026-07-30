import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Session storage backed by the platform keystore.
///
/// Supabase defaults to SharedPreferences, which on Android is a plain XML
/// file in the app sandbox — readable on a rooted device and included in some
/// backup configurations. The refresh token is long-lived and grants full
/// account access, so it belongs in EncryptedSharedPreferences behind the
/// Android Keystore (architecture section 10.3).
///
/// `accessibility: first_unlock_this_device` means the token is unavailable
/// until the user has unlocked the device once after boot, and never syncs to
/// another device.
class SecureSupabaseStorage extends LocalStorage {
  const SecureSupabaseStorage();

  static const String _key = 'planto.session';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
