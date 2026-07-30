import 'app/bootstrap.dart';

/// Single entry point for every flavour.
///
/// Deviation from architecture section 14, which specified main_dev /
/// main_stg / main_prod: with --dart-define-from-file the flavour file
/// already selects the environment, so three identical one-line files would
/// be pure ceremony. Gradle product flavours still exist for the application
/// id and app name.
Future<void> main() => bootstrap();
