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

  /// Manual availability grid. A route rather than a modal because the
  /// "somebody hasn't shared availability" notification has to deep-link
  /// straight here — that nudge is the difference between a trip that gets
  /// planned and one that stalls.
  static const String availabilityName = 'availability';

  static String tripDetail(String tripId, {String tab = 'overview'}) =>
      '$trips/$tripId?tab=$tab';

  static String availability(String tripId) => '$trips/$tripId/availability';
}
