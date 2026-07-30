/// Route paths and names in one place, so nothing navigates by string literal.
abstract final class Routes {
  static const String signIn = '/auth';
  static const String signInName = 'signIn';

  static const String otp = '/auth/otp';
  static const String otpName = 'otp';

  static const String trips = '/trips';
  static const String tripsName = 'trips';

  static const String newTrip = '/trips/new';
  static const String newTripName = 'newTrip';

  static const String discover = '/discover';
  static const String discoverName = 'discover';

  static const String profile = '/profile';
  static const String profileName = 'profile';

  static const String tripDetailName = 'tripDetail';
  static const String inviteName = 'invite';

  static String tripDetail(String tripId, {String tab = 'overview'}) =>
      '$trips/$tripId?tab=$tab';
}
