import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import '../../core/network/supabase_providers.dart';
import '../../features/availability/presentation/screens/calendar_callback_screen.dart';
import '../../features/availability/presentation/screens/manual_availability_screen.dart';
import '../../features/auth/presentation/screens/otp_verify_screen.dart';
import '../../features/auth/presentation/screens/sign_in_screen.dart';
import '../../features/trips/domain/trip.dart' show TripKind;
import '../../features/trips/presentation/screens/create_trip_screen.dart';
import '../../features/trips/presentation/screens/edit_trip_screen.dart';
import '../../features/invites/presentation/screens/invite_preview_screen.dart';
import '../../features/trips/presentation/screens/profile_screen.dart';
import '../../features/trips/presentation/screens/trip_detail_screen.dart';
import '../../features/trips/presentation/screens/trips_list_screen.dart';
import '../env/env.dart';
import 'routes.dart';
import 'shell_scaffold.dart';

/// Návrat z Google OAuth na Androidu.
///
/// Na webu dorazí callback jako obyčejná routa, protože je to tatáž doména.
/// Android ho doručí jako `app.planto://calendar-callback?...`, kde je host
/// mimo cestu — go_router čte `uri.path`, takže by z toho zbylo prázdno a
/// nesedlo by to na nic.
///
/// Odběr se neruší schválně: router žije po celou dobu běhu aplikace a
/// zrušení by znamenalo, že se na callback přestane čekat přesně ve chvíli,
/// kdy je uživatel v cizím prohlížeči.
void _listenForCalendarCallback(GoRouter router) {
  if (kIsWeb) return;
  AppLinks().uriLinkStream.listen((Uri uri) {
    if (uri.scheme != 'app.planto' || uri.host != 'calendar-callback') return;
    router.go('${Routes.calendarCallback}?${uri.query}');
  });
}

final Provider<GoRouter> routerProvider = Provider<GoRouter>((Ref ref) {
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> shellKey = GlobalKey<NavigatorState>();

  final GoRouter router = GoRouter(
    navigatorKey: rootKey,
    initialLocation: Routes.trips,
    debugLogDiagnostics: !Env.isProd,

    // Re-evaluates redirects when auth changes, without rebuilding the router.
    refreshListenable: _AuthRefresh(ref),

    redirect: (BuildContext context, GoRouterState state) {
      final String location = state.matchedLocation;

      // The invite preview must render for a signed-out user. This single
      // exception is the entire growth loop (architecture section 6).
      if (location.startsWith('/i/') || location.startsWith('/PlanTo/i/')) {
        return null;
      }

      // Návrat z obrazovky souhlasu Googlu se přesměrovat nesmí.
      //
      // Guard níž posílá nepřihlášeného na `/auth?from=<cesta>` a `from` nese
      // jen cestu, ne query — takže by se zahodilo `?code=`. Autorizační kód
      // je jednorázový a vázaný na redirect_uri, takže druhý pokus neexistuje:
      // uživatel by musel projít celým souhlasem znovu, a to bez vysvětlení.
      //
      // Obrazovka si s chybějící session poradí sama — funkce vrátí 401 a
      // `CalendarCallbackScreen` z toho udělá větu a tlačítko „Zadat
      // dostupnost jinak". To je lepší než tiché odbočení na přihlášení,
      // které tenhle tok navíc nikdy nepotřeboval.
      if (location == Routes.calendarCallback) return null;

      // Without a backend there is nothing to sign in to, so skip the guard
      // entirely and let the UI be reviewed locally.
      if (!Env.isConfigured) {
        return location == Routes.signIn ? Routes.trips : null;
      }

      final bool signedIn = ref.read(sessionProvider) != null;
      final bool isGuest = ref.read(isAnonymousProvider);

      // The OTP screen is part of signing in, so it must stay reachable while
      // the user is still signed out.
      if (!signedIn && location != Routes.signIn && location != Routes.otp) {
        // Preserve the destination so sign-in returns them there.
        return '${Routes.signIn}?from=$location';
      }

      // A guest IS signed in, so the old `signedIn` check bounced them
      // straight back to /trips and the "Přihlásit se" button did nothing.
      // Guests must be able to reach sign-in — upgrading the account is the
      // whole point of the guest path.
      if (signedIn && !isGuest && location == Routes.signIn) {
        return Routes.trips;
      }
      return null;
    },

    routes: <RouteBase>[
      GoRoute(
        path: Routes.signIn,
        name: Routes.signInName,
        builder: (BuildContext context, GoRouterState state) =>
            SignInScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: Routes.otp,
        name: Routes.otpName,
        builder: (BuildContext context, GoRouterState state) => OtpVerifyScreen(
          email: state.uri.queryParameters['email'] ?? '',
          from: state.uri.queryParameters['from'],
        ),
      ),
      // GitHub Pages serves the app under /PlanTo/, so an incoming App Link
      // arrives as /PlanTo/i/<token>. Both shapes resolve to the same screen.
      GoRoute(
        path: '/PlanTo/i/:token',
        builder: (BuildContext context, GoRouterState state) =>
            InvitePreviewScreen(token: state.pathParameters['token']!),
      ),
      GoRoute(
        path: '/i/:token',
        name: Routes.inviteName,
        builder: (BuildContext context, GoRouterState state) =>
            InvitePreviewScreen(token: state.pathParameters['token']!),
      ),

      GoRoute(
        path: Routes.newTrip,
        name: Routes.newTripName,
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const CreateTripScreen(),
      ),
      GoRoute(
        path: Routes.calendarCallback,
        name: Routes.calendarCallbackName,
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            CalendarCallbackScreen(
          code: state.uri.queryParameters['code'],
          tripId: state.uri.queryParameters['trip'],
          error: state.uri.queryParameters['error'],
        ),
      ),
      GoRoute(
        path: Routes.newMeeting,
        name: Routes.newMeetingName,
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const CreateTripScreen(kind: TripKind.meeting),
      ),

      // Trip detail sits OUTSIDE the shell: a trip is a context you enter and
      // leave, not a tab (architecture section 6).
      GoRoute(
        path: '${Routes.trips}/:tripId',
        name: Routes.tripDetailName,
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            TripDetailScreen(
          tripId: state.pathParameters['tripId']!,
          // Inner tabs are query params so a notification can deep-link
          // straight to /trips/abc?tab=dates.
          tab: state.uri.queryParameters['tab'] ?? 'overview',
        ),
        routes: <RouteBase>[
          GoRoute(
            path: 'availability',
            name: Routes.availabilityName,
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                ManualAvailabilityScreen(
              tripId: state.pathParameters['tripId']!,
            ),
          ),
          GoRoute(
            path: 'edit',
            name: Routes.editTripName,
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                EditTripScreen(tripId: state.pathParameters['tripId']!),
          ),
        ],
      ),

      ShellRoute(
        navigatorKey: shellKey,
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            ShellScaffold(state: state, child: child),
        routes: <RouteBase>[
          GoRoute(
            path: Routes.trips,
            name: Routes.tripsName,
            pageBuilder: (BuildContext context, GoRouterState state) =>
                const NoTransitionPage<void>(child: TripsListScreen()),
          ),
          GoRoute(
            path: Routes.discover,
            name: Routes.discoverName,
            pageBuilder: (BuildContext context, GoRouterState state) =>
                const NoTransitionPage<void>(
              child: Scaffold(body: Center(child: Text('Objevovat — V1'))),
            ),
          ),
          GoRoute(
            path: Routes.profile,
            name: Routes.profileName,
            pageBuilder: (BuildContext context, GoRouterState state) =>
                const NoTransitionPage<void>(child: ProfileScreen()),
          ),
        ],
      ),
    ],
  );

  _listenForCalendarCallback(router);
  return router;
});

/// Bridges Riverpod auth state to GoRouter's Listenable-based refresh.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen<Session?>(sessionProvider, (Session? _, Session? __) {
      notifyListeners();
    });
  }
}
