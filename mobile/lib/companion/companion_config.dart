/// Companion runtime feature switches (master goal §108).
///
/// `COMPANION_ENABLED=false` (dart-define) keeps the existing campus
/// marketplace exactly as it was — no companion shell, no debug routes.
const bool kCompanionEnabled = bool.fromEnvironment(
  'COMPANION_ENABLED',
  defaultValue: true,
);
