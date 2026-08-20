import '../l10n/app_localizations.dart';

String mutualAidModeLabel(AppLocalizations l, String mode) => switch (mode) {
  'pickup' => l.postMutualAidModePickup,
  'buy' => l.postMutualAidModeBuy,
  'queue' => l.postMutualAidModeQueue,
  'print' => l.postMutualAidModePrint,
  'return' => l.postMutualAidModeReturn,
  _ => l.postMutualAidModeOther,
};
