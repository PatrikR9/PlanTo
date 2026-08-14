import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planto/core/error/failure.dart';
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

  @override
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    await _run('signup:$email');
    return signUpReturnsSession;
  }

  /// Co Supabase vrátí, řídí přepínač *Confirm email* v dashboardu, ne kód.
  /// Test si tedy musí umět nastavit obojí.
  bool signUpReturnsSession = true;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) =>
      _run('signin:$email');

  @override
  Future<void> sendPasswordReset(String email) => _run('reset:$email');

  /// Added when the name gate landed. Implementing the interface by hand
  /// rather than mocking is what turned "the repository grew two methods"
  /// into a compile error instead of a test that keeps passing while it
  /// exercises an interface nobody has any more.
  String? displayName;

  @override
  Future<String?> myDisplayName() async {
    calls.add('myName');
    if (throwThis != null) throw throwThis!;
    return displayName;
  }

  @override
  Future<void> setDisplayName(String name) async {
    await _run('setName:$name');
    displayName = name.trim();
  }
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

    test('signUp reports whether a session came back', () async {
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      // Confirm email vypnuté: Supabase vrátí session a je hotovo.
      fake.signUpReturnsSession = true;
      expect(
        await c.signUp(email: 'a@example.cz', password: 'tajne1'),
        isTrue,
      );

      // Zapnuté: účet vznikne, session ne. Není to chyba — obrazovka na to
      // má vlastní panel, a splést si tyhle dva stavy znamená ukázat člověku
      // červenou hlášku ve chvíli, kdy všechno proběhlo správně.
      fake.signUpReturnsSession = false;
      expect(
        await c.signUp(email: 'b@example.cz', password: 'tajne1'),
        isFalse,
      );
      expect(container.read(signInControllerProvider).hasError, isFalse);
    });

    test('signUp on a taken address is an error, not "check your inbox"',
        () async {
      // Supabase na existující adresu nevrátí chybu — vrátí vymyšleného
      // uživatele bez session a bez identit, žádný mail nepošle a heslo
      // neuloží. Repozitář to musí přeložit na EmailAlreadyRegisteredFailure;
      // kdyby to propadlo jako `false`, obrazovka by tvrdila "účet je
      // založený, potvrď schránku" a člověk by pak marně zkoušel heslo, které
      // nikdy nikam nedorazilo. Přesně tohle se stalo 8. srpna.
      fake.throwThis = const EmailAlreadyRegisteredFailure(email: 'a@test.cz');
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      expect(await c.signUp(email: 'a@test.cz', password: 'tajne1'), isNull);
      expect(
        container.read(signInControllerProvider).error,
        isA<EmailAlreadyRegisteredFailure>(),
      );
    });

    test('signUp returns null on failure, not false', () async {
      fake.throwThis = Exception('boom');
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      // Kdyby chyba vracela false, obrazovka by ji zobrazila jako "čeká se na
      // potvrzení e-mailu" — tedy uklidnila by uživatele něčím, co se nestalo.
      expect(await c.signUp(email: 'a@example.cz', password: 'tajne1'), isNull);
      expect(container.read(signInControllerProvider).hasError, isTrue);
    });

    test('signIn forwards the address and password', () async {
      final SignInController c =
          container.read(signInControllerProvider.notifier);
      await container.read(signInControllerProvider.future);

      expect(await c.signIn(email: 'a@example.cz', password: 'tajne1'), isTrue);
      expect(fake.calls.single, 'signin:a@example.cz');
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
