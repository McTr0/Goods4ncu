import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

String localizedCategoryLabel(BuildContext context, String? category) {
  final l = AppLocalizations.of(context)!;
  switch ((category ?? '').trim()) {
    case 'electronics':
      return l.electronics;
    case 'books':
      return l.books;
    case 'digitalAccessories':
      return l.digitalAccessories;
    case 'dailyGoods':
      return l.dailyGoods;
    case 'clothingShoes':
      return l.clothingShoes;
    case 'other':
      return l.other;
    default:
      return (category == null || category.trim().isEmpty) ? l.other : category;
  }
}
