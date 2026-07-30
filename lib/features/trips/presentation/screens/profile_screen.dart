import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/entitlement/entitlement.dart';
import '../../../../core/network/supabase_providers.dart';
import '../../../auth/presentation/controllers/sign_in_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Entitlement entitlement = ref.watch(entitlementProvider);
    final bool signedIn = ref.watch(sessionProvider) != null;
    final bool isAnonymous = ref.watch(isAnonymousProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: Text(entitlement.isPro ? 'PlanTo Pro' : 'Zdarma'),
            subtitle: Text(
              entitlement.isPro
                  ? 'Aktivní'
                  : 'Plánování je zdarma. Pro přidává AI.',
            ),
            onTap: () {}, // M9 paywall
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Připojené kalendáře'),
            onTap: () {}, // M4
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Oznámení'),
            onTap: () {}, // M10
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Soukromí a data'),
            onTap: () {}, // M12
          ),
          const Divider(),
          if (isAnonymous)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Jste přihlášeni jako host'),
              subtitle: Text(
                'Přihlaste se, ať o výlety nepřijdete při změně telefonu.',
              ),
            ),
          if (signedIn)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Odhlásit se'),
              onTap: () =>
                  ref.read(signInControllerProvider.notifier).signOut(),
            ),
        ],
      ),
    );
  }
}
