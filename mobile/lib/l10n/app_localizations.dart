import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @aiAssistantTab.
  ///
  /// In en, this message translates to:
  /// **'AI Assistant'**
  String get aiAssistantTab;

  /// No description provided for @aiError.
  ///
  /// In en, this message translates to:
  /// **'Sorry, something went wrong. Please try again.'**
  String get aiError;

  /// No description provided for @aiGreeting.
  ///
  /// In en, this message translates to:
  /// **'Hello! I\'m your campus secondhand trading assistant. How can I help you today?'**
  String get aiGreeting;

  /// No description provided for @aiWillAutoRecognize.
  ///
  /// In en, this message translates to:
  /// **'AI will auto-recognize item info'**
  String get aiWillAutoRecognize;

  /// No description provided for @allCategories.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allCategories;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Campus Marketplace'**
  String get appTitle;

  /// No description provided for @brand.
  ///
  /// In en, this message translates to:
  /// **'Brand'**
  String get brand;

  /// No description provided for @brandLabel.
  ///
  /// In en, this message translates to:
  /// **'Brand'**
  String get brandLabel;

  /// No description provided for @books.
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get books;

  /// No description provided for @buyNow.
  ///
  /// In en, this message translates to:
  /// **'Start deal intent'**
  String get buyNow;

  /// No description provided for @buyer.
  ///
  /// In en, this message translates to:
  /// **'Buyer'**
  String get buyer;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @category.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get category;

  /// No description provided for @categoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get categoryLabel;

  /// No description provided for @chinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified)'**
  String get chinese;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @chatWithSelf.
  ///
  /// In en, this message translates to:
  /// **'Cannot chat with yourself'**
  String get chatWithSelf;

  /// No description provided for @clothingShoes.
  ///
  /// In en, this message translates to:
  /// **'Clothing & Shoes'**
  String get clothingShoes;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon...'**
  String get comingSoon;

  /// No description provided for @condition.
  ///
  /// In en, this message translates to:
  /// **'Condition'**
  String get condition;

  /// No description provided for @conditionLabel.
  ///
  /// In en, this message translates to:
  /// **'Condition'**
  String get conditionLabel;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @confirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get confirmPassword;

  /// No description provided for @connectionFailedRetry.
  ///
  /// In en, this message translates to:
  /// **'Connection failed, please try again later'**
  String get connectionFailedRetry;

  /// No description provided for @connectionRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Connection request sent, waiting for acceptance'**
  String get connectionRequestSent;

  /// No description provided for @connectionPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection privacy'**
  String get connectionPrivacyTitle;

  /// No description provided for @connectionPrivacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose who may interrupt you with realtime requests.'**
  String get connectionPrivacySubtitle;

  /// No description provided for @allowStrangersTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow strangers to connect'**
  String get allowStrangersTitle;

  /// No description provided for @allowStrangersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, strangers can still leave a message but cannot start realtime.'**
  String get allowStrangersSubtitle;

  /// No description provided for @busyModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Pause realtime requests for one hour'**
  String get busyModeTitle;

  /// No description provided for @busyModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mail remains available while you are busy.'**
  String get busyModeSubtitle;

  /// No description provided for @contactSeller.
  ///
  /// In en, this message translates to:
  /// **'Contact Seller'**
  String get contactSeller;

  /// No description provided for @counterOfferAmount.
  ///
  /// In en, this message translates to:
  /// **'Counter offer amount'**
  String get counterOfferAmount;

  /// No description provided for @counterOfferBySeller.
  ///
  /// In en, this message translates to:
  /// **'Seller counter-offered ¥{amount}'**
  String counterOfferBySeller(String amount);

  /// No description provided for @createError.
  ///
  /// In en, this message translates to:
  /// **'Failed to create listing'**
  String get createError;

  /// No description provided for @createListing.
  ///
  /// In en, this message translates to:
  /// **'Create Listing'**
  String get createListing;

  /// No description provided for @createListingAiNeedsRetry.
  ///
  /// In en, this message translates to:
  /// **'Needs retry'**
  String get createListingAiNeedsRetry;

  /// No description provided for @createListingAiReady.
  ///
  /// In en, this message translates to:
  /// **'AI recognition complete'**
  String get createListingAiReady;

  /// No description provided for @createListingAiRecognizing.
  ///
  /// In en, this message translates to:
  /// **'Assistant is recognizing...'**
  String get createListingAiRecognizing;

  /// No description provided for @createListingAiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Take or upload a photo, and the assistant will draft the title, category, brand, and condition for you to confirm.'**
  String get createListingAiSubtitle;

  /// No description provided for @createListingAiTitle.
  ///
  /// In en, this message translates to:
  /// **'Let the assistant take a look first'**
  String get createListingAiTitle;

  /// No description provided for @createListingModeOffer.
  ///
  /// In en, this message translates to:
  /// **'I am offering'**
  String get createListingModeOffer;

  /// No description provided for @createListingModeWanted.
  ///
  /// In en, this message translates to:
  /// **'I am looking for'**
  String get createListingModeWanted;

  /// No description provided for @createWantedPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Describe what you want'**
  String get createWantedPanelTitle;

  /// No description provided for @createWantedPanelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add budget, minimum condition, and the details you care about. The system will match classmates\' active offers.'**
  String get createWantedPanelSubtitle;

  /// No description provided for @createListingBasicInfo.
  ///
  /// In en, this message translates to:
  /// **'Listing basics'**
  String get createListingBasicInfo;

  /// No description provided for @createListingBasicInfoSubtitle.
  ///
  /// In en, this message translates to:
  /// **'These details decide whether classmates will open the listing.'**
  String get createListingBasicInfoSubtitle;

  /// No description provided for @createWantedBasicInfo.
  ///
  /// In en, this message translates to:
  /// **'Wanted basics'**
  String get createWantedBasicInfo;

  /// No description provided for @createWantedBasicInfoSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A clear request helps classmates know whether their item matches.'**
  String get createWantedBasicInfoSubtitle;

  /// No description provided for @createListingBrandHint.
  ///
  /// In en, this message translates to:
  /// **'For example: Apple, Casio, NCU'**
  String get createListingBrandHint;

  /// No description provided for @createWantedBrandLabel.
  ///
  /// In en, this message translates to:
  /// **'Preferred brand'**
  String get createWantedBrandLabel;

  /// No description provided for @createWantedBrandHint.
  ///
  /// In en, this message translates to:
  /// **'Any, or for example: Apple, Casio'**
  String get createWantedBrandHint;

  /// No description provided for @createListingBrandRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter the brand or source'**
  String get createListingBrandRequired;

  /// No description provided for @createListingChangeImage.
  ///
  /// In en, this message translates to:
  /// **'Change image'**
  String get createListingChangeImage;

  /// No description provided for @createListingConditionSection.
  ///
  /// In en, this message translates to:
  /// **'Condition & defects'**
  String get createListingConditionSection;

  /// No description provided for @createListingConditionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Being clear about flaws makes the listing easier to trust.'**
  String get createListingConditionSubtitle;

  /// No description provided for @createWantedConditionSection.
  ///
  /// In en, this message translates to:
  /// **'Minimum requirements'**
  String get createWantedConditionSection;

  /// No description provided for @createWantedConditionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set the lowest condition and notes you can accept.'**
  String get createWantedConditionSubtitle;

  /// No description provided for @createListingDefectHint.
  ///
  /// In en, this message translates to:
  /// **'For example: minor screen scratch'**
  String get createListingDefectHint;

  /// No description provided for @createWantedRequirementHint.
  ///
  /// In en, this message translates to:
  /// **'For example: charger included, minor scratches acceptable'**
  String get createWantedRequirementHint;

  /// No description provided for @createWantedRequirementsLabel.
  ///
  /// In en, this message translates to:
  /// **'Requirements / notes'**
  String get createWantedRequirementsLabel;

  /// No description provided for @createWantedBudgetLabel.
  ///
  /// In en, this message translates to:
  /// **'Budget ceiling (CNY) *'**
  String get createWantedBudgetLabel;

  /// No description provided for @createListingDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Describe purchase time, usage, accessories, pickup location, etc...'**
  String get createListingDescriptionHint;

  /// No description provided for @createListingDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get createListingDescriptionLabel;

  /// No description provided for @createListingDescriptionSection.
  ///
  /// In en, this message translates to:
  /// **'Extra details'**
  String get createListingDescriptionSection;

  /// No description provided for @createListingDescriptionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Optional, but concrete details reduce back-and-forth.'**
  String get createListingDescriptionSubtitle;

  /// No description provided for @createWantedDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Describe how you will use it, pickup preference, and deal breakers...'**
  String get createWantedDescriptionHint;

  /// No description provided for @createWantedDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Wanted description (optional)'**
  String get createWantedDescriptionLabel;

  /// No description provided for @createWantedDescriptionSection.
  ///
  /// In en, this message translates to:
  /// **'Extra request details'**
  String get createWantedDescriptionSection;

  /// No description provided for @createWantedDescriptionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Optional, but details help you get better recommendations.'**
  String get createWantedDescriptionSubtitle;

  /// No description provided for @createListingMissingFields.
  ///
  /// In en, this message translates to:
  /// **'Missing {fields}'**
  String createListingMissingFields(String fields);

  /// No description provided for @createListingPriceInvalid.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid price number'**
  String get createListingPriceInvalid;

  /// No description provided for @createListingPriceLabel.
  ///
  /// In en, this message translates to:
  /// **'Price (CNY) *'**
  String get createListingPriceLabel;

  /// No description provided for @createListingPriceRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a price'**
  String get createListingPriceRequired;

  /// No description provided for @createListingProgressBasics.
  ///
  /// In en, this message translates to:
  /// **'Basics complete'**
  String get createListingProgressBasics;

  /// No description provided for @createListingProgressCondition.
  ///
  /// In en, this message translates to:
  /// **'Condition confirmed'**
  String get createListingProgressCondition;

  /// No description provided for @createListingProgressDescription.
  ///
  /// In en, this message translates to:
  /// **'Extra details'**
  String get createListingProgressDescription;

  /// No description provided for @createListingProgressImage.
  ///
  /// In en, this message translates to:
  /// **'Image-assisted recognition'**
  String get createListingProgressImage;

  /// No description provided for @createListingProgressSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Follow this rhythm and the listing will stay tidy.'**
  String get createListingProgressSubtitle;

  /// No description provided for @createListingProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Publish progress'**
  String get createListingProgressTitle;

  /// No description provided for @createListingReadyHint.
  ///
  /// In en, this message translates to:
  /// **'Everything is ready to publish'**
  String get createListingReadyHint;

  /// No description provided for @createListingTitleHint.
  ///
  /// In en, this message translates to:
  /// **'For example: iPhone 13 Pro Max 256G'**
  String get createListingTitleHint;

  /// No description provided for @createWantedTitleHint.
  ///
  /// In en, this message translates to:
  /// **'For example: Looking for an iPad Air or similar tablet'**
  String get createWantedTitleHint;

  /// No description provided for @createSuccess.
  ///
  /// In en, this message translates to:
  /// **'Listing created successfully'**
  String get createSuccess;

  /// No description provided for @dailyGoods.
  ///
  /// In en, this message translates to:
  /// **'Daily Goods'**
  String get dailyGoods;

  /// No description provided for @defects.
  ///
  /// In en, this message translates to:
  /// **'Defects'**
  String get defects;

  /// No description provided for @defectsLabel.
  ///
  /// In en, this message translates to:
  /// **'Defects'**
  String get defectsLabel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this listing?'**
  String get deleteConfirm;

  /// No description provided for @removeFavoriteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this item from favorites?'**
  String get removeFavoriteConfirm;

  /// No description provided for @favoriteRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed from favorites'**
  String get favoriteRemoved;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @description.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// No description provided for @descriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get descriptionLabel;

  /// No description provided for @digitalAccessories.
  ///
  /// In en, this message translates to:
  /// **'Digital Accessories'**
  String get digitalAccessories;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @electronics.
  ///
  /// In en, this message translates to:
  /// **'Electronics'**
  String get electronics;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @enterValidCounterAmount.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid counter offer amount'**
  String get enterValidCounterAmount;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @fromGallery.
  ///
  /// In en, this message translates to:
  /// **'From gallery'**
  String get fromGallery;

  /// No description provided for @homeTab.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get homeTab;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @listSeparator.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get listSeparator;

  /// No description provided for @listingDirectionAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get listingDirectionAll;

  /// No description provided for @listingDirectionOffer.
  ///
  /// In en, this message translates to:
  /// **'Offer'**
  String get listingDirectionOffer;

  /// No description provided for @listingDirectionWanted.
  ///
  /// In en, this message translates to:
  /// **'Wanted'**
  String get listingDirectionWanted;

  /// No description provided for @listingDetail.
  ///
  /// In en, this message translates to:
  /// **'Listing Details'**
  String get listingDetail;

  /// No description provided for @loadFailed.
  ///
  /// In en, this message translates to:
  /// **'Load failed: {error}'**
  String loadFailed(String error);

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @loadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get loadMore;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// No description provided for @loginError.
  ///
  /// In en, this message translates to:
  /// **'Login error'**
  String get loginError;

  /// No description provided for @loginSuccess.
  ///
  /// In en, this message translates to:
  /// **'Login successful'**
  String get loginSuccess;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// No description provided for @logoutConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to logout?'**
  String get logoutConfirm;

  /// No description provided for @logoutSuccess.
  ///
  /// In en, this message translates to:
  /// **'Logout successful'**
  String get logoutSuccess;

  /// No description provided for @memberSince.
  ///
  /// In en, this message translates to:
  /// **'Member since {date}'**
  String memberSince(String date);

  /// No description provided for @messagesTab.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get messagesTab;

  /// No description provided for @notificationsCenter.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsCenter;

  /// No description provided for @notificationsCenterSubtitle.
  ///
  /// In en, this message translates to:
  /// **'System messages and reminders'**
  String get notificationsCenterSubtitle;

  /// No description provided for @myFavorites.
  ///
  /// In en, this message translates to:
  /// **'My Favorites'**
  String get myFavorites;

  /// No description provided for @myFavoritesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your favorite items'**
  String get myFavoritesSubtitle;

  /// No description provided for @watchlistEmpty.
  ///
  /// In en, this message translates to:
  /// **'No favorites yet'**
  String get watchlistEmpty;

  /// No description provided for @notificationsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No notifications for now'**
  String get notificationsEmpty;

  /// No description provided for @markAllRead.
  ///
  /// In en, this message translates to:
  /// **'Mark all as read'**
  String get markAllRead;

  /// No description provided for @markAllReadSuccess.
  ///
  /// In en, this message translates to:
  /// **'All notifications marked as read'**
  String get markAllReadSuccess;

  /// No description provided for @myListings.
  ///
  /// In en, this message translates to:
  /// **'My Listings'**
  String get myListings;

  /// No description provided for @myListingsMenu.
  ///
  /// In en, this message translates to:
  /// **'View and manage your listings'**
  String get myListingsMenu;

  /// No description provided for @myListingsTab.
  ///
  /// In en, this message translates to:
  /// **'My Listings'**
  String get myListingsTab;

  /// No description provided for @myOrders.
  ///
  /// In en, this message translates to:
  /// **'Deal Records'**
  String get myOrders;

  /// No description provided for @myOrdersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'View offline deal intents and confirmations'**
  String get myOrdersSubtitle;

  /// No description provided for @allOrders.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allOrders;

  /// No description provided for @allNotifications.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allNotifications;

  /// No description provided for @unreadOnly.
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get unreadOnly;

  /// No description provided for @buyerOrders.
  ///
  /// In en, this message translates to:
  /// **'Wanted by Me'**
  String get buyerOrders;

  /// No description provided for @sellerOrders.
  ///
  /// In en, this message translates to:
  /// **'Offered by Me'**
  String get sellerOrders;

  /// No description provided for @orderAsBuyer.
  ///
  /// In en, this message translates to:
  /// **'Wanted'**
  String get orderAsBuyer;

  /// No description provided for @orderAsSeller.
  ///
  /// In en, this message translates to:
  /// **'Offered'**
  String get orderAsSeller;

  /// No description provided for @pay.
  ///
  /// In en, this message translates to:
  /// **'Pay'**
  String get pay;

  /// No description provided for @markPaid.
  ///
  /// In en, this message translates to:
  /// **'Intent confirmed'**
  String get markPaid;

  /// No description provided for @reason.
  ///
  /// In en, this message translates to:
  /// **'Reason (optional)'**
  String get reason;

  /// No description provided for @negotiationDetails.
  ///
  /// In en, this message translates to:
  /// **'Negotiation details'**
  String get negotiationDetails;

  /// No description provided for @negotiationExpired.
  ///
  /// In en, this message translates to:
  /// **'Negotiation expired and cancelled'**
  String get negotiationExpired;

  /// No description provided for @connectionAccepted.
  ///
  /// In en, this message translates to:
  /// **'Connection accepted'**
  String get connectionAccepted;

  /// No description provided for @connectionRejected.
  ///
  /// In en, this message translates to:
  /// **'Connection rejected'**
  String get connectionRejected;

  /// No description provided for @negotiationRejected.
  ///
  /// In en, this message translates to:
  /// **'Negotiation rejected'**
  String get negotiationRejected;

  /// No description provided for @noProducts.
  ///
  /// In en, this message translates to:
  /// **'No products available'**
  String get noProducts;

  /// No description provided for @homeColdStartTitle.
  ///
  /// In en, this message translates to:
  /// **'This place is just starting'**
  String get homeColdStartTitle;

  /// No description provided for @homeColdStartBody.
  ///
  /// In en, this message translates to:
  /// **'Nobody has posted yet. Say what you\'re selling or looking for and others will see it — the first person to speak matters most.'**
  String get homeColdStartBody;

  /// No description provided for @homeColdStartAction.
  ///
  /// In en, this message translates to:
  /// **'I\'ll go first'**
  String get homeColdStartAction;

  /// No description provided for @homeVoicesTitle.
  ///
  /// In en, this message translates to:
  /// **'What people are after'**
  String get homeVoicesTitle;

  /// No description provided for @homeVoicesBody.
  ///
  /// In en, this message translates to:
  /// **'Nothing in the grid yet, but these are what people here are saying. A reply is all it takes to start.'**
  String get homeVoicesBody;

  /// No description provided for @homeFilterEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing matches this filter. Try another, or just say what you want.'**
  String get homeFilterEmpty;

  /// No description provided for @notFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get notFound;

  /// No description provided for @operationFailed.
  ///
  /// In en, this message translates to:
  /// **'Operation failed: {error}'**
  String operationFailed(String error);

  /// No description provided for @other.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get other;

  /// No description provided for @optional.
  ///
  /// In en, this message translates to:
  /// **'optional'**
  String get optional;

  /// No description provided for @owner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get owner;

  /// No description provided for @pendingNegotiation.
  ///
  /// In en, this message translates to:
  /// **'Pending negotiation'**
  String get pendingNegotiation;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @price.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get price;

  /// No description provided for @priceLabel.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get priceLabel;

  /// No description provided for @wantedBudgetShort.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get wantedBudgetShort;

  /// No description provided for @wantedMinimumCondition.
  ///
  /// In en, this message translates to:
  /// **'Minimum condition'**
  String get wantedMinimumCondition;

  /// No description provided for @wantedRequester.
  ///
  /// In en, this message translates to:
  /// **'Requester'**
  String get wantedRequester;

  /// No description provided for @wantedMatchesTitle.
  ///
  /// In en, this message translates to:
  /// **'Matching offers'**
  String get wantedMatchesTitle;

  /// No description provided for @contactRequester.
  ///
  /// In en, this message translates to:
  /// **'Contact requester'**
  String get contactRequester;

  /// No description provided for @recommendMyOffer.
  ///
  /// In en, this message translates to:
  /// **'Recommend my offer'**
  String get recommendMyOffer;

  /// No description provided for @wantedOwnerHint.
  ///
  /// In en, this message translates to:
  /// **'This is your own request'**
  String get wantedOwnerHint;

  /// No description provided for @wantedNoOfferToRecommend.
  ///
  /// In en, this message translates to:
  /// **'You do not have an active offer to recommend'**
  String get wantedNoOfferToRecommend;

  /// No description provided for @wantedRecommendSuccess.
  ///
  /// In en, this message translates to:
  /// **'Recommended to the requester'**
  String get wantedRecommendSuccess;

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @profileLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load profile'**
  String get profileLoadFailed;

  /// No description provided for @profileTab.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTab;

  /// No description provided for @campusMembershipVerified.
  ///
  /// In en, this message translates to:
  /// **'Campus verified'**
  String get campusMembershipVerified;

  /// No description provided for @campusMembershipPending.
  ///
  /// In en, this message translates to:
  /// **'Verification pending'**
  String get campusMembershipPending;

  /// No description provided for @campusMembershipSuspended.
  ///
  /// In en, this message translates to:
  /// **'Membership suspended'**
  String get campusMembershipSuspended;

  /// No description provided for @campusMembershipRevoked.
  ///
  /// In en, this message translates to:
  /// **'Membership revoked'**
  String get campusMembershipRevoked;

  /// No description provided for @campusEmail.
  ///
  /// In en, this message translates to:
  /// **'Campus email'**
  String get campusEmail;

  /// No description provided for @campusEmailHint.
  ///
  /// In en, this message translates to:
  /// **'student-id@email.ncu.edu.cn'**
  String get campusEmailHint;

  /// No description provided for @campusEmailRequired.
  ///
  /// In en, this message translates to:
  /// **'A campus email is required to register'**
  String get campusEmailRequired;

  /// No description provided for @verifyCampusIdentity.
  ///
  /// In en, this message translates to:
  /// **'Verify campus identity'**
  String get verifyCampusIdentity;

  /// No description provided for @campusVerificationSendHint.
  ///
  /// In en, this message translates to:
  /// **'We will send a code to your current campus email. It expires in 5 minutes.'**
  String get campusVerificationSendHint;

  /// No description provided for @sendVerificationCode.
  ///
  /// In en, this message translates to:
  /// **'Send verification code'**
  String get sendVerificationCode;

  /// No description provided for @verificationCodeSent.
  ///
  /// In en, this message translates to:
  /// **'Code sent. Check your campus inbox.'**
  String get verificationCodeSent;

  /// No description provided for @verificationCode.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get verificationCode;

  /// No description provided for @confirmVerification.
  ///
  /// In en, this message translates to:
  /// **'Confirm verification'**
  String get confirmVerification;

  /// No description provided for @campusVerificationSuccess.
  ///
  /// In en, this message translates to:
  /// **'Campus identity verified'**
  String get campusVerificationSuccess;

  /// No description provided for @campusSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch active campus'**
  String get campusSwitchTitle;

  /// No description provided for @campusSwitchDescription.
  ///
  /// In en, this message translates to:
  /// **'Browsing, publishing, and communication stay within this campus. Each device can choose independently.'**
  String get campusSwitchDescription;

  /// No description provided for @campusActive.
  ///
  /// In en, this message translates to:
  /// **'Active campus'**
  String get campusActive;

  /// No description provided for @campusSwitchSuccess.
  ///
  /// In en, this message translates to:
  /// **'Active campus switched'**
  String get campusSwitchSuccess;

  /// No description provided for @publishTab.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get publishTab;

  /// No description provided for @purchaseFailed.
  ///
  /// In en, this message translates to:
  /// **'Purchase failed, please try again'**
  String get purchaseFailed;

  /// No description provided for @purchaseSuccess.
  ///
  /// In en, this message translates to:
  /// **'Deal intent sent. Waiting for seller confirmation.'**
  String get purchaseSuccess;

  /// No description provided for @recognitionFailed.
  ///
  /// In en, this message translates to:
  /// **'Recognition failed: {error}'**
  String recognitionFailed(String error);

  /// No description provided for @recognitionSuccess.
  ///
  /// In en, this message translates to:
  /// **'Recognition successful, info auto-filled'**
  String get recognitionSuccess;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get register;

  /// No description provided for @registerError.
  ///
  /// In en, this message translates to:
  /// **'Registration error'**
  String get registerError;

  /// No description provided for @registerSuccess.
  ///
  /// In en, this message translates to:
  /// **'Registration successful'**
  String get registerSuccess;

  /// No description provided for @requestFailed.
  ///
  /// In en, this message translates to:
  /// **'Request failed: {code}'**
  String requestFailed(int code);

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search products...'**
  String get searchHint;

  /// No description provided for @sellerAcceptedDealComplete.
  ///
  /// In en, this message translates to:
  /// **'Seller accepted, deal complete'**
  String get sellerAcceptedDealComplete;

  /// No description provided for @sellerCounterOffered.
  ///
  /// In en, this message translates to:
  /// **'Seller counter-offered'**
  String get sellerCounterOffered;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @sessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please login again.'**
  String get sessionExpired;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @settingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get settingsSubtitle;

  /// No description provided for @nickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nickname;

  /// No description provided for @nicknameChange.
  ///
  /// In en, this message translates to:
  /// **'Change nickname'**
  String get nicknameChange;

  /// No description provided for @nicknameChangeSuccess.
  ///
  /// In en, this message translates to:
  /// **'Nickname updated'**
  String get nicknameChangeSuccess;

  /// No description provided for @nicknameChangeHint.
  ///
  /// In en, this message translates to:
  /// **'Others will see your new nickname after update'**
  String get nicknameChangeHint;

  /// No description provided for @nicknameConflict.
  ///
  /// In en, this message translates to:
  /// **'This nickname is already taken'**
  String get nicknameConflict;

  /// No description provided for @nicknameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nickname cannot be empty'**
  String get nicknameEmpty;

  /// No description provided for @userAgreement.
  ///
  /// In en, this message translates to:
  /// **'User Agreement'**
  String get userAgreement;

  /// No description provided for @userAgreementTitle.
  ///
  /// In en, this message translates to:
  /// **'User Agreement & Terms'**
  String get userAgreementTitle;

  /// No description provided for @userAgreementSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Understand platform rules and usage responsibilities.'**
  String get userAgreementSubtitle;

  /// No description provided for @sold.
  ///
  /// In en, this message translates to:
  /// **'Sold'**
  String get sold;

  /// No description provided for @status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get status;

  /// No description provided for @submit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get submit;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get takePhoto;

  /// No description provided for @tapCameraIconHint.
  ///
  /// In en, this message translates to:
  /// **'Tap camera icon to take photo or select image'**
  String get tapCameraIconHint;

  /// No description provided for @title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// No description provided for @titleRequired.
  ///
  /// In en, this message translates to:
  /// **'Title is required'**
  String get titleRequired;

  /// No description provided for @totalListings.
  ///
  /// In en, this message translates to:
  /// **'{count} listings'**
  String totalListings(int count);

  /// No description provided for @tradeProtection.
  ///
  /// In en, this message translates to:
  /// **'Offline deal reminder'**
  String get tradeProtection;

  /// No description provided for @tradeProtectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The platform does not escrow funds. Confirm inspection, handoff, and payment with each other.'**
  String get tradeProtectionSubtitle;

  /// No description provided for @typeMessage.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get typeMessage;

  /// No description provided for @uploadFromCamera.
  ///
  /// In en, this message translates to:
  /// **'Upload from camera'**
  String get uploadFromCamera;

  /// No description provided for @uploadFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Upload from gallery'**
  String get uploadFromGallery;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @adminConsole.
  ///
  /// In en, this message translates to:
  /// **'Admin Console'**
  String get adminConsole;

  /// No description provided for @adminConsoleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'System overview & management'**
  String get adminConsoleSubtitle;

  /// No description provided for @adminOnly.
  ///
  /// In en, this message translates to:
  /// **'Admin only'**
  String get adminOnly;

  /// No description provided for @adminStatsTab.
  ///
  /// In en, this message translates to:
  /// **'Stats'**
  String get adminStatsTab;

  /// No description provided for @adminListingsTab.
  ///
  /// In en, this message translates to:
  /// **'Listings'**
  String get adminListingsTab;

  /// No description provided for @adminOrdersTab.
  ///
  /// In en, this message translates to:
  /// **'Deal Records'**
  String get adminOrdersTab;

  /// No description provided for @adminUsersTab.
  ///
  /// In en, this message translates to:
  /// **'Users'**
  String get adminUsersTab;

  /// No description provided for @adminTotalListings.
  ///
  /// In en, this message translates to:
  /// **'Total Listings'**
  String get adminTotalListings;

  /// No description provided for @adminActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get adminActive;

  /// No description provided for @adminUsers.
  ///
  /// In en, this message translates to:
  /// **'Users'**
  String get adminUsers;

  /// No description provided for @adminOrders.
  ///
  /// In en, this message translates to:
  /// **'Deal Records'**
  String get adminOrders;

  /// No description provided for @adminTrend7Days.
  ///
  /// In en, this message translates to:
  /// **'Trend (7 days)'**
  String get adminTrend7Days;

  /// No description provided for @changeRole.
  ///
  /// In en, this message translates to:
  /// **'Change Role'**
  String get changeRole;

  /// No description provided for @markShipped.
  ///
  /// In en, this message translates to:
  /// **'Confirm deal'**
  String get markShipped;

  /// No description provided for @markCompleted.
  ///
  /// In en, this message translates to:
  /// **'Deal confirmed'**
  String get markCompleted;

  /// No description provided for @orderStatusUpdated.
  ///
  /// In en, this message translates to:
  /// **'Deal record updated'**
  String get orderStatusUpdated;

  /// No description provided for @userRoleUpdated.
  ///
  /// In en, this message translates to:
  /// **'User role updated'**
  String get userRoleUpdated;

  /// No description provided for @adminTakedown.
  ///
  /// In en, this message translates to:
  /// **'Takedown'**
  String get adminTakedown;

  /// No description provided for @adminTakedownConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm Takedown'**
  String get adminTakedownConfirm;

  /// No description provided for @adminTakedownConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to takedown \"{title}\"?'**
  String adminTakedownConfirmMessage(String title);

  /// No description provided for @adminTakedownSuccess.
  ///
  /// In en, this message translates to:
  /// **'Listing taken down'**
  String get adminTakedownSuccess;

  /// No description provided for @adminBan.
  ///
  /// In en, this message translates to:
  /// **'Ban'**
  String get adminBan;

  /// No description provided for @adminBanConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm Ban'**
  String get adminBanConfirm;

  /// No description provided for @adminBanConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to ban this user? All their sessions will be terminated.'**
  String get adminBanConfirmMessage;

  /// No description provided for @adminBanSuccess.
  ///
  /// In en, this message translates to:
  /// **'User banned'**
  String get adminBanSuccess;

  /// No description provided for @adminUnban.
  ///
  /// In en, this message translates to:
  /// **'Unban'**
  String get adminUnban;

  /// No description provided for @adminUnbanSuccess.
  ///
  /// In en, this message translates to:
  /// **'User unbanned'**
  String get adminUnbanSuccess;

  /// No description provided for @adminSearchListingsPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Search listings...'**
  String get adminSearchListingsPlaceholder;

  /// No description provided for @adminSearchUsersPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Search users...'**
  String get adminSearchUsersPlaceholder;

  /// No description provided for @adminNoUsersFound.
  ///
  /// In en, this message translates to:
  /// **'No users found'**
  String get adminNoUsersFound;

  /// No description provided for @adminNoListingsFound.
  ///
  /// In en, this message translates to:
  /// **'No listings found'**
  String get adminNoListingsFound;

  /// No description provided for @adminSensitiveActionsLocked.
  ///
  /// In en, this message translates to:
  /// **'Sensitive actions are locked'**
  String get adminSensitiveActionsLocked;

  /// No description provided for @adminSensitiveActionsLockedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Viewing is unaffected. Bans, takedowns, role changes, and moderation decisions require password verification.'**
  String get adminSensitiveActionsLockedSubtitle;

  /// No description provided for @adminUnlockActions.
  ///
  /// In en, this message translates to:
  /// **'Verify and unlock'**
  String get adminUnlockActions;

  /// No description provided for @adminReauthenticateTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify administrator identity'**
  String get adminReauthenticateTitle;

  /// No description provided for @adminReauthenticateHint.
  ///
  /// In en, this message translates to:
  /// **'Sensitive actions stay unlocked for 10 minutes'**
  String get adminReauthenticateHint;

  /// No description provided for @adminTotpCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Authenticator code (if enabled)'**
  String get adminTotpCodeLabel;

  /// No description provided for @adminTotpCodeHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit code from your authenticator app'**
  String get adminTotpCodeHint;

  /// No description provided for @agentPlanPendingHeader.
  ///
  /// In en, this message translates to:
  /// **'Pending actions (proposed by assistant, run only after you confirm)'**
  String get agentPlanPendingHeader;

  /// No description provided for @agentPlanConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get agentPlanConfirmAction;

  /// No description provided for @undoDoneHeader.
  ///
  /// In en, this message translates to:
  /// **'Done — you can still undo'**
  String get undoDoneHeader;

  /// No description provided for @undoAction.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undoAction;

  /// Countdown on the undo affordance
  ///
  /// In en, this message translates to:
  /// **'{seconds}s left'**
  String undoRemainingSeconds(int seconds);

  /// No description provided for @undoSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Undone'**
  String get undoSucceeded;

  /// No description provided for @undoConflict.
  ///
  /// In en, this message translates to:
  /// **'Could not undo'**
  String get undoConflict;

  /// No description provided for @undoFailed.
  ///
  /// In en, this message translates to:
  /// **'Undo failed, please try again'**
  String get undoFailed;

  /// No description provided for @intentPageTitle.
  ///
  /// In en, this message translates to:
  /// **'What I want'**
  String get intentPageTitle;

  /// No description provided for @intentComposerPrompt.
  ///
  /// In en, this message translates to:
  /// **'Say it however you like — no form. Selling, looking for something, looking for someone, asking a favour, or planning something.'**
  String get intentComposerPrompt;

  /// No description provided for @intentComposerHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Clearing out my dorm, will take whatever for the mini fridge / Looking for someone to play badminton with'**
  String get intentComposerHint;

  /// No description provided for @intentKindGoodsOffer.
  ///
  /// In en, this message translates to:
  /// **'Selling'**
  String get intentKindGoodsOffer;

  /// No description provided for @intentKindGoodsSeek.
  ///
  /// In en, this message translates to:
  /// **'Looking for'**
  String get intentKindGoodsSeek;

  /// No description provided for @intentKindCompanion.
  ///
  /// In en, this message translates to:
  /// **'Looking for company'**
  String get intentKindCompanion;

  /// No description provided for @intentKindHelp.
  ///
  /// In en, this message translates to:
  /// **'Asking a favour'**
  String get intentKindHelp;

  /// No description provided for @intentKindActivity.
  ///
  /// In en, this message translates to:
  /// **'Planning something'**
  String get intentKindActivity;

  /// No description provided for @intentPriceWhatever.
  ///
  /// In en, this message translates to:
  /// **'Whatever you\'ll give me'**
  String get intentPriceWhatever;

  /// No description provided for @intentPriceFree.
  ///
  /// In en, this message translates to:
  /// **'Giving it away'**
  String get intentPriceFree;

  /// No description provided for @intentPriceFlexible.
  ///
  /// In en, this message translates to:
  /// **'Price open'**
  String get intentPriceFlexible;

  /// No description provided for @intentTimeFlexible.
  ///
  /// In en, this message translates to:
  /// **'Any time'**
  String get intentTimeFlexible;

  /// No description provided for @intentSubmit.
  ///
  /// In en, this message translates to:
  /// **'Post it'**
  String get intentSubmit;

  /// No description provided for @intentPhotoAction.
  ///
  /// In en, this message translates to:
  /// **'One photo, everything at once'**
  String get intentPhotoAction;

  /// No description provided for @intentPhotoWorking.
  ///
  /// In en, this message translates to:
  /// **'Reading the photo…'**
  String get intentPhotoWorking;

  /// No description provided for @intentPhotoSplit.
  ///
  /// In en, this message translates to:
  /// **'Found a few — confirm which to post'**
  String get intentPhotoSplit;

  /// No description provided for @intentPhotoNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing recognised — saved what you wrote'**
  String get intentPhotoNothing;

  /// No description provided for @intentSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get intentSaving;

  /// No description provided for @intentSaved.
  ///
  /// In en, this message translates to:
  /// **'Noted — you\'ll hear if something fits'**
  String get intentSaved;

  /// No description provided for @intentSavedNotListed.
  ///
  /// In en, this message translates to:
  /// **'Noted. Without a price it won\'t appear in the browse grid, but it will still be matched'**
  String get intentSavedNotListed;

  /// No description provided for @intentMineHeader.
  ///
  /// In en, this message translates to:
  /// **'What I\'ve said'**
  String get intentMineHeader;

  /// No description provided for @intentMineEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet. One sentence above is enough.'**
  String get intentMineEmpty;

  /// No description provided for @intentDraftBadge.
  ///
  /// In en, this message translates to:
  /// **'Awaiting your confirmation'**
  String get intentDraftBadge;

  /// No description provided for @intentConfirmDraft.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get intentConfirmDraft;

  /// No description provided for @intentNoMatchesYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing fits yet'**
  String get intentNoMatchesYet;

  /// No description provided for @intentFulfilAction.
  ///
  /// In en, this message translates to:
  /// **'Sorted'**
  String get intentFulfilAction;

  /// No description provided for @intentWithdrawAction.
  ///
  /// In en, this message translates to:
  /// **'Never mind'**
  String get intentWithdrawAction;

  /// No description provided for @intentFulfilled.
  ///
  /// In en, this message translates to:
  /// **'Marked as sorted'**
  String get intentFulfilled;

  /// No description provided for @intentWithdrawn.
  ///
  /// In en, this message translates to:
  /// **'Withdrawn'**
  String get intentWithdrawn;

  /// No description provided for @intentFeedHeader.
  ///
  /// In en, this message translates to:
  /// **'What people are looking for'**
  String get intentFeedHeader;

  /// No description provided for @intentFeedEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nobody is looking for anything yet. Say something first so others can see it.'**
  String get intentFeedEmpty;

  /// No description provided for @intentRespondAction.
  ///
  /// In en, this message translates to:
  /// **'I can help'**
  String get intentRespondAction;

  /// No description provided for @intentRespondTitle.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get intentRespondTitle;

  /// No description provided for @intentRespondHint.
  ///
  /// In en, this message translates to:
  /// **'Say what you have, or how you can help'**
  String get intentRespondHint;

  /// No description provided for @intentRespondSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get intentRespondSend;

  /// No description provided for @intentRespondSent.
  ///
  /// In en, this message translates to:
  /// **'Sent — they\'ll see it in their messages'**
  String get intentRespondSent;

  /// No description provided for @priceDiscoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Let the assistant settle it'**
  String get priceDiscoveryTitle;

  /// No description provided for @priceDiscoveryStart.
  ///
  /// In en, this message translates to:
  /// **'Settle by private limits'**
  String get priceDiscoveryStart;

  /// No description provided for @priceDiscoveryYourLimit.
  ///
  /// In en, this message translates to:
  /// **'Your limit (CNY)'**
  String get priceDiscoveryYourLimit;

  /// No description provided for @priceDiscoveryBuyerHint.
  ///
  /// In en, this message translates to:
  /// **'The most you\'d pay'**
  String get priceDiscoveryBuyerHint;

  /// No description provided for @priceDiscoverySellerHint.
  ///
  /// In en, this message translates to:
  /// **'The least you\'d accept'**
  String get priceDiscoverySellerHint;

  /// No description provided for @priceDiscoverySubmit.
  ///
  /// In en, this message translates to:
  /// **'Tell the assistant privately'**
  String get priceDiscoverySubmit;

  /// No description provided for @priceDiscoveryWaiting.
  ///
  /// In en, this message translates to:
  /// **'Got it. The result comes once they\'ve answered too — they cannot see your number.'**
  String get priceDiscoveryWaiting;

  /// No description provided for @priceDiscoveryNoDeal.
  ///
  /// In en, this message translates to:
  /// **'It didn\'t work out this time. Want to just talk instead?'**
  String get priceDiscoveryNoDeal;

  /// No description provided for @priceDiscoveryAcceptInvite.
  ///
  /// In en, this message translates to:
  /// **'They\'d like to settle it this way'**
  String get priceDiscoveryAcceptInvite;

  /// No description provided for @priceDiscoveryAgree.
  ///
  /// In en, this message translates to:
  /// **'Alright'**
  String get priceDiscoveryAgree;

  /// No description provided for @priceDiscoveryPreferHaggle.
  ///
  /// In en, this message translates to:
  /// **'I\'d rather talk'**
  String get priceDiscoveryPreferHaggle;

  /// No description provided for @priceDiscoveryDeclined.
  ///
  /// In en, this message translates to:
  /// **'Switched to talking it over'**
  String get priceDiscoveryDeclined;

  /// No description provided for @priceDiscoveryInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a sensible price'**
  String get priceDiscoveryInvalid;

  /// No description provided for @agreementCardTitle.
  ///
  /// In en, this message translates to:
  /// **'What we agreed'**
  String get agreementCardTitle;

  /// No description provided for @agreementSlotItem.
  ///
  /// In en, this message translates to:
  /// **'Item'**
  String get agreementSlotItem;

  /// No description provided for @agreementSlotPrice.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get agreementSlotPrice;

  /// No description provided for @agreementSlotTime.
  ///
  /// In en, this message translates to:
  /// **'When'**
  String get agreementSlotTime;

  /// No description provided for @agreementSlotPlace.
  ///
  /// In en, this message translates to:
  /// **'Where'**
  String get agreementSlotPlace;

  /// No description provided for @agreementSlotWho.
  ///
  /// In en, this message translates to:
  /// **'Who'**
  String get agreementSlotWho;

  /// No description provided for @agreementSlotBring.
  ///
  /// In en, this message translates to:
  /// **'Bring'**
  String get agreementSlotBring;

  /// No description provided for @agreementSlotConditions.
  ///
  /// In en, this message translates to:
  /// **'Other terms'**
  String get agreementSlotConditions;

  /// No description provided for @agreementSuggestion.
  ///
  /// In en, this message translates to:
  /// **'Read from the chat — adopt it?'**
  String get agreementSuggestion;

  /// No description provided for @agreementAdopt.
  ///
  /// In en, this message translates to:
  /// **'Adopt'**
  String get agreementAdopt;

  /// No description provided for @agreementWaitingOther.
  ///
  /// In en, this message translates to:
  /// **'Waiting for them'**
  String get agreementWaitingOther;

  /// No description provided for @agreementAgreed.
  ///
  /// In en, this message translates to:
  /// **'Both agreed'**
  String get agreementAgreed;

  /// No description provided for @agreementNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get agreementNotSet;

  /// No description provided for @agreementSet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get agreementSet;

  /// No description provided for @agreementSettle.
  ///
  /// In en, this message translates to:
  /// **'It\'s settled'**
  String get agreementSettle;

  /// No description provided for @agreementSettled.
  ///
  /// In en, this message translates to:
  /// **'Settled'**
  String get agreementSettled;

  /// No description provided for @agreementStale.
  ///
  /// In en, this message translates to:
  /// **'This changed — take a look'**
  String get agreementStale;

  /// No description provided for @handoffPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'How did it go?'**
  String get handoffPromptTitle;

  /// No description provided for @handoffHappened.
  ///
  /// In en, this message translates to:
  /// **'We met and it worked out'**
  String get handoffHappened;

  /// No description provided for @handoffMissed.
  ///
  /// In en, this message translates to:
  /// **'It didn\'t happen'**
  String get handoffMissed;

  /// No description provided for @handoffOnTime.
  ///
  /// In en, this message translates to:
  /// **'They were on time'**
  String get handoffOnTime;

  /// No description provided for @handoffLate.
  ///
  /// In en, this message translates to:
  /// **'They were late'**
  String get handoffLate;

  /// No description provided for @handoffThanks.
  ///
  /// In en, this message translates to:
  /// **'Thanks — noted'**
  String get handoffThanks;

  /// No description provided for @handoffOnce.
  ///
  /// In en, this message translates to:
  /// **'Asked once, and it cannot be changed later'**
  String get handoffOnce;

  /// No description provided for @reputationNewcomer.
  ///
  /// In en, this message translates to:
  /// **'New here — no record yet'**
  String get reputationNewcomer;

  /// Someone's record, stated as facts rather than a score
  ///
  /// In en, this message translates to:
  /// **'Completed {completed}, on time {onTime}'**
  String reputationSummary(int completed, int onTime);

  /// The agreed price from private-limit matching
  ///
  /// In en, this message translates to:
  /// **'Agreed at ¥{price}'**
  String priceDiscoveryMatched(String price);

  /// How many candidate matches an intent has
  ///
  /// In en, this message translates to:
  /// **'{count} possible match(es)'**
  String intentMatchCount(int count);

  /// No description provided for @agentPlanExecuted.
  ///
  /// In en, this message translates to:
  /// **'Action executed'**
  String get agentPlanExecuted;

  /// No description provided for @agentPlanCancelled.
  ///
  /// In en, this message translates to:
  /// **'Action cancelled'**
  String get agentPlanCancelled;

  /// No description provided for @fulfillWantedAction.
  ///
  /// In en, this message translates to:
  /// **'Mark fulfilled'**
  String get fulfillWantedAction;

  /// No description provided for @reopenWantedAction.
  ///
  /// In en, this message translates to:
  /// **'Reopen request'**
  String get reopenWantedAction;

  /// No description provided for @wantedFulfilledHint.
  ///
  /// In en, this message translates to:
  /// **'This request is fulfilled and no longer receives matches'**
  String get wantedFulfilledHint;

  /// No description provided for @wantedFulfilledToast.
  ///
  /// In en, this message translates to:
  /// **'Request marked fulfilled'**
  String get wantedFulfilledToast;

  /// No description provided for @wantedReopenedToast.
  ///
  /// In en, this message translates to:
  /// **'Request reopened'**
  String get wantedReopenedToast;

  /// No description provided for @wantedFulfillConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Mark this request fulfilled?'**
  String get wantedFulfillConfirmTitle;

  /// No description provided for @wantedFulfillConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'New matches and recommendations will stop. Existing conversations and recommendation history will remain, and you can reopen the request later.'**
  String get wantedFulfillConfirmBody;

  /// No description provided for @wantedClosedResponderHint.
  ///
  /// In en, this message translates to:
  /// **'This request is closed, so it cannot receive new recommendations.'**
  String get wantedClosedResponderHint;

  /// No description provided for @wantedResponsesReceivedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendations received'**
  String get wantedResponsesReceivedTitle;

  /// No description provided for @wantedResponsesSentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendations sent'**
  String get wantedResponsesSentTitle;

  /// No description provided for @wantedResponsesReceivedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No one has recommended an offer for this request yet.'**
  String get wantedResponsesReceivedEmpty;

  /// No description provided for @wantedResponsesSentEmpty.
  ///
  /// In en, this message translates to:
  /// **'You have not recommended an offer yet.'**
  String get wantedResponsesSentEmpty;

  /// No description provided for @wantedResponseLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Recommendations could not be loaded. Try again.'**
  String get wantedResponseLoadFailed;

  /// No description provided for @wantedResponseActionFailed.
  ///
  /// In en, this message translates to:
  /// **'The recommendation could not be updated: {error}'**
  String wantedResponseActionFailed(String error);

  /// No description provided for @wantedResponseRoundClosedToast.
  ///
  /// In en, this message translates to:
  /// **'This recommendation belongs to a closed request round and is now read-only.'**
  String get wantedResponseRoundClosedToast;

  /// No description provided for @wantedResponseClosedRoundLabel.
  ///
  /// In en, this message translates to:
  /// **'Closed request round · Read-only'**
  String get wantedResponseClosedRoundLabel;

  /// No description provided for @wantedResponseAcceptedToast.
  ///
  /// In en, this message translates to:
  /// **'Recommendation accepted'**
  String get wantedResponseAcceptedToast;

  /// No description provided for @wantedResponseDismissedToast.
  ///
  /// In en, this message translates to:
  /// **'Recommendation dismissed'**
  String get wantedResponseDismissedToast;

  /// No description provided for @wantedResponseWithdrawnToast.
  ///
  /// In en, this message translates to:
  /// **'Recommendation withdrawn'**
  String get wantedResponseWithdrawnToast;

  /// No description provided for @wantedResponseStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Awaiting decision'**
  String get wantedResponseStatusPending;

  /// No description provided for @wantedResponseStatusAccepted.
  ///
  /// In en, this message translates to:
  /// **'Accepted'**
  String get wantedResponseStatusAccepted;

  /// No description provided for @wantedResponseStatusDismissed.
  ///
  /// In en, this message translates to:
  /// **'Dismissed'**
  String get wantedResponseStatusDismissed;

  /// No description provided for @wantedResponseStatusWithdrawn.
  ///
  /// In en, this message translates to:
  /// **'Withdrawn'**
  String get wantedResponseStatusWithdrawn;

  /// No description provided for @wantedResponseStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unavailable'**
  String get wantedResponseStatusUnknown;

  /// No description provided for @wantedResponseListingStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get wantedResponseListingStatusActive;

  /// No description provided for @wantedResponseListingStatusFulfilled.
  ///
  /// In en, this message translates to:
  /// **'Fulfilled'**
  String get wantedResponseListingStatusFulfilled;

  /// No description provided for @wantedResponseListingStatusSold.
  ///
  /// In en, this message translates to:
  /// **'Sold'**
  String get wantedResponseListingStatusSold;

  /// No description provided for @wantedResponseListingStatusDeleted.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get wantedResponseListingStatusDeleted;

  /// No description provided for @wantedResponseListingStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unavailable'**
  String get wantedResponseListingStatusUnknown;

  /// No description provided for @wantedResponseWantedContext.
  ///
  /// In en, this message translates to:
  /// **'Request: {title} · {status}'**
  String wantedResponseWantedContext(String title, String status);

  /// No description provided for @wantedResponseOfferContext.
  ///
  /// In en, this message translates to:
  /// **'Offer: {title} · {status}'**
  String wantedResponseOfferContext(String title, String status);

  /// No description provided for @wantedResponseMessageLabel.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get wantedResponseMessageLabel;

  /// No description provided for @wantedResponseOpenOfferAction.
  ///
  /// In en, this message translates to:
  /// **'View offer'**
  String get wantedResponseOpenOfferAction;

  /// No description provided for @wantedResponseAcceptAction.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get wantedResponseAcceptAction;

  /// No description provided for @wantedResponseDismissAction.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get wantedResponseDismissAction;

  /// No description provided for @wantedResponseWithdrawAction.
  ///
  /// In en, this message translates to:
  /// **'Withdraw'**
  String get wantedResponseWithdrawAction;

  /// No description provided for @agentPlanSecondConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'High-risk action — confirm again'**
  String get agentPlanSecondConfirmTitle;

  /// No description provided for @agentPlanSecondConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm and run'**
  String get agentPlanSecondConfirmAction;

  /// No description provided for @adminReauthenticateSuccess.
  ///
  /// In en, this message translates to:
  /// **'Administrator verified. Sensitive actions are temporarily unlocked.'**
  String get adminReauthenticateSuccess;

  /// No description provided for @adminLoginAs.
  ///
  /// In en, this message translates to:
  /// **'Login as user'**
  String get adminLoginAs;

  /// No description provided for @adminLoginAsSuccess.
  ///
  /// In en, this message translates to:
  /// **'Logged in as {username}'**
  String adminLoginAsSuccess(String username);

  /// No description provided for @adminLoginAsFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get adminLoginAsFailed;

  /// No description provided for @adminLoginAsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get adminLoginAsConfirm;

  /// No description provided for @adminLoginAsWarning.
  ///
  /// In en, this message translates to:
  /// **'You are about to switch to this user\'s identity'**
  String get adminLoginAsWarning;

  /// No description provided for @adminViewListings.
  ///
  /// In en, this message translates to:
  /// **'View Listings'**
  String get adminViewListings;

  /// No description provided for @orderId.
  ///
  /// In en, this message translates to:
  /// **'Record ID'**
  String get orderId;

  /// No description provided for @orderDetail.
  ///
  /// In en, this message translates to:
  /// **'Deal Details'**
  String get orderDetail;

  /// No description provided for @dealParties.
  ///
  /// In en, this message translates to:
  /// **'Participants'**
  String get dealParties;

  /// No description provided for @dealTimeline.
  ///
  /// In en, this message translates to:
  /// **'Deal Timeline'**
  String get dealTimeline;

  /// No description provided for @noOrders.
  ///
  /// In en, this message translates to:
  /// **'No deal records'**
  String get noOrders;

  /// No description provided for @conditionLikeNew.
  ///
  /// In en, this message translates to:
  /// **'Like New'**
  String get conditionLikeNew;

  /// No description provided for @conditionGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get conditionGood;

  /// No description provided for @conditionFair.
  ///
  /// In en, this message translates to:
  /// **'Fair'**
  String get conditionFair;

  /// No description provided for @conditionPoor.
  ///
  /// In en, this message translates to:
  /// **'Poor'**
  String get conditionPoor;

  /// No description provided for @buyerInitiatedNegotiation.
  ///
  /// In en, this message translates to:
  /// **'Buyer initiated negotiation'**
  String get buyerInitiatedNegotiation;

  /// No description provided for @cannotContactSeller.
  ///
  /// In en, this message translates to:
  /// **'Unable to contact seller: missing seller info'**
  String get cannotContactSeller;

  /// No description provided for @itemAlreadyPurchased.
  ///
  /// In en, this message translates to:
  /// **'Oops, this item is too popular, someone beat you to it!'**
  String get itemAlreadyPurchased;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @idLabel.
  ///
  /// In en, this message translates to:
  /// **'ID:'**
  String get idLabel;

  /// No description provided for @ownerIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Owner ID:'**
  String get ownerIdLabel;

  /// No description provided for @orderNumber.
  ///
  /// In en, this message translates to:
  /// **'Deal record #{id}'**
  String orderNumber(String id);

  /// No description provided for @joinedLabel.
  ///
  /// In en, this message translates to:
  /// **'Joined:'**
  String get joinedLabel;

  /// No description provided for @roleLabel.
  ///
  /// In en, this message translates to:
  /// **'Role:'**
  String get roleLabel;

  /// No description provided for @unbanConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to unban user \"{username}\"?'**
  String unbanConfirmMessage(String username);

  /// No description provided for @adminLoginAsAuditLogWarning.
  ///
  /// In en, this message translates to:
  /// **'This operation will log in as the selected user and leave an audit log. Continue?'**
  String get adminLoginAsAuditLogWarning;

  /// No description provided for @impersonationFailed.
  ///
  /// In en, this message translates to:
  /// **'Impersonation failed: {error}'**
  String impersonationFailed(String error);

  /// No description provided for @infoDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'This product is for information publishing only, with no guarantee, no fund intermediary, and no transaction fees.'**
  String get infoDisclaimer;

  /// No description provided for @aboutPlatform.
  ///
  /// In en, this message translates to:
  /// **'About This Platform'**
  String get aboutPlatform;

  /// No description provided for @aboutPlatformSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How this platform works and key safety notice.'**
  String get aboutPlatformSubtitle;

  /// No description provided for @infoPublishing.
  ///
  /// In en, this message translates to:
  /// **'Information Publishing'**
  String get infoPublishing;

  /// No description provided for @infoPublishingDesc.
  ///
  /// In en, this message translates to:
  /// **'This platform is for information publishing only. Users share listing information through posts. No transactions or payments occur on this platform.'**
  String get infoPublishingDesc;

  /// No description provided for @contactThroughChat.
  ///
  /// In en, this message translates to:
  /// **'Contact Through Chat'**
  String get contactThroughChat;

  /// No description provided for @contactThroughChatDesc.
  ///
  /// In en, this message translates to:
  /// **'Contact sellers directly through the in-app chat feature. Communicate details and arrange transactions offline.'**
  String get contactThroughChatDesc;

  /// No description provided for @safetyTips.
  ///
  /// In en, this message translates to:
  /// **'Safety Tips'**
  String get safetyTips;

  /// No description provided for @safetyTipsDesc.
  ///
  /// In en, this message translates to:
  /// **'Meet in safe public places when exchanging items. Verify item condition before completing any offline arrangement.'**
  String get safetyTipsDesc;

  /// No description provided for @platformDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'This platform serves as an information listing service only. Any offline transactions are at your own risk. Please stay vigilant and protect your personal safety and property.'**
  String get platformDisclaimer;

  /// No description provided for @recommendedForYou.
  ///
  /// In en, this message translates to:
  /// **'For You'**
  String get recommendedForYou;

  /// No description provided for @similarRecommendations.
  ///
  /// In en, this message translates to:
  /// **'Similar Items'**
  String get similarRecommendations;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @gallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get gallery;

  /// No description provided for @uploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading'**
  String get uploading;

  /// No description provided for @avatarUpdated.
  ///
  /// In en, this message translates to:
  /// **'Avatar updated'**
  String get avatarUpdated;

  /// No description provided for @uploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get uploadFailed;

  /// No description provided for @emailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailLabel;

  /// No description provided for @emailChange.
  ///
  /// In en, this message translates to:
  /// **'Change Email'**
  String get emailChange;

  /// No description provided for @emailChangeHint.
  ///
  /// In en, this message translates to:
  /// **'Enter @email.ncu.edu.cn email'**
  String get emailChangeHint;

  /// No description provided for @emailDomainError.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid campus email address'**
  String get emailDomainError;

  /// No description provided for @emailChangeSuccess.
  ///
  /// In en, this message translates to:
  /// **'Email updated'**
  String get emailChangeSuccess;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @homeHeroEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Goods4ncu Campus Market'**
  String get homeHeroEyebrow;

  /// No description provided for @homeHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'What are you looking for today?'**
  String get homeHeroTitle;

  /// No description provided for @homeHeroSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tell Xiaobang what you need, your budget, or how you plan to use it. You can also keep scrolling through what classmates just listed.'**
  String get homeHeroSubtitle;

  /// No description provided for @homePromptHint.
  ///
  /// In en, this message translates to:
  /// **'Find textbooks, lightweight laptops, or ask Xiaobang to help sell an item...'**
  String get homePromptHint;

  /// No description provided for @homePromptSubmitTooltip.
  ///
  /// In en, this message translates to:
  /// **'Ask Xiaobang'**
  String get homePromptSubmitTooltip;

  /// No description provided for @homeSuggestionTitle.
  ///
  /// In en, this message translates to:
  /// **'Try starting with'**
  String get homeSuggestionTitle;

  /// No description provided for @homeThoughtLaptopLabel.
  ///
  /// In en, this message translates to:
  /// **'Find a laptop'**
  String get homeThoughtLaptopLabel;

  /// No description provided for @homeThoughtLaptopPrompt.
  ///
  /// In en, this message translates to:
  /// **'My budget is 3000 yuan. Help me find a lightweight laptop for coding and carrying to class.'**
  String get homeThoughtLaptopPrompt;

  /// No description provided for @homeThoughtPriceLabel.
  ///
  /// In en, this message translates to:
  /// **'Price my item'**
  String get homeThoughtPriceLabel;

  /// No description provided for @homeThoughtPricePrompt.
  ///
  /// In en, this message translates to:
  /// **'I have an unused item to sell. Ask me a few questions first, then estimate a fair price.'**
  String get homeThoughtPricePrompt;

  /// No description provided for @homeThoughtCopyLabel.
  ///
  /// In en, this message translates to:
  /// **'Write listing copy'**
  String get homeThoughtCopyLabel;

  /// No description provided for @homeThoughtCopyPrompt.
  ///
  /// In en, this message translates to:
  /// **'Help me organize the item details step by step and write an honest, trustworthy listing.'**
  String get homeThoughtCopyPrompt;

  /// No description provided for @homeThoughtNegotiateLabel.
  ///
  /// In en, this message translates to:
  /// **'Negotiate politely'**
  String get homeThoughtNegotiateLabel;

  /// No description provided for @homeThoughtNegotiatePrompt.
  ///
  /// In en, this message translates to:
  /// **'Help me find worthwhile digital items and start a polite negotiation when the price makes sense.'**
  String get homeThoughtNegotiatePrompt;

  /// No description provided for @homeRecentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently Listed'**
  String get homeRecentTitle;

  /// No description provided for @homeRecentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'See what classmates are selling right now.'**
  String get homeRecentSubtitle;

  /// No description provided for @conversationLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Messages could not load'**
  String get conversationLoadFailedTitle;

  /// No description provided for @conversationEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get conversationEmptyTitle;

  /// No description provided for @conversationEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Answer someone in \"what people are looking for\" and you\'ll have your first conversation.'**
  String get conversationEmptySubtitle;

  /// No description provided for @conversationEmptyAction.
  ///
  /// In en, this message translates to:
  /// **'See what people are looking for'**
  String get conversationEmptyAction;

  /// No description provided for @findClassmate.
  ///
  /// In en, this message translates to:
  /// **'Find classmate'**
  String get findClassmate;

  /// No description provided for @conversationWaitingCount.
  ///
  /// In en, this message translates to:
  /// **'Awaiting your reply · {count}'**
  String conversationWaitingCount(int count);

  /// No description provided for @conversationFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get conversationFilterAll;

  /// No description provided for @conversationFilterRealtime.
  ///
  /// In en, this message translates to:
  /// **'Realtime'**
  String get conversationFilterRealtime;

  /// No description provided for @conversationFilterMail.
  ///
  /// In en, this message translates to:
  /// **'Mail'**
  String get conversationFilterMail;

  /// No description provided for @lookupDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Find classmate'**
  String get lookupDialogTitle;

  /// No description provided for @lookupDialogSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter a username, full email, or student ID. If they turned off that discovery method, they will not appear here.'**
  String get lookupDialogSubtitle;

  /// No description provided for @lookupFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Search value'**
  String get lookupFieldLabel;

  /// No description provided for @lookupFieldHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Alex / 2024123456 / name@email.ncu.edu.cn'**
  String get lookupFieldHint;

  /// No description provided for @lookupMethodLabel.
  ///
  /// In en, this message translates to:
  /// **'Search by'**
  String get lookupMethodLabel;

  /// No description provided for @lookupMethodAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto detect'**
  String get lookupMethodAuto;

  /// No description provided for @lookupMethodUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get lookupMethodUsername;

  /// No description provided for @lookupMethodStudentId.
  ///
  /// In en, this message translates to:
  /// **'Student ID'**
  String get lookupMethodStudentId;

  /// No description provided for @lookupMethodEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get lookupMethodEmail;

  /// No description provided for @lookupSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get lookupSearchAction;

  /// No description provided for @lookupHint.
  ///
  /// In en, this message translates to:
  /// **'Tip: email and student ID must be entered fully. Whether someone can be found is controlled by their settings.'**
  String get lookupHint;

  /// No description provided for @lookupEmpty.
  ///
  /// In en, this message translates to:
  /// **'No contactable user found. The input may be incomplete, or the other user may not have enabled this discovery method.'**
  String get lookupEmpty;

  /// No description provided for @lookupMatchedWithListings.
  ///
  /// In en, this message translates to:
  /// **'Matched by {method} · {count} active listings'**
  String lookupMatchedWithListings(String method, int count);

  /// No description provided for @lookupMatchedIdentifierWithListings.
  ///
  /// In en, this message translates to:
  /// **'Matched by {method}: {identifier} · {count} active listings'**
  String lookupMatchedIdentifierWithListings(
    String method,
    String identifier,
    int count,
  );

  /// No description provided for @viewClassmateListings.
  ///
  /// In en, this message translates to:
  /// **'View listings'**
  String get viewClassmateListings;

  /// No description provided for @contactAction.
  ///
  /// In en, this message translates to:
  /// **'Contact'**
  String get contactAction;

  /// No description provided for @classmateActiveListingsTitle.
  ///
  /// In en, this message translates to:
  /// **'{username}\'s listings'**
  String classmateActiveListingsTitle(String username);

  /// No description provided for @classmateListingsLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Listings could not load'**
  String get classmateListingsLoadFailedTitle;

  /// No description provided for @classmateListingsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No active listings'**
  String get classmateListingsEmptyTitle;

  /// No description provided for @classmateListingsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'This user does not have public active listings right now.'**
  String get classmateListingsEmptySubtitle;

  /// No description provided for @unnamedListing.
  ///
  /// In en, this message translates to:
  /// **'Untitled listing'**
  String get unnamedListing;

  /// No description provided for @listingPriceLine.
  ///
  /// In en, this message translates to:
  /// **'{category} · ¥{price}'**
  String listingPriceLine(String category, String price);

  /// No description provided for @assistantName.
  ///
  /// In en, this message translates to:
  /// **'Xiaobang'**
  String get assistantName;

  /// No description provided for @assistantSystemBadge.
  ///
  /// In en, this message translates to:
  /// **'AI Assistant'**
  String get assistantSystemBadge;

  /// No description provided for @assistantInboxSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Find items, price, publish, and negotiate from here'**
  String get assistantInboxSubtitle;

  /// No description provided for @assistantHeaderSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your campus trading assistant · important decisions ask for your confirmation first'**
  String get assistantHeaderSubtitle;

  /// No description provided for @assistantHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'History could not load. You can still keep asking Xiaobang.'**
  String get assistantHistoryLoadFailed;

  /// No description provided for @assistantTyping.
  ///
  /// In en, this message translates to:
  /// **'AI is typing...'**
  String get assistantTyping;

  /// No description provided for @recordingStatus.
  ///
  /// In en, this message translates to:
  /// **'Recording {seconds}s / 60s'**
  String recordingStatus(int seconds);

  /// No description provided for @viewAction.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get viewAction;

  /// No description provided for @invitationFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Wants to chat with you now'**
  String get invitationFallbackTitle;

  /// No description provided for @declineNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get declineNow;

  /// No description provided for @connectNow.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectNow;

  /// No description provided for @modeRealtime.
  ///
  /// In en, this message translates to:
  /// **'Realtime'**
  String get modeRealtime;

  /// No description provided for @modeMail.
  ///
  /// In en, this message translates to:
  /// **'Mail'**
  String get modeMail;

  /// No description provided for @conversationStateDelivered.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get conversationStateDelivered;

  /// No description provided for @conversationStateSynSent.
  ///
  /// In en, this message translates to:
  /// **'Waiting for them to connect'**
  String get conversationStateSynSent;

  /// No description provided for @conversationStateSynAck.
  ///
  /// In en, this message translates to:
  /// **'They replied, waiting for confirmation'**
  String get conversationStateSynAck;

  /// No description provided for @conversationStateActive.
  ///
  /// In en, this message translates to:
  /// **'This conversation is connected'**
  String get conversationStateActive;

  /// No description provided for @conversationStateDeclined.
  ///
  /// In en, this message translates to:
  /// **'This time did not connect'**
  String get conversationStateDeclined;

  /// No description provided for @conversationStateCancelled.
  ///
  /// In en, this message translates to:
  /// **'Invitation cancelled'**
  String get conversationStateCancelled;

  /// No description provided for @conversationStateExpired.
  ///
  /// In en, this message translates to:
  /// **'This conversation has ended'**
  String get conversationStateExpired;

  /// No description provided for @conversationStateClosed.
  ///
  /// In en, this message translates to:
  /// **'This conversation is closed'**
  String get conversationStateClosed;

  /// No description provided for @conversationChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a conversation'**
  String get conversationChooseTitle;

  /// No description provided for @conversationChooseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Realtime conversations and mail threads stay clearly separated here.'**
  String get conversationChooseSubtitle;

  /// No description provided for @contactModePromptTitle.
  ///
  /// In en, this message translates to:
  /// **'How would you like to reach out?'**
  String get contactModePromptTitle;

  /// No description provided for @contactContextUser.
  ///
  /// In en, this message translates to:
  /// **'Contact {username}'**
  String contactContextUser(String username);

  /// No description provided for @contactContextListing.
  ///
  /// In en, this message translates to:
  /// **'About \"{title}\"'**
  String contactContextListing(String title);

  /// No description provided for @contactFallbackUser.
  ///
  /// In en, this message translates to:
  /// **'this classmate'**
  String get contactFallbackUser;

  /// No description provided for @contactModeRealtimeTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat now'**
  String get contactModeRealtimeTitle;

  /// No description provided for @contactModeRealtimeDescription.
  ///
  /// In en, this message translates to:
  /// **'Send a 10-minute realtime invite. The conversation starts once they connect.'**
  String get contactModeRealtimeDescription;

  /// No description provided for @contactModeMailTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave a message'**
  String get contactModeMailTitle;

  /// No description provided for @contactModeMailDescription.
  ///
  /// In en, this message translates to:
  /// **'Send it directly without online, typing, or read indicators.'**
  String get contactModeMailDescription;

  /// No description provided for @contactOpeningRequired.
  ///
  /// In en, this message translates to:
  /// **'Please write what you want to say first.'**
  String get contactOpeningRequired;

  /// No description provided for @contactMailSubjectRequired.
  ///
  /// In en, this message translates to:
  /// **'Mail needs a subject.'**
  String get contactMailSubjectRequired;

  /// No description provided for @contactRealtimeComposerTitle.
  ///
  /// In en, this message translates to:
  /// **'Start a realtime invite'**
  String get contactRealtimeComposerTitle;

  /// No description provided for @contactMailComposerTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave a message'**
  String get contactMailComposerTitle;

  /// No description provided for @contactMailSubjectLabel.
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get contactMailSubjectLabel;

  /// No description provided for @contactMailSubjectHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Asking about condition'**
  String get contactMailSubjectHint;

  /// No description provided for @contactMailBodyLabel.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get contactMailBodyLabel;

  /// No description provided for @contactRealtimeOpeningLabel.
  ///
  /// In en, this message translates to:
  /// **'They will see this before connecting'**
  String get contactRealtimeOpeningLabel;

  /// No description provided for @contactMailBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Share your question and when it is convenient to reply...'**
  String get contactMailBodyHint;

  /// No description provided for @contactRealtimeOpeningHint.
  ///
  /// In en, this message translates to:
  /// **'Hi, is this item still available?'**
  String get contactRealtimeOpeningHint;

  /// No description provided for @contactMailSubmit.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get contactMailSubmit;

  /// No description provided for @contactRealtimeSubmit.
  ///
  /// In en, this message translates to:
  /// **'Wait for them to connect'**
  String get contactRealtimeSubmit;

  /// No description provided for @publicProfile.
  ///
  /// In en, this message translates to:
  /// **'Classmate Profile'**
  String get publicProfile;

  /// No description provided for @myPublicProfile.
  ///
  /// In en, this message translates to:
  /// **'My public profile'**
  String get myPublicProfile;

  /// No description provided for @myPublicProfileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Preview how others see your profile.'**
  String get myPublicProfileSubtitle;

  /// No description provided for @viewPublicProfile.
  ///
  /// In en, this message translates to:
  /// **'View profile'**
  String get viewPublicProfile;

  /// No description provided for @publicProfileLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Profile could not load'**
  String get publicProfileLoadFailed;

  /// No description provided for @publicProfileListingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Active listings'**
  String get publicProfileListingsTitle;

  /// No description provided for @publicProfileListingsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No active listings right now.'**
  String get publicProfileListingsEmpty;

  /// No description provided for @paymentQrSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Offline payment QR codes'**
  String get paymentQrSectionTitle;

  /// No description provided for @paymentQrSectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shown only when the user chooses to make them public. The platform does not process, verify, or escrow payments.'**
  String get paymentQrSectionSubtitle;

  /// No description provided for @paymentQrPublicNotice.
  ///
  /// In en, this message translates to:
  /// **'Use only after you have confirmed the item and seller. Offline payments are arranged between users.'**
  String get paymentQrPublicNotice;

  /// No description provided for @wechatPayQr.
  ///
  /// In en, this message translates to:
  /// **'WeChat Pay'**
  String get wechatPayQr;

  /// No description provided for @alipayQr.
  ///
  /// In en, this message translates to:
  /// **'Alipay'**
  String get alipayQr;

  /// No description provided for @paymentQrSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Payment QR codes'**
  String get paymentQrSettingsTitle;

  /// No description provided for @paymentQrSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Optional. These are displayed on your public profile only after you turn them on.'**
  String get paymentQrSettingsSubtitle;

  /// No description provided for @uploadWechatQr.
  ///
  /// In en, this message translates to:
  /// **'Upload WeChat Pay code'**
  String get uploadWechatQr;

  /// No description provided for @uploadAlipayQr.
  ///
  /// In en, this message translates to:
  /// **'Upload Alipay code'**
  String get uploadAlipayQr;

  /// No description provided for @showWechatQr.
  ///
  /// In en, this message translates to:
  /// **'Show WeChat Pay code'**
  String get showWechatQr;

  /// No description provided for @showAlipayQr.
  ///
  /// In en, this message translates to:
  /// **'Show Alipay code'**
  String get showAlipayQr;

  /// No description provided for @paymentQrUpdated.
  ///
  /// In en, this message translates to:
  /// **'Payment QR settings updated'**
  String get paymentQrUpdated;

  /// No description provided for @paymentQrCleared.
  ///
  /// In en, this message translates to:
  /// **'Payment QR code removed'**
  String get paymentQrCleared;

  /// No description provided for @paymentQrMissingHint.
  ///
  /// In en, this message translates to:
  /// **'Upload a QR code before turning on public display.'**
  String get paymentQrMissingHint;

  /// No description provided for @paymentQrSafetyHint.
  ///
  /// In en, this message translates to:
  /// **'The platform only displays your image and will not confirm whether anyone has paid.'**
  String get paymentQrSafetyHint;

  /// No description provided for @createDealIntent.
  ///
  /// In en, this message translates to:
  /// **'Start deal intent'**
  String get createDealIntent;

  /// No description provided for @dealIntentSent.
  ///
  /// In en, this message translates to:
  /// **'Deal intent sent. Waiting for seller confirmation.'**
  String get dealIntentSent;

  /// No description provided for @platformNoEscrowShort.
  ///
  /// In en, this message translates to:
  /// **'The platform only records offline deal intent. It does not escrow funds or verify payment or handoff. Please confirm inspection, exchange, and payment in chat.'**
  String get platformNoEscrowShort;

  /// No description provided for @awaitingSellerConfirm.
  ///
  /// In en, this message translates to:
  /// **'Waiting for seller confirmation'**
  String get awaitingSellerConfirm;

  /// No description provided for @dealConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Offline deal confirmed'**
  String get dealConfirmed;

  /// No description provided for @dealCancelled.
  ///
  /// In en, this message translates to:
  /// **'Deal record cancelled'**
  String get dealCancelled;

  /// No description provided for @confirmOfflineDeal.
  ///
  /// In en, this message translates to:
  /// **'Confirm deal'**
  String get confirmOfflineDeal;

  /// No description provided for @autoDelistAfterConfirm.
  ///
  /// In en, this message translates to:
  /// **'Auto-delist item after confirmation'**
  String get autoDelistAfterConfirm;

  /// No description provided for @autoDelistAfterConfirmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Best for one-off used items. Turn it off if you want the listing to keep receiving intents.'**
  String get autoDelistAfterConfirmSubtitle;

  /// No description provided for @dealIntentCreated.
  ///
  /// In en, this message translates to:
  /// **'Buyer started deal intent'**
  String get dealIntentCreated;

  /// No description provided for @sellerConfirmedDeal.
  ///
  /// In en, this message translates to:
  /// **'Seller confirmed deal'**
  String get sellerConfirmedDeal;

  /// No description provided for @itemAutoDelisted.
  ///
  /// In en, this message translates to:
  /// **'Item auto-delisted'**
  String get itemAutoDelisted;

  /// No description provided for @listingStatus.
  ///
  /// In en, this message translates to:
  /// **'Listing status'**
  String get listingStatus;

  /// No description provided for @chatReadReceiptSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat read receipts'**
  String get chatReadReceiptSettingsTitle;

  /// No description provided for @chatReadReceiptDefaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Default read behavior'**
  String get chatReadReceiptDefaultTitle;

  /// No description provided for @chatReadReceiptAutoTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto read'**
  String get chatReadReceiptAutoTitle;

  /// No description provided for @chatReadReceiptManualTitle.
  ///
  /// In en, this message translates to:
  /// **'Manual read'**
  String get chatReadReceiptManualTitle;

  /// No description provided for @chatReadReceiptAutoSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mark received messages as read when you open an active realtime chat.'**
  String get chatReadReceiptAutoSubtitle;

  /// No description provided for @chatReadReceiptManualSubtitle.
  ///
  /// In en, this message translates to:
  /// **'They only see read after you tap \"Mark read\".'**
  String get chatReadReceiptManualSubtitle;

  /// No description provided for @chatReadReceiptAutoCurrent.
  ///
  /// In en, this message translates to:
  /// **'Auto: opening an active realtime chat marks messages as read.'**
  String get chatReadReceiptAutoCurrent;

  /// No description provided for @chatReadReceiptManualCurrent.
  ///
  /// In en, this message translates to:
  /// **'Manual: opening chat does not automatically show read receipts.'**
  String get chatReadReceiptManualCurrent;

  /// No description provided for @chatReadReceiptUpdated.
  ///
  /// In en, this message translates to:
  /// **'Chat read receipt setting updated'**
  String get chatReadReceiptUpdated;

  /// No description provided for @markConversationRead.
  ///
  /// In en, this message translates to:
  /// **'Mark read'**
  String get markConversationRead;

  /// No description provided for @markConversationReadSuccess.
  ///
  /// In en, this message translates to:
  /// **'Marked as read'**
  String get markConversationReadSuccess;

  /// No description provided for @manualReadUnreadOne.
  ///
  /// In en, this message translates to:
  /// **'Unread messages are waiting; manual read is on'**
  String get manualReadUnreadOne;

  /// No description provided for @manualReadUnreadMany.
  ///
  /// In en, this message translates to:
  /// **'{count} unread messages; manual read is on'**
  String manualReadUnreadMany(int count);

  /// No description provided for @readPreferenceUpdated.
  ///
  /// In en, this message translates to:
  /// **'Read preference updated'**
  String get readPreferenceUpdated;

  /// No description provided for @readPreferenceInherit.
  ///
  /// In en, this message translates to:
  /// **'Read receipts: inherit default'**
  String get readPreferenceInherit;

  /// No description provided for @readPreferenceAuto.
  ///
  /// In en, this message translates to:
  /// **'Read receipts: auto'**
  String get readPreferenceAuto;

  /// No description provided for @readPreferenceManual.
  ///
  /// In en, this message translates to:
  /// **'Read receipts: manual'**
  String get readPreferenceManual;

  /// No description provided for @selectedSuffix.
  ///
  /// In en, this message translates to:
  /// **' ✓'**
  String get selectedSuffix;

  /// No description provided for @quoteListing.
  ///
  /// In en, this message translates to:
  /// **'Listing'**
  String get quoteListing;

  /// No description provided for @quoteOrder.
  ///
  /// In en, this message translates to:
  /// **'Deal record'**
  String get quoteOrder;

  /// No description provided for @quoteHitlOffer.
  ///
  /// In en, this message translates to:
  /// **'Negotiation'**
  String get quoteHitlOffer;

  /// No description provided for @quoteGeneric.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get quoteGeneric;

  /// No description provided for @discoverabilitySettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'How others can find me'**
  String get discoverabilitySettingsTitle;

  /// No description provided for @discoverByUsernameTitle.
  ///
  /// In en, this message translates to:
  /// **'Find me by username'**
  String get discoverByUsernameTitle;

  /// No description provided for @discoverByUsernameSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, others cannot find you by username. Required display in listings and existing conversations is not affected.'**
  String get discoverByUsernameSubtitle;

  /// No description provided for @discoverByEmailTitle.
  ///
  /// In en, this message translates to:
  /// **'Find me by email'**
  String get discoverByEmailTitle;

  /// No description provided for @discoverByEmailMissingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set a campus email first, then choose whether others can find you by entering the full email.'**
  String get discoverByEmailMissingSubtitle;

  /// No description provided for @discoverByEmailSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Current email: {email}. When enabled, others must enter the full email to find you.'**
  String discoverByEmailSubtitle(String email);

  /// No description provided for @discoverByStudentIdTitle.
  ///
  /// In en, this message translates to:
  /// **'Find me by student ID'**
  String get discoverByStudentIdTitle;

  /// No description provided for @discoverByStudentIdSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Student ID inferred from email: {studentId}. When enabled, others must enter the full student ID to find you.'**
  String discoverByStudentIdSubtitle(String studentId);

  /// No description provided for @discoverByStudentIdMissingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The current email does not reveal a student ID. Use a campus email that starts with 8-12 digits.'**
  String get discoverByStudentIdMissingSubtitle;

  /// No description provided for @discoverabilityUpdated.
  ///
  /// In en, this message translates to:
  /// **'Discovery settings updated'**
  String get discoverabilityUpdated;

  /// No description provided for @settingsUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Settings update failed: {error}'**
  String settingsUpdateFailed(String error);

  /// No description provided for @conversationSectionDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct messages'**
  String get conversationSectionDirect;

  /// No description provided for @conversationSectionSpaces.
  ///
  /// In en, this message translates to:
  /// **'Campus groups and channels'**
  String get conversationSectionSpaces;

  /// No description provided for @conversationSectionTools.
  ///
  /// In en, this message translates to:
  /// **'Xiaobang'**
  String get conversationSectionTools;

  /// No description provided for @conversationCreateGroupSuccess.
  ///
  /// In en, this message translates to:
  /// **'Group created and added to Messages'**
  String get conversationCreateGroupSuccess;

  /// No description provided for @conversationCreateChannelSuccess.
  ///
  /// In en, this message translates to:
  /// **'Channel created and added to Messages'**
  String get conversationCreateChannelSuccess;

  /// No description provided for @conversationCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'Create failed: {error}'**
  String conversationCreateFailed(String error);

  /// No description provided for @conversationPeerFallback.
  ///
  /// In en, this message translates to:
  /// **'Classmate'**
  String get conversationPeerFallback;

  /// No description provided for @conversationThreadLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading thread'**
  String get conversationThreadLoading;

  /// No description provided for @conversationThreadStats.
  ///
  /// In en, this message translates to:
  /// **'Realtime {realtime} · Mail {mail} · {count} segments'**
  String conversationThreadStats(int realtime, int mail, int count);

  /// No description provided for @conversationReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get conversationReconnect;

  /// No description provided for @conversationThreadLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Contact thread could not load'**
  String get conversationThreadLoadFailedTitle;

  /// No description provided for @conversationThreadEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No visible conversation history yet'**
  String get conversationThreadEmptyTitle;

  /// No description provided for @conversationThreadEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to start a new realtime chat or mail thread.'**
  String get conversationThreadEmptySubtitle;

  /// No description provided for @conversationMailThreadTitle.
  ///
  /// In en, this message translates to:
  /// **'Mail thread'**
  String get conversationMailThreadTitle;

  /// No description provided for @conversationRealtimeThreadTitle.
  ///
  /// In en, this message translates to:
  /// **'Realtime session'**
  String get conversationRealtimeThreadTitle;

  /// No description provided for @conversationSegmentHistoryHint.
  ///
  /// In en, this message translates to:
  /// **'This segment is kept as history. Start a new conversation when you need to continue.'**
  String get conversationSegmentHistoryHint;

  /// No description provided for @conversationSegmentOpenHint.
  ///
  /// In en, this message translates to:
  /// **'Open this segment to view messages, reply, quote context, or handle connection state.'**
  String get conversationSegmentOpenHint;

  /// No description provided for @conversationViewHistory.
  ///
  /// In en, this message translates to:
  /// **'View history'**
  String get conversationViewHistory;

  /// No description provided for @conversationOpenSegment.
  ///
  /// In en, this message translates to:
  /// **'Open this segment'**
  String get conversationOpenSegment;

  /// No description provided for @conversationPendingCount.
  ///
  /// In en, this message translates to:
  /// **'Pending {count}'**
  String conversationPendingCount(int count);

  /// No description provided for @conversationTimelineFallback.
  ///
  /// In en, this message translates to:
  /// **'View conversation timeline'**
  String get conversationTimelineFallback;

  /// No description provided for @relationshipSpaceTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared space'**
  String get relationshipSpaceTitle;

  /// No description provided for @relationshipSpaceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep history while asynchronous; show only explicit connection state when connected.'**
  String get relationshipSpaceSubtitle;

  /// No description provided for @relationshipSpaceMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get relationshipSpaceMe;

  /// No description provided for @relationshipSpaceAsync.
  ///
  /// In en, this message translates to:
  /// **'Leave a message'**
  String get relationshipSpaceAsync;

  /// No description provided for @relationshipSpaceConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get relationshipSpaceConnected;

  /// No description provided for @relationshipSpaceTimeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get relationshipSpaceTimeline;

  /// No description provided for @relationshipSpaceNoEvent.
  ///
  /// In en, this message translates to:
  /// **'No shared events yet'**
  String get relationshipSpaceNoEvent;

  /// No description provided for @relationshipSpacePin.
  ///
  /// In en, this message translates to:
  /// **'Pin to shared space'**
  String get relationshipSpacePin;

  /// No description provided for @relationshipSpaceUnpin.
  ///
  /// In en, this message translates to:
  /// **'Remove from shared space'**
  String get relationshipSpaceUnpin;

  /// No description provided for @relationshipSpacePinsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} pins'**
  String relationshipSpacePinsCount(int count);

  /// No description provided for @relationshipSpaceObjectsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} shared objects'**
  String relationshipSpaceObjectsCount(int count);

  /// No description provided for @relationshipSpaceSharedObjectsTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared objects'**
  String get relationshipSpaceSharedObjectsTitle;

  /// No description provided for @relationshipSpaceSharedObjectsReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-only references; original facts stay authoritative'**
  String get relationshipSpaceSharedObjectsReadOnly;

  /// No description provided for @relationshipSpaceObjectFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get relationshipSpaceObjectFile;

  /// No description provided for @relationshipSpaceObjectLink.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get relationshipSpaceObjectLink;

  /// No description provided for @relationshipSpaceObjectReference.
  ///
  /// In en, this message translates to:
  /// **'Reference'**
  String get relationshipSpaceObjectReference;

  /// No description provided for @conversationRealtimeCount.
  ///
  /// In en, this message translates to:
  /// **'Realtime {count}'**
  String conversationRealtimeCount(int count);

  /// No description provided for @conversationMailCount.
  ///
  /// In en, this message translates to:
  /// **'Mail {count}'**
  String conversationMailCount(int count);

  /// No description provided for @conversationSegmentCount.
  ///
  /// In en, this message translates to:
  /// **'{count} segments'**
  String conversationSegmentCount(int count);

  /// No description provided for @createGroup.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get createGroup;

  /// No description provided for @createChannel.
  ///
  /// In en, this message translates to:
  /// **'Create channel'**
  String get createChannel;

  /// No description provided for @spaceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get spaceNameLabel;

  /// No description provided for @spaceDescriptionOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get spaceDescriptionOptionalLabel;

  /// No description provided for @createAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get createAction;

  /// No description provided for @unnamedSpace.
  ///
  /// In en, this message translates to:
  /// **'Unnamed space'**
  String get unnamedSpace;

  /// No description provided for @spaceFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Campus group'**
  String get spaceFallbackTitle;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @spaceLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Space could not load'**
  String get spaceLoadFailedTitle;

  /// No description provided for @spaceNotFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Space not found'**
  String get spaceNotFoundTitle;

  /// No description provided for @spaceNotFoundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'It may have been deleted, or you may not be a member.'**
  String get spaceNotFoundSubtitle;

  /// No description provided for @spaceSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String spaceSendFailed(String error);

  /// No description provided for @spaceMembersRoleLine.
  ///
  /// In en, this message translates to:
  /// **'{count} members · My role {role}'**
  String spaceMembersRoleLine(int count, String role);

  /// No description provided for @spaceMessagesLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Space messages could not load'**
  String get spaceMessagesLoadFailedTitle;

  /// No description provided for @spaceChannelCreatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Channel created'**
  String get spaceChannelCreatedTitle;

  /// No description provided for @spaceGroupCreatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Group created'**
  String get spaceGroupCreatedTitle;

  /// No description provided for @spaceChannelEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Announcements will appear here. Channel members can read, react, and report.'**
  String get spaceChannelEmptySubtitle;

  /// No description provided for @spaceGroupEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'It is now in Messages. Send the first note to bring the group to life.'**
  String get spaceGroupEmptySubtitle;

  /// No description provided for @replyAction.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get replyAction;

  /// No description provided for @replyPreviewMissing.
  ///
  /// In en, this message translates to:
  /// **'Replied to message #{messageId}'**
  String replyPreviewMissing(int messageId);

  /// No description provided for @spaceChannelReadOnlyNotice.
  ///
  /// In en, this message translates to:
  /// **'You are a channel member. You can read, react, and report; only channel owners/admins can post announcements.'**
  String get spaceChannelReadOnlyNotice;

  /// No description provided for @cancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get cancelReply;

  /// No description provided for @channelComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Post an announcement...'**
  String get channelComposerHint;

  /// No description provided for @groupComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Send a group message...'**
  String get groupComposerHint;

  /// No description provided for @spaceFallbackDescription.
  ///
  /// In en, this message translates to:
  /// **'{count} members · {kind}'**
  String spaceFallbackDescription(int count, String kind);

  /// No description provided for @spaceKindChannelLong.
  ///
  /// In en, this message translates to:
  /// **'Announcement channel'**
  String get spaceKindChannelLong;

  /// No description provided for @spaceKindGroupLong.
  ///
  /// In en, this message translates to:
  /// **'Campus group'**
  String get spaceKindGroupLong;

  /// No description provided for @spaceKindChannel.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get spaceKindChannel;

  /// No description provided for @spaceKindGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get spaceKindGroup;

  /// No description provided for @spaceRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get spaceRoleOwner;

  /// No description provided for @spaceRoleAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get spaceRoleAdmin;

  /// No description provided for @spaceRoleBanned.
  ///
  /// In en, this message translates to:
  /// **'Restricted'**
  String get spaceRoleBanned;

  /// No description provided for @spaceRoleMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get spaceRoleMember;

  /// No description provided for @chatAcceptedLegacy.
  ///
  /// In en, this message translates to:
  /// **'Connection accepted'**
  String get chatAcceptedLegacy;

  /// No description provided for @chatAcceptFailed.
  ///
  /// In en, this message translates to:
  /// **'Accept failed: {error}'**
  String chatAcceptFailed(String error);

  /// No description provided for @chatRejectedLegacy.
  ///
  /// In en, this message translates to:
  /// **'Connection rejected'**
  String get chatRejectedLegacy;

  /// No description provided for @chatRejectFailed.
  ///
  /// In en, this message translates to:
  /// **'Reject failed: {error}'**
  String chatRejectFailed(String error);

  /// No description provided for @replyingToMessage.
  ///
  /// In en, this message translates to:
  /// **'Replying to this message'**
  String get replyingToMessage;

  /// No description provided for @reactionFailed.
  ///
  /// In en, this message translates to:
  /// **'Reaction failed: {error}'**
  String reactionFailed(String error);

  /// No description provided for @hideMessageDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete from my chat history?'**
  String get hideMessageDialogTitle;

  /// No description provided for @hideMessageDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This only hides the message for you. The other person can still see it.'**
  String get hideMessageDialogBody;

  /// No description provided for @deleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteAction;

  /// No description provided for @messageHiddenForMe.
  ///
  /// In en, this message translates to:
  /// **'Hidden from your chat history'**
  String get messageHiddenForMe;

  /// No description provided for @messageHideFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String messageHideFailed(String error);

  /// No description provided for @reportMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Report this message'**
  String get reportMessageTitle;

  /// No description provided for @reportListingAction.
  ///
  /// In en, this message translates to:
  /// **'Report listing'**
  String get reportListingAction;

  /// No description provided for @reportUserAction.
  ///
  /// In en, this message translates to:
  /// **'Report user'**
  String get reportUserAction;

  /// No description provided for @reportListingTitle.
  ///
  /// In en, this message translates to:
  /// **'Report this listing'**
  String get reportListingTitle;

  /// No description provided for @reportUserTitle.
  ///
  /// In en, this message translates to:
  /// **'Report this user'**
  String get reportUserTitle;

  /// No description provided for @reportReasonDefault.
  ///
  /// In en, this message translates to:
  /// **'Inappropriate content'**
  String get reportReasonDefault;

  /// No description provided for @reportReasonLabel.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get reportReasonLabel;

  /// No description provided for @reportReasonRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a reason'**
  String get reportReasonRequired;

  /// No description provided for @reportDetailsLabel.
  ///
  /// In en, this message translates to:
  /// **'Additional details (optional)'**
  String get reportDetailsLabel;

  /// No description provided for @submitAction.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get submitAction;

  /// No description provided for @acceptAction.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get acceptAction;

  /// No description provided for @rejectAction.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get rejectAction;

  /// No description provided for @reportSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Report submitted'**
  String get reportSubmitted;

  /// No description provided for @reportFailed.
  ///
  /// In en, this message translates to:
  /// **'Report failed: {error}'**
  String reportFailed(String error);

  /// No description provided for @markReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Mark read failed: {error}'**
  String markReadFailed(String error);

  /// No description provided for @readPreferenceUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Read preference update failed: {error}'**
  String readPreferenceUpdateFailed(String error);

  /// No description provided for @quoteUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This conversation has no listing, order, or negotiation context to quote.'**
  String get quoteUnavailable;

  /// No description provided for @quotePickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Quote related info'**
  String get quotePickerTitle;

  /// No description provided for @quotePickerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The server creates the fact snapshot, so price, title, and status cannot be forged by the client.'**
  String get quotePickerSubtitle;

  /// No description provided for @quoteListingFallback.
  ///
  /// In en, this message translates to:
  /// **'Listing linked to this conversation'**
  String get quoteListingFallback;

  /// No description provided for @quoteListingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Quote a snapshot of the listing title, price, condition, and cover image.'**
  String get quoteListingSubtitle;

  /// No description provided for @conversationCannotSendMessage.
  ///
  /// In en, this message translates to:
  /// **'This conversation cannot send messages right now'**
  String get conversationCannotSendMessage;

  /// No description provided for @messageSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String messageSendFailed(String error);

  /// No description provided for @replyAssistantUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Xiaobang is not ready yet. You can still type directly.'**
  String get replyAssistantUnavailable;

  /// No description provided for @closeConversationFailed.
  ///
  /// In en, this message translates to:
  /// **'End conversation failed: {error}'**
  String closeConversationFailed(String error);

  /// No description provided for @blockUserTitle.
  ///
  /// In en, this message translates to:
  /// **'Block this user?'**
  String get blockUserTitle;

  /// No description provided for @blockUserBody.
  ///
  /// In en, this message translates to:
  /// **'Neither side will be able to keep sending messages. Existing history will be preserved.'**
  String get blockUserBody;

  /// No description provided for @blockAction.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockAction;

  /// No description provided for @blockFailed.
  ///
  /// In en, this message translates to:
  /// **'Block failed: {error}'**
  String blockFailed(String error);

  /// No description provided for @callRequiresActiveConversation.
  ///
  /// In en, this message translates to:
  /// **'You can start a call after the conversation is connected.'**
  String get callRequiresActiveConversation;

  /// No description provided for @videoCallSignalSent.
  ///
  /// In en, this message translates to:
  /// **'Video call signal sent'**
  String get videoCallSignalSent;

  /// No description provided for @audioCallSignalSent.
  ///
  /// In en, this message translates to:
  /// **'Audio call signal sent'**
  String get audioCallSignalSent;

  /// No description provided for @callStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Start call failed: {error}'**
  String callStartFailed(String error);

  /// No description provided for @secretChatCreated.
  ///
  /// In en, this message translates to:
  /// **'Secret chat session created. The server only stores ciphertext endpoints.'**
  String get secretChatCreated;

  /// No description provided for @secretChatCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'Create secret chat failed: {error}'**
  String secretChatCreateFailed(String error);

  /// No description provided for @quoteListingLabel.
  ///
  /// In en, this message translates to:
  /// **'Quote listing: {title}'**
  String quoteListingLabel(String title);

  /// No description provided for @conversationFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get conversationFallbackTitle;

  /// No description provided for @conversationLoadingState.
  ///
  /// In en, this message translates to:
  /// **'Loading conversation state'**
  String get conversationLoadingState;

  /// No description provided for @conversationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This conversation is currently unavailable'**
  String get conversationUnavailable;

  /// No description provided for @conversationWaitingPeer.
  ///
  /// In en, this message translates to:
  /// **'Waiting for them to connect'**
  String get conversationWaitingPeer;

  /// No description provided for @conversationAcceptToReply.
  ///
  /// In en, this message translates to:
  /// **'Connect to reply'**
  String get conversationAcceptToReply;

  /// No description provided for @conversationCompletingHandshake.
  ///
  /// In en, this message translates to:
  /// **'Completing connection confirmation'**
  String get conversationCompletingHandshake;

  /// No description provided for @conversationDeclinedTitle.
  ///
  /// In en, this message translates to:
  /// **'This time did not connect'**
  String get conversationDeclinedTitle;

  /// No description provided for @conversationCancelledTitle.
  ///
  /// In en, this message translates to:
  /// **'Invitation cancelled'**
  String get conversationCancelledTitle;

  /// No description provided for @conversationExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'This conversation has ended'**
  String get conversationExpiredTitle;

  /// No description provided for @conversationClosedTitle.
  ///
  /// In en, this message translates to:
  /// **'This conversation is closed'**
  String get conversationClosedTitle;

  /// No description provided for @conversationReadMenuHeader.
  ///
  /// In en, this message translates to:
  /// **'Read settings · Current {mode}'**
  String conversationReadMenuHeader(String mode);

  /// No description provided for @readModeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get readModeUnknown;

  /// No description provided for @readModeManual.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get readModeManual;

  /// No description provided for @readModeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get readModeAuto;

  /// No description provided for @readModeInherit.
  ///
  /// In en, this message translates to:
  /// **'Inherit default'**
  String get readModeInherit;

  /// No description provided for @audioCallMvp.
  ///
  /// In en, this message translates to:
  /// **'Audio call MVP'**
  String get audioCallMvp;

  /// No description provided for @videoCallMvp.
  ///
  /// In en, this message translates to:
  /// **'Video call MVP'**
  String get videoCallMvp;

  /// No description provided for @secretChatMvp.
  ///
  /// In en, this message translates to:
  /// **'Secret chat MVP'**
  String get secretChatMvp;

  /// No description provided for @closeConversationAction.
  ///
  /// In en, this message translates to:
  /// **'End this conversation'**
  String get closeConversationAction;

  /// No description provided for @replyAssistantButton.
  ///
  /// In en, this message translates to:
  /// **'Ask Xiaobang'**
  String get replyAssistantButton;

  /// No description provided for @mailFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Mail'**
  String get mailFallbackTitle;

  /// No description provided for @mailProtocolSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Async sending · no online, typing, or read status'**
  String get mailProtocolSubtitle;

  /// No description provided for @incomingRealtimeTitle.
  ///
  /// In en, this message translates to:
  /// **'They want to chat now'**
  String get incomingRealtimeTitle;

  /// No description provided for @incomingRealtimeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You can choose whether to connect'**
  String get incomingRealtimeSubtitle;

  /// No description provided for @incomingRealtimeExpiring.
  ///
  /// In en, this message translates to:
  /// **'Invitation expires in {remaining}'**
  String incomingRealtimeExpiring(String remaining);

  /// No description provided for @notConvenientNow.
  ///
  /// In en, this message translates to:
  /// **'Not convenient now'**
  String get notConvenientNow;

  /// No description provided for @connectAction.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectAction;

  /// No description provided for @waitingPeerTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting for them to connect'**
  String get waitingPeerTitle;

  /// No description provided for @invitationDelivered.
  ///
  /// In en, this message translates to:
  /// **'Invitation sent'**
  String get invitationDelivered;

  /// No description provided for @timeRemaining.
  ///
  /// In en, this message translates to:
  /// **'{remaining} left'**
  String timeRemaining(String remaining);

  /// No description provided for @cancelInvitation.
  ///
  /// In en, this message translates to:
  /// **'Cancel invitation'**
  String get cancelInvitation;

  /// No description provided for @confirmingConnectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirming connection'**
  String get confirmingConnectionTitle;

  /// No description provided for @peerRespondedWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'They responded; waiting for confirmation'**
  String get peerRespondedWaitingTitle;

  /// No description provided for @confirmingConnectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You can chat after confirmation completes.'**
  String get confirmingConnectionSubtitle;

  /// No description provided for @connectionReleaseAfter.
  ///
  /// In en, this message translates to:
  /// **'This connection releases in {remaining}'**
  String connectionReleaseAfter(String remaining);

  /// No description provided for @realtimeConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation connected'**
  String get realtimeConnectedTitle;

  /// No description provided for @realtimeConnectedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You can chat in realtime now'**
  String get realtimeConnectedSubtitle;

  /// No description provided for @realtimeExpiresAfterIdle.
  ///
  /// In en, this message translates to:
  /// **'Ends after {remaining} with no new messages'**
  String realtimeExpiresAfterIdle(String remaining);

  /// No description provided for @endAction.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get endAction;

  /// No description provided for @conversationTerminalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'History is kept. Reconnecting starts a new conversation.'**
  String get conversationTerminalSubtitle;

  /// No description provided for @conversationNaturallyEndedTitle.
  ///
  /// In en, this message translates to:
  /// **'This conversation ended naturally'**
  String get conversationNaturallyEndedTitle;

  /// No description provided for @durationHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours}h {minutes}m'**
  String durationHoursMinutes(int hours, int minutes);

  /// No description provided for @connectionRequestTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection request'**
  String get connectionRequestTitle;

  /// No description provided for @offlineStatus.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offlineStatus;

  /// No description provided for @onlineStatus.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get onlineStatus;

  /// No description provided for @connectedStatus.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connectedStatus;

  /// No description provided for @pendingAcceptStatus.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get pendingAcceptStatus;

  /// No description provided for @connectingStatus.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connectingStatus;

  /// No description provided for @replyPreviewGeneric.
  ///
  /// In en, this message translates to:
  /// **'Quoted a message'**
  String get replyPreviewGeneric;

  /// No description provided for @editedSuffix.
  ///
  /// In en, this message translates to:
  /// **'(edited)'**
  String get editedSuffix;

  /// No description provided for @editAction.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editAction;

  /// No description provided for @hideMessageAction.
  ///
  /// In en, this message translates to:
  /// **'Delete from my chat history'**
  String get hideMessageAction;

  /// No description provided for @hideMessageActionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Only hides it for you; the other person can still see it'**
  String get hideMessageActionSubtitle;

  /// No description provided for @reportAction.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get reportAction;

  /// No description provided for @sendFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Send failed'**
  String get sendFailedShort;

  /// No description provided for @messageSentStatus.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get messageSentStatus;

  /// No description provided for @messageActionsHint.
  ///
  /// In en, this message translates to:
  /// **'Open message actions'**
  String get messageActionsHint;

  /// No description provided for @messageReadStatus.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get messageReadStatus;

  /// No description provided for @messageDeliveredStatus.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get messageDeliveredStatus;

  /// No description provided for @acknowledgementReceived.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get acknowledgementReceived;

  /// No description provided for @acknowledgementWillReview.
  ///
  /// In en, this message translates to:
  /// **'I\'ll review'**
  String get acknowledgementWillReview;

  /// No description provided for @acknowledgementCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get acknowledgementCompleted;

  /// No description provided for @acknowledgementWithdraw.
  ///
  /// In en, this message translates to:
  /// **'Withdraw acknowledgement'**
  String get acknowledgementWithdraw;

  /// No description provided for @typingIndicator.
  ///
  /// In en, this message translates to:
  /// **'{username} is typing...'**
  String typingIndicator(String username);

  /// No description provided for @loadFailedWithError.
  ///
  /// In en, this message translates to:
  /// **'Load failed: {error}'**
  String loadFailedWithError(String error);

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Start the conversation.'**
  String get noMessagesYet;

  /// No description provided for @stopAction.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopAction;

  /// No description provided for @replyMediaMessage.
  ///
  /// In en, this message translates to:
  /// **'Reply to a media message'**
  String get replyMediaMessage;

  /// No description provided for @cancelQuote.
  ///
  /// In en, this message translates to:
  /// **'Cancel quote'**
  String get cancelQuote;

  /// No description provided for @quoteContextTooltip.
  ///
  /// In en, this message translates to:
  /// **'Quote a listing, order, or negotiation'**
  String get quoteContextTooltip;

  /// No description provided for @editMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Edit message...'**
  String get editMessageHint;

  /// No description provided for @messageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get messageInputHint;

  /// No description provided for @offerPriceLine.
  ///
  /// In en, this message translates to:
  /// **'Offer: ¥{price}'**
  String offerPriceLine(String price);

  /// No description provided for @reasonLine.
  ///
  /// In en, this message translates to:
  /// **'Reason: {reason}'**
  String reasonLine(String reason);

  /// No description provided for @expiresAtLine.
  ///
  /// In en, this message translates to:
  /// **'Valid until: {time}'**
  String expiresAtLine(String time);

  /// No description provided for @counterOfferAction.
  ///
  /// In en, this message translates to:
  /// **'Counter'**
  String get counterOfferAction;

  /// No description provided for @acceptCounterAction.
  ///
  /// In en, this message translates to:
  /// **'Accept counter'**
  String get acceptCounterAction;

  /// No description provided for @sellerCounterPriceLine.
  ///
  /// In en, this message translates to:
  /// **'Seller countered ¥{price}'**
  String sellerCounterPriceLine(String price);

  /// No description provided for @yourOriginalOfferLine.
  ///
  /// In en, this message translates to:
  /// **'Your original offer: ¥{price}'**
  String yourOriginalOfferLine(String price);

  /// No description provided for @connectionFailedNetwork.
  ///
  /// In en, this message translates to:
  /// **'Connection failed. Please check the network.'**
  String get connectionFailedNetwork;

  /// No description provided for @emptyReplyPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'(no reply)'**
  String get emptyReplyPlaceholder;

  /// No description provided for @listingLine.
  ///
  /// In en, this message translates to:
  /// **'Listing: {listingId}'**
  String listingLine(String listingId);

  /// No description provided for @buyerOfferLine.
  ///
  /// In en, this message translates to:
  /// **'Buyer offer: ¥{price}'**
  String buyerOfferLine(String price);

  /// No description provided for @statusLine.
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String statusLine(String status);

  /// No description provided for @counterPriceLine.
  ///
  /// In en, this message translates to:
  /// **'Counter: ¥{price}'**
  String counterPriceLine(String price);

  /// No description provided for @negotiationStatusLine.
  ///
  /// In en, this message translates to:
  /// **'Negotiation {status}'**
  String negotiationStatusLine(String status);

  /// No description provided for @adminModerationTab.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get adminModerationTab;

  /// No description provided for @moderationCenter.
  ///
  /// In en, this message translates to:
  /// **'Content review'**
  String get moderationCenter;

  /// No description provided for @moderationCenterSubtitle.
  ///
  /// In en, this message translates to:
  /// **'View decisions affecting your content and submit appeals'**
  String get moderationCenterSubtitle;

  /// No description provided for @moderationNoCases.
  ///
  /// In en, this message translates to:
  /// **'There are no moderation cases affecting you'**
  String get moderationNoCases;

  /// No description provided for @moderationReadOnly.
  ///
  /// In en, this message translates to:
  /// **'You can inspect cases for this campus. Only platform admins can take action.'**
  String get moderationReadOnly;

  /// No description provided for @moderationCase.
  ///
  /// In en, this message translates to:
  /// **'Moderation case'**
  String get moderationCase;

  /// No description provided for @moderationResource.
  ///
  /// In en, this message translates to:
  /// **'Related content'**
  String get moderationResource;

  /// No description provided for @moderationReason.
  ///
  /// In en, this message translates to:
  /// **'Public reason'**
  String get moderationReason;

  /// No description provided for @moderationCreatedAt.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get moderationCreatedAt;

  /// No description provided for @moderationResolution.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get moderationResolution;

  /// No description provided for @moderationInternalEvidence.
  ///
  /// In en, this message translates to:
  /// **'Internal evidence'**
  String get moderationInternalEvidence;

  /// No description provided for @moderationStartReview.
  ///
  /// In en, this message translates to:
  /// **'Start review'**
  String get moderationStartReview;

  /// No description provided for @moderationRestrict.
  ///
  /// In en, this message translates to:
  /// **'Restrict content'**
  String get moderationRestrict;

  /// No description provided for @moderationDismiss.
  ///
  /// In en, this message translates to:
  /// **'No violation'**
  String get moderationDismiss;

  /// No description provided for @moderationRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore content'**
  String get moderationRestore;

  /// No description provided for @moderationManagedEnforcementHint.
  ///
  /// In en, this message translates to:
  /// **'Use the Listings or Users management tab to take down a listing or act on an account. Those enforcement actions are audited separately.'**
  String get moderationManagedEnforcementHint;

  /// No description provided for @moderationActionNote.
  ///
  /// In en, this message translates to:
  /// **'Internal decision note'**
  String get moderationActionNote;

  /// No description provided for @moderationPublicReason.
  ///
  /// In en, this message translates to:
  /// **'Reason shown to the user (optional)'**
  String get moderationPublicReason;

  /// No description provided for @moderationActionSuccess.
  ///
  /// In en, this message translates to:
  /// **'Case status updated'**
  String get moderationActionSuccess;

  /// No description provided for @moderationStatusOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get moderationStatusOpen;

  /// No description provided for @moderationStatusReviewing.
  ///
  /// In en, this message translates to:
  /// **'In review'**
  String get moderationStatusReviewing;

  /// No description provided for @moderationStatusActioned.
  ///
  /// In en, this message translates to:
  /// **'Action taken'**
  String get moderationStatusActioned;

  /// No description provided for @moderationStatusDismissed.
  ///
  /// In en, this message translates to:
  /// **'No violation'**
  String get moderationStatusDismissed;

  /// No description provided for @moderationStatusAppealed.
  ///
  /// In en, this message translates to:
  /// **'Under appeal'**
  String get moderationStatusAppealed;

  /// No description provided for @moderationStatusResolved.
  ///
  /// In en, this message translates to:
  /// **'Resolved'**
  String get moderationStatusResolved;

  /// No description provided for @moderationSourceMachine.
  ///
  /// In en, this message translates to:
  /// **'Automated review'**
  String get moderationSourceMachine;

  /// No description provided for @moderationSourceUserReport.
  ///
  /// In en, this message translates to:
  /// **'User report'**
  String get moderationSourceUserReport;

  /// No description provided for @moderationSourceManual.
  ///
  /// In en, this message translates to:
  /// **'Manual case'**
  String get moderationSourceManual;

  /// No description provided for @moderationAppeal.
  ///
  /// In en, this message translates to:
  /// **'Submit appeal'**
  String get moderationAppeal;

  /// No description provided for @moderationAppealHint.
  ///
  /// In en, this message translates to:
  /// **'Explain why the decision may be wrong and what another reviewer should check (10–2000 characters).'**
  String get moderationAppealHint;

  /// No description provided for @moderationAppealSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Appeal submitted for independent review'**
  String get moderationAppealSubmitted;

  /// No description provided for @moderationPendingAppeal.
  ///
  /// In en, this message translates to:
  /// **'Appeal awaiting review'**
  String get moderationPendingAppeal;

  /// No description provided for @moderationCannotAppeal.
  ///
  /// In en, this message translates to:
  /// **'This case cannot be appealed in its current state'**
  String get moderationCannotAppeal;

  /// No description provided for @moderationFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get moderationFilterAll;

  /// No description provided for @moderationNoInternalDetails.
  ///
  /// In en, this message translates to:
  /// **'No additional internal evidence'**
  String get moderationNoInternalDetails;

  /// No description provided for @listingImage.
  ///
  /// In en, this message translates to:
  /// **'Listing image'**
  String get listingImage;

  /// No description provided for @imageMessage.
  ///
  /// In en, this message translates to:
  /// **'Chat image'**
  String get imageMessage;

  /// No description provided for @avatar.
  ///
  /// In en, this message translates to:
  /// **'Avatar'**
  String get avatar;

  /// No description provided for @feedFeedbackMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Recommendation options'**
  String get feedFeedbackMenuTooltip;

  /// No description provided for @feedFeedbackHide.
  ///
  /// In en, this message translates to:
  /// **'Hide this'**
  String get feedFeedbackHide;

  /// No description provided for @feedFeedbackLessLikeThis.
  ///
  /// In en, this message translates to:
  /// **'Show me fewer like this'**
  String get feedFeedbackLessLikeThis;

  /// No description provided for @feedFeedbackNotRelevant.
  ///
  /// In en, this message translates to:
  /// **'Not relevant'**
  String get feedFeedbackNotRelevant;

  /// No description provided for @feedFeedbackSaved.
  ///
  /// In en, this message translates to:
  /// **'Thanks. This recommendation has been removed.'**
  String get feedFeedbackSaved;

  /// No description provided for @feedFeedbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that preference. The item is still here.'**
  String get feedFeedbackFailed;

  /// No description provided for @feedReasonRecent.
  ///
  /// In en, this message translates to:
  /// **'Recently posted'**
  String get feedReasonRecent;

  /// No description provided for @feedReasonSameCategory.
  ///
  /// In en, this message translates to:
  /// **'Matches categories you view'**
  String get feedReasonSameCategory;

  /// No description provided for @feedReasonCategoryMatch.
  ///
  /// In en, this message translates to:
  /// **'Category matches your request'**
  String get feedReasonCategoryMatch;

  /// No description provided for @feedReasonSimilar.
  ///
  /// In en, this message translates to:
  /// **'Similar to something you viewed'**
  String get feedReasonSimilar;

  /// No description provided for @feedReasonWithinBudget.
  ///
  /// In en, this message translates to:
  /// **'Within your budget'**
  String get feedReasonWithinBudget;

  /// No description provided for @feedReasonConditionMatch.
  ///
  /// In en, this message translates to:
  /// **'Matches the condition you wanted'**
  String get feedReasonConditionMatch;

  /// No description provided for @feedReasonIntentKind.
  ///
  /// In en, this message translates to:
  /// **'Matches what you are looking for'**
  String get feedReasonIntentKind;

  /// No description provided for @feedReasonKeywordMatch.
  ///
  /// In en, this message translates to:
  /// **'Matches the words in your request'**
  String get feedReasonKeywordMatch;

  /// No description provided for @feedReasonRequirementsMatch.
  ///
  /// In en, this message translates to:
  /// **'Matches the details you specified'**
  String get feedReasonRequirementsMatch;

  /// No description provided for @feedReasonTimeOverlap.
  ///
  /// In en, this message translates to:
  /// **'The available time overlaps with yours'**
  String get feedReasonTimeOverlap;

  /// No description provided for @feedReasonRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended for you'**
  String get feedReasonRecommended;

  /// No description provided for @feedPreferencesSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Feed controls'**
  String get feedPreferencesSectionTitle;

  /// No description provided for @feedPersonalizationTitle.
  ///
  /// In en, this message translates to:
  /// **'Personalized recommendations'**
  String get feedPersonalizationTitle;

  /// No description provided for @feedPersonalizationOnSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your feed preferences to make suggestions more relevant.'**
  String get feedPersonalizationOnSubtitle;

  /// No description provided for @feedPersonalizationOffSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show a non-personalized feed instead.'**
  String get feedPersonalizationOffSubtitle;

  /// No description provided for @feedPersonalizationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Feed preferences are temporarily unavailable.'**
  String get feedPersonalizationUnavailable;

  /// No description provided for @feedPersonalizationUpdated.
  ///
  /// In en, this message translates to:
  /// **'Feed preference updated'**
  String get feedPersonalizationUpdated;

  /// No description provided for @feedPreferencesUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update your feed preference. Try again.'**
  String get feedPreferencesUpdateFailed;

  /// No description provided for @feedPersonalizationClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset personalized recommendations'**
  String get feedPersonalizationClearTitle;

  /// No description provided for @feedPersonalizationClearSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Stop using past watchlist, deal activity, and “show fewer” signals. Items you hid stay hidden.'**
  String get feedPersonalizationClearSubtitle;

  /// No description provided for @feedPersonalizationClearConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset personalized recommendations?'**
  String get feedPersonalizationClearConfirmTitle;

  /// No description provided for @feedPersonalizationClearConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Recommendations will no longer use your previous watchlist, deal activity, or “show fewer” signals. The underlying records are not deleted, and specific items you hid stay hidden.'**
  String get feedPersonalizationClearConfirmBody;

  /// No description provided for @feedPersonalizationClearAction.
  ///
  /// In en, this message translates to:
  /// **'Reset recommendations'**
  String get feedPersonalizationClearAction;

  /// No description provided for @feedPersonalizationCleared.
  ///
  /// In en, this message translates to:
  /// **'Personalized recommendations reset'**
  String get feedPersonalizationCleared;

  /// No description provided for @feedPersonalizationClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reset personalized recommendations. Try again.'**
  String get feedPersonalizationClearFailed;

  /// No description provided for @warning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get warning;

  /// No description provided for @listingLifecycleActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get listingLifecycleActive;

  /// No description provided for @listingLifecycleFulfilled.
  ///
  /// In en, this message translates to:
  /// **'Fulfilled'**
  String get listingLifecycleFulfilled;

  /// No description provided for @listingLifecycleSold.
  ///
  /// In en, this message translates to:
  /// **'Sold'**
  String get listingLifecycleSold;

  /// No description provided for @listingLifecycleOwnerDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted by you'**
  String get listingLifecycleOwnerDeleted;

  /// No description provided for @listingLifecycleUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unavailable'**
  String get listingLifecycleUnknown;

  /// No description provided for @listingRestrictedBadge.
  ///
  /// In en, this message translates to:
  /// **'Restricted by moderation'**
  String get listingRestrictedBadge;

  /// No description provided for @listingRestrictionTitle.
  ///
  /// In en, this message translates to:
  /// **'This listing is restricted'**
  String get listingRestrictionTitle;

  /// No description provided for @listingRestrictionGeneric.
  ///
  /// In en, this message translates to:
  /// **'It is hidden from marketplace activity until an administrator restores it.'**
  String get listingRestrictionGeneric;

  /// No description provided for @viewModerationCase.
  ///
  /// In en, this message translates to:
  /// **'View moderation case'**
  String get viewModerationCase;

  /// No description provided for @deleteListingAction.
  ///
  /// In en, this message translates to:
  /// **'Delete listing'**
  String get deleteListingAction;

  /// No description provided for @relistListingAction.
  ///
  /// In en, this message translates to:
  /// **'Relist'**
  String get relistListingAction;

  /// No description provided for @listingDeletedToast.
  ///
  /// In en, this message translates to:
  /// **'Listing deleted'**
  String get listingDeletedToast;

  /// No description provided for @listingRelistedToast.
  ///
  /// In en, this message translates to:
  /// **'Listing relisted'**
  String get listingRelistedToast;

  /// No description provided for @deleteListingConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this listing?'**
  String get deleteListingConfirmTitle;

  /// No description provided for @listingPolicyChangedToast.
  ///
  /// In en, this message translates to:
  /// **'The listing changed. Actions have been refreshed.'**
  String get listingPolicyChangedToast;

  /// No description provided for @adminRestoreListing.
  ///
  /// In en, this message translates to:
  /// **'Restore listing'**
  String get adminRestoreListing;

  /// No description provided for @adminRestoreListingConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restore this listing?'**
  String get adminRestoreListingConfirm;

  /// No description provided for @adminRestoreReasonHint.
  ///
  /// In en, this message translates to:
  /// **'Explain why this administrative restriction should be removed.'**
  String get adminRestoreReasonHint;

  /// No description provided for @adminRestoreListingSuccess.
  ///
  /// In en, this message translates to:
  /// **'Listing restriction removed'**
  String get adminRestoreListingSuccess;

  /// No description provided for @adminListingNoActions.
  ///
  /// In en, this message translates to:
  /// **'No administrative action is available for this listing.'**
  String get adminListingNoActions;

  /// No description provided for @socialPersonaTitle.
  ///
  /// In en, this message translates to:
  /// **'Role presentation'**
  String get socialPersonaTitle;

  /// No description provided for @socialPersonaDescription.
  ///
  /// In en, this message translates to:
  /// **'Show how you want to be approached with choices you made; it never represents online, read, or inferred attention state.'**
  String get socialPersonaDescription;

  /// No description provided for @socialPersonaCreate.
  ///
  /// In en, this message translates to:
  /// **'Create role presentation'**
  String get socialPersonaCreate;

  /// No description provided for @socialPersonaEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit role presentation'**
  String get socialPersonaEdit;

  /// No description provided for @socialPersonaDraft.
  ///
  /// In en, this message translates to:
  /// **'Draft · visible only to you'**
  String get socialPersonaDraft;

  /// No description provided for @socialPersonaPublished.
  ///
  /// In en, this message translates to:
  /// **'Published · visible on this campus'**
  String get socialPersonaPublished;

  /// No description provided for @socialPersonaArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived · ordinary avatar is shown'**
  String get socialPersonaArchived;

  /// No description provided for @socialPersonaRepresentationMode.
  ///
  /// In en, this message translates to:
  /// **'Representation'**
  String get socialPersonaRepresentationMode;

  /// No description provided for @socialPersonaTraitMapped.
  ///
  /// In en, this message translates to:
  /// **'Trait mapped'**
  String get socialPersonaTraitMapped;

  /// No description provided for @socialPersonaRoleCharacter.
  ///
  /// In en, this message translates to:
  /// **'Role character'**
  String get socialPersonaRoleCharacter;

  /// No description provided for @socialPersonaPalette.
  ///
  /// In en, this message translates to:
  /// **'Palette'**
  String get socialPersonaPalette;

  /// No description provided for @socialPersonaPaletteTeal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get socialPersonaPaletteTeal;

  /// No description provided for @socialPersonaPalettePlum.
  ///
  /// In en, this message translates to:
  /// **'Plum'**
  String get socialPersonaPalettePlum;

  /// No description provided for @socialPersonaPaletteSun.
  ///
  /// In en, this message translates to:
  /// **'Sun'**
  String get socialPersonaPaletteSun;

  /// No description provided for @socialPersonaPaletteSlate.
  ///
  /// In en, this message translates to:
  /// **'Slate'**
  String get socialPersonaPaletteSlate;

  /// No description provided for @socialPersonaSilhouette.
  ///
  /// In en, this message translates to:
  /// **'Silhouette'**
  String get socialPersonaSilhouette;

  /// No description provided for @socialPersonaSilhouetteSoft.
  ///
  /// In en, this message translates to:
  /// **'Soft'**
  String get socialPersonaSilhouetteSoft;

  /// No description provided for @socialPersonaSilhouetteRound.
  ///
  /// In en, this message translates to:
  /// **'Round'**
  String get socialPersonaSilhouetteRound;

  /// No description provided for @socialPersonaSilhouetteSharp.
  ///
  /// In en, this message translates to:
  /// **'Sharp'**
  String get socialPersonaSilhouetteSharp;

  /// No description provided for @socialPersonaAccessory.
  ///
  /// In en, this message translates to:
  /// **'Accessory'**
  String get socialPersonaAccessory;

  /// No description provided for @socialPersonaAccessoryNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get socialPersonaAccessoryNone;

  /// No description provided for @socialPersonaAccessoryGlasses.
  ///
  /// In en, this message translates to:
  /// **'Glasses'**
  String get socialPersonaAccessoryGlasses;

  /// No description provided for @socialPersonaAccessoryHeadphones.
  ///
  /// In en, this message translates to:
  /// **'Headphones'**
  String get socialPersonaAccessoryHeadphones;

  /// No description provided for @socialPersonaAccessoryLeaf.
  ///
  /// In en, this message translates to:
  /// **'Leaf'**
  String get socialPersonaAccessoryLeaf;

  /// No description provided for @socialPersonaOutfit.
  ///
  /// In en, this message translates to:
  /// **'Outfit'**
  String get socialPersonaOutfit;

  /// No description provided for @socialPersonaOutfitCampus.
  ///
  /// In en, this message translates to:
  /// **'Campus'**
  String get socialPersonaOutfitCampus;

  /// No description provided for @socialPersonaOutfitWorkwear.
  ///
  /// In en, this message translates to:
  /// **'Simple'**
  String get socialPersonaOutfitWorkwear;

  /// No description provided for @socialPersonaOutfitCasual.
  ///
  /// In en, this message translates to:
  /// **'Casual'**
  String get socialPersonaOutfitCasual;

  /// No description provided for @socialPersonaOutfitLab.
  ///
  /// In en, this message translates to:
  /// **'Lab'**
  String get socialPersonaOutfitLab;

  /// No description provided for @socialPersonaContactPosture.
  ///
  /// In en, this message translates to:
  /// **'How others can approach you'**
  String get socialPersonaContactPosture;

  /// No description provided for @socialPersonaLeaveMessage.
  ///
  /// In en, this message translates to:
  /// **'Leave a message; replies may not be immediate'**
  String get socialPersonaLeaveMessage;

  /// No description provided for @socialPersonaConnectionAllowed.
  ///
  /// In en, this message translates to:
  /// **'Connection requests are welcome'**
  String get socialPersonaConnectionAllowed;

  /// No description provided for @socialPersonaBusy.
  ///
  /// In en, this message translates to:
  /// **'Busy lately; messages are still welcome'**
  String get socialPersonaBusy;

  /// No description provided for @socialPersonaLater.
  ///
  /// In en, this message translates to:
  /// **'Will look later'**
  String get socialPersonaLater;

  /// No description provided for @socialPersonaLabels.
  ///
  /// In en, this message translates to:
  /// **'Self-description (up to three)'**
  String get socialPersonaLabels;

  /// No description provided for @socialPersonaLabelSlowToWarm.
  ///
  /// In en, this message translates to:
  /// **'Slow to warm'**
  String get socialPersonaLabelSlowToWarm;

  /// No description provided for @socialPersonaLabelBusinessOnly.
  ///
  /// In en, this message translates to:
  /// **'Business only'**
  String get socialPersonaLabelBusinessOnly;

  /// No description provided for @socialPersonaLabelMeetupFriendly.
  ///
  /// In en, this message translates to:
  /// **'Meetup friendly'**
  String get socialPersonaLabelMeetupFriendly;

  /// No description provided for @socialPersonaLabelCasualChat.
  ///
  /// In en, this message translates to:
  /// **'Casual chat'**
  String get socialPersonaLabelCasualChat;

  /// No description provided for @socialPersonaLabelReplyLater.
  ///
  /// In en, this message translates to:
  /// **'Replies later'**
  String get socialPersonaLabelReplyLater;

  /// No description provided for @socialPersonaLabelTechEnthusiast.
  ///
  /// In en, this message translates to:
  /// **'Tech enthusiast'**
  String get socialPersonaLabelTechEnthusiast;

  /// No description provided for @socialPersonaSaveDraft.
  ///
  /// In en, this message translates to:
  /// **'Save draft'**
  String get socialPersonaSaveDraft;

  /// No description provided for @socialPersonaPublish.
  ///
  /// In en, this message translates to:
  /// **'Publish presentation'**
  String get socialPersonaPublish;

  /// No description provided for @socialPersonaArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive and restore ordinary avatar'**
  String get socialPersonaArchive;

  /// No description provided for @socialPersonaRestore.
  ///
  /// In en, this message translates to:
  /// **'Edit and publish again'**
  String get socialPersonaRestore;

  /// No description provided for @socialPersonaPublishConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Publish role presentation?'**
  String get socialPersonaPublishConfirmTitle;

  /// No description provided for @socialPersonaPublishConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'People on this campus will be able to see it. It never means online, read, typing, or any other attention state.'**
  String get socialPersonaPublishConfirmBody;

  /// No description provided for @socialPersonaSaved.
  ///
  /// In en, this message translates to:
  /// **'Role presentation draft saved'**
  String get socialPersonaSaved;

  /// No description provided for @socialPersonaPublishedToast.
  ///
  /// In en, this message translates to:
  /// **'Role presentation published'**
  String get socialPersonaPublishedToast;

  /// No description provided for @socialPersonaArchivedToast.
  ///
  /// In en, this message translates to:
  /// **'Archived; ordinary avatar is shown'**
  String get socialPersonaArchivedToast;

  /// No description provided for @socialPersonaPreviewRole.
  ///
  /// In en, this message translates to:
  /// **'Role preview'**
  String get socialPersonaPreviewRole;

  /// No description provided for @socialPersonaSelectHint.
  ///
  /// In en, this message translates to:
  /// **'Choices are restricted to the current style version.'**
  String get socialPersonaSelectHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
