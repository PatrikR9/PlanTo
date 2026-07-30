import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/auth/data/auth_repository_impl.dart';
import 'package:planto/features/auth/domain/auth_repository.dart';
import 'package:planto/features/auth/presentation/controllers/sign_in_controller.dart';

class _FakeAuth implements AuthRepository {
  final List<String> calls = <String>[];
  Object? throwThis;

  Future<void> _run(String name) async {
    calls.add(name);
    if (throwThis != null) throw throwThis!;
  }

  @override
  Future<void> signInAnonymously() => _run('anon');
  @override
  Future<void> sendEmailOtp(String email) => _run('send:$email');
  @override
  Future<void> verifyEmailOtp({required String email, required String token}) =>
      _run('verify:$email:$token');
  @override
  Future<void> signInWithGoogle() => _run('google');
  @override
  Future<void> linkGoogle() => _run('link');
  @override
  Future<void> signOut() => _run('out');
}

void main() {
  group('isPlausibleEmail', () {
    test('accepts ordinary addresses', () {
      expect(isPlausibleEmail('patrik@example.cz'), isTrue);
      expect(isPlausibleEmail('  a.b@sub.domain.com '), isTrue);
    });

    test('rejects obvious nonsense', () {
      expect(isPlausibleEmail('patrik'), isFalse);
      expect(isPlausibleEmail('patrik@localhost'), isFalse);
      expect(isPlausibleEmail(''), isFalse);
    });
  });

  group('SignInController', () {
    late _FakeAuth fake;
    late ProviderContainer container;

    setUp(() {
      fake = _FakeAuth();
      container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);
    });

    test('trims and forwards the email, reports success', () async {
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      expect(await c.sendCode(' patrik@example.cz '), isTrue);
      expect(fake.calls.single, 'send: patrik@example.cz ');
      expect(container.read(signInControllerProvider).hasError, isFalse);
    });

    test('captures failures in state instead of throwing', () async {
      fake.throwThis = Exception('boom');
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      expect(await c.sendCode('patrik@example.cz'), isFalse);
      expect(container.read(signInControllerProvider).hasError, isTrue);
    });
  });
}
