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
  /// **'Service unavailable. Try again.'**
  String get aiError;

  /// No description provided for @aiGreeting.
  ///
  /// In en, this message translates to:
  /// **'Goods4ncu intelligent services'**
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
  /// **'Goods4ncu'**
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
  /// **'Identifying…'**
  String get createListingAiRecognizing;

  /// No description provided for @createListingAiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Upload an image to identify the title, category, brand, and condition. Confirmation is required before publishing.'**
  String get createListingAiSubtitle;

  /// No description provided for @createListingAiTitle.
  ///
  /// In en, this message translates to:
  /// **'Image recognition'**
  String get createListingAiTitle;

  /// No description provided for @createListingModeOffer.
  ///
  /// In en, this message translates to:
  /// **'Sell'**
  String get createListingModeOffer;

  /// No description provided for @createListingModeWanted.
  ///
  /// In en, this message translates to:
  /// **'Request'**
  String get createListingModeWanted;

  /// No description provided for @createWantedPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Request details'**
  String get createWantedPanelTitle;

  /// No description provided for @createWantedPanelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter a budget, minimum condition, and other requirements for campus listing matching.'**
  String get createWantedPanelSubtitle;

  /// No description provided for @createListingBasicInfo.
  ///
  /// In en, this message translates to:
  /// **'Listing basics'**
  String get createListingBasicInfo;

  /// No description provided for @createListingBasicInfoSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Used to generate the item list and detail view.'**
  String get createListingBasicInfoSubtitle;

  /// No description provided for @createWantedBasicInfo.
  ///
  /// In en, this message translates to:
  /// **'Wanted basics'**
  String get createWantedBasicInfo;

  /// No description provided for @createWantedBasicInfoSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter clear request criteria.'**
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
  /// **'Accurately describe the item\'s condition and defects.'**
  String get createListingConditionSubtitle;

  /// No description provided for @createWantedConditionSection.
  ///
  /// In en, this message translates to:
  /// **'Minimum requirements'**
  String get createWantedConditionSection;

  /// No description provided for @createWantedConditionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter the minimum acceptable condition and requirements.'**
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
  /// **'Optional. Used to reduce follow-up questions.'**
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
  /// **'Optional. Used to improve matching accuracy.'**
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

  /// No description provided for @publishBrandLabel.
  ///
  /// In en, this message translates to:
  /// **'Brand / source (optional)'**
  String get publishBrandLabel;

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
  /// **'Complete the required fields.'**
  String get createListingProgressSubtitle;

  /// No description provided for @createListingProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Publish progress'**
  String get createListingProgressTitle;

  /// No description provided for @createListingReadyHint.
  ///
  /// In en, this message translates to:
  /// **'Information complete'**
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
  /// **'Discover'**
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

  /// No description provided for @myPosts.
  ///
  /// In en, this message translates to:
  /// **'My posts'**
  String get myPosts;

  /// No description provided for @myPostsMenu.
  ///
  /// In en, this message translates to:
  /// **'Manage your offer/wanted/discussion posts'**
  String get myPostsMenu;

  /// No description provided for @myPostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing published yet'**
  String get myPostsEmpty;

  /// No description provided for @myPostsDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this post?'**
  String get myPostsDeleteConfirmTitle;

  /// No description provided for @myPostsDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The post will be marked deleted. This cannot be undone.'**
  String get myPostsDeleteConfirmBody;

  /// No description provided for @postStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get postStatusActive;

  /// No description provided for @postStatusLocked.
  ///
  /// In en, this message translates to:
  /// **'Locked'**
  String get postStatusLocked;

  /// No description provided for @postStatusArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get postStatusArchived;

  /// No description provided for @postStatusDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get postStatusDeleted;

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
  /// **'No listings or requests yet'**
  String get homeColdStartTitle;

  /// No description provided for @homeColdStartBody.
  ///
  /// In en, this message translates to:
  /// **'No offers or requests at this school.'**
  String get homeColdStartBody;

  /// No description provided for @homeColdStartAction.
  ///
  /// In en, this message translates to:
  /// **'Post'**
  String get homeColdStartAction;

  /// No description provided for @homeVoicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Campus Requests'**
  String get homeVoicesTitle;

  /// No description provided for @homeVoicesBody.
  ///
  /// In en, this message translates to:
  /// **'Items classmates are looking for.'**
  String get homeVoicesBody;

  /// No description provided for @homeFilterEmpty.
  ///
  /// In en, this message translates to:
  /// **'No content under this filter.'**
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

  /// No description provided for @assistantMemoryPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Memory & skills'**
  String get assistantMemoryPanelTitle;

  /// No description provided for @memoryInstructionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Long-term instructions'**
  String get memoryInstructionsTitle;

  /// No description provided for @memoryInstructionsHint.
  ///
  /// In en, this message translates to:
  /// **'Tell the assistant your standing preferences, e.g. \'prefer textbooks under ¥50\'.'**
  String get memoryInstructionsHint;

  /// No description provided for @memoryEnabledTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable memory'**
  String get memoryEnabledTitle;

  /// No description provided for @memoryEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, past memories and personalization are ignored'**
  String get memoryEnabledSubtitle;

  /// No description provided for @memoriesListTitle.
  ///
  /// In en, this message translates to:
  /// **'Remembered'**
  String get memoriesListTitle;

  /// No description provided for @memoriesEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing remembered yet. Preferences expressed in chat show up here.'**
  String get memoriesEmpty;

  /// No description provided for @memoryClearAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear all memories?'**
  String get memoryClearAllTitle;

  /// No description provided for @memoryClearAllBody.
  ///
  /// In en, this message translates to:
  /// **'The assistant will forget everything it has learned. This cannot be undone.'**
  String get memoryClearAllBody;

  /// No description provided for @memoryClearAllAction.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get memoryClearAllAction;

  /// No description provided for @memoryClearedToast.
  ///
  /// In en, this message translates to:
  /// **'Memories cleared'**
  String get memoryClearedToast;

  /// No description provided for @memorySavedToast.
  ///
  /// In en, this message translates to:
  /// **'Instructions saved'**
  String get memorySavedToast;

  /// No description provided for @skillsTitle.
  ///
  /// In en, this message translates to:
  /// **'My skills'**
  String get skillsTitle;

  /// No description provided for @skillNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Skill name'**
  String get skillNameLabel;

  /// No description provided for @skillInstructionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Skill instructions'**
  String get skillInstructionsLabel;

  /// No description provided for @skillAddAction.
  ///
  /// In en, this message translates to:
  /// **'Add / update skill'**
  String get skillAddAction;

  /// No description provided for @skillMissingFields.
  ///
  /// In en, this message translates to:
  /// **'Fill in both name and instructions'**
  String get skillMissingFields;

  /// No description provided for @skillSavedToast.
  ///
  /// In en, this message translates to:
  /// **'Skill saved'**
  String get skillSavedToast;

  /// No description provided for @skillsImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Import skills (JSON)'**
  String get skillsImportTitle;

  /// Example JSON payload shown as hint text
  ///
  /// In en, this message translates to:
  /// **'A JSON array in the form {example}'**
  String skillsImportHint(Object example);

  /// No description provided for @skillsImportAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get skillsImportAction;

  /// No description provided for @skillsImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} skills'**
  String skillsImported(Object count);

  /// No description provided for @skillImportBadJson.
  ///
  /// In en, this message translates to:
  /// **'Invalid JSON format'**
  String get skillImportBadJson;

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
  /// **'Pending actions'**
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

  /// No description provided for @intentRespondAction.
  ///
  /// In en, this message translates to:
  /// **'Contact publisher'**
  String get intentRespondAction;

  /// No description provided for @intentRespondTitle.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get intentRespondTitle;

  /// No description provided for @intentRespondHint.
  ///
  /// In en, this message translates to:
  /// **'Describe the item or relevant information you can provide'**
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
  /// **'Price negotiation'**
  String get priceDiscoveryTitle;

  /// No description provided for @priceDiscoveryStart.
  ///
  /// In en, this message translates to:
  /// **'Start price negotiation'**
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
  /// **'Submit offer'**
  String get priceDiscoverySubmit;

  /// No description provided for @priceDiscoveryWaiting.
  ///
  /// In en, this message translates to:
  /// **'Offer submitted. Offers remain hidden until both parties submit.'**
  String get priceDiscoveryWaiting;

  /// No description provided for @priceDiscoveryNoDeal.
  ///
  /// In en, this message translates to:
  /// **'The submitted offers do not currently overlap.'**
  String get priceDiscoveryNoDeal;

  /// No description provided for @priceDiscoveryAcceptInvite.
  ///
  /// In en, this message translates to:
  /// **'Price negotiation request received'**
  String get priceDiscoveryAcceptInvite;

  /// No description provided for @priceDiscoveryAgree.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get priceDiscoveryAgree;

  /// No description provided for @priceDiscoveryPreferHaggle.
  ///
  /// In en, this message translates to:
  /// **'Switch to direct negotiation'**
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

  /// No description provided for @reputationNewcomer.
  ///
  /// In en, this message translates to:
  /// **'No record'**
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

  /// No description provided for @homePromptHint.
  ///
  /// In en, this message translates to:
  /// **'Search items or requests'**
  String get homePromptHint;

  /// No description provided for @homePromptSubmitTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get homePromptSubmitTooltip;

  /// No description provided for @homeActionOffer.
  ///
  /// In en, this message translates to:
  /// **'Post Offer'**
  String get homeActionOffer;

  /// No description provided for @homeActionWanted.
  ///
  /// In en, this message translates to:
  /// **'Post Request'**
  String get homeActionWanted;

  /// No description provided for @homeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Classmates Buying & Selling'**
  String get homeSectionTitle;

  /// No description provided for @homeSectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Listings and requests from your campus'**
  String get homeSectionSubtitle;

  /// No description provided for @homeLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load right now'**
  String get homeLoadFailed;

  /// No description provided for @homeLoadFailedRetry.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get homeLoadFailedRetry;

  /// No description provided for @conversationLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Messages could not load'**
  String get conversationLoadFailedTitle;

  /// No description provided for @conversationEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations'**
  String get conversationEmptyTitle;

  /// No description provided for @conversationEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Conversations appear here after contact is initiated.'**
  String get conversationEmptySubtitle;

  /// No description provided for @conversationEmptyAction.
  ///
  /// In en, this message translates to:
  /// **'Post offer / wanted'**
  String get conversationEmptyAction;

  /// No description provided for @conversationEmptyAskAssistant.
  ///
  /// In en, this message translates to:
  /// **'Xiaochang'**
  String get conversationEmptyAskAssistant;

  /// No description provided for @conversationSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search contacts, messages, items, or groups'**
  String get conversationSearchHint;

  /// No description provided for @conversationSearchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get conversationSearchClear;

  /// No description provided for @conversationSearchEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No matching messages'**
  String get conversationSearchEmptyTitle;

  /// No description provided for @conversationSearchEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a contact, item, recent message, or group name.'**
  String get conversationSearchEmptySubtitle;

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
  /// **'Connections'**
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

  /// No description provided for @contactConnectAction.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get contactConnectAction;

  /// No description provided for @contactMailAction.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get contactMailAction;

  /// No description provided for @chatHistoryAction.
  ///
  /// In en, this message translates to:
  /// **'Chat history'**
  String get chatHistoryAction;

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
  /// **'Xiaochang'**
  String get assistantName;

  /// No description provided for @assistantSystemBadge.
  ///
  /// In en, this message translates to:
  /// **'Core Avatar'**
  String get assistantSystemBadge;

  /// No description provided for @assistantInboxSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Item search, pricing, publishing, and negotiation'**
  String get assistantInboxSubtitle;

  /// No description provided for @assistantHeaderSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Personal transaction assistant · important actions require confirmation'**
  String get assistantHeaderSubtitle;

  /// No description provided for @assistantHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'History failed to load.'**
  String get assistantHistoryLoadFailed;

  /// No description provided for @assistantTyping.
  ///
  /// In en, this message translates to:
  /// **'Processing…'**
  String get assistantTyping;

  /// No description provided for @assistantAskAboutPage.
  ///
  /// In en, this message translates to:
  /// **'Ask Xiaochang'**
  String get assistantAskAboutPage;

  /// No description provided for @relationshipSpacePokeAction.
  ///
  /// In en, this message translates to:
  /// **'Poke'**
  String get relationshipSpacePokeAction;

  /// No description provided for @relationshipSpacePokeFeedback.
  ///
  /// In en, this message translates to:
  /// **'You poked {name}'**
  String relationshipSpacePokeFeedback(String name);

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
  /// **'Realtime conversation invitation'**
  String get invitationFallbackTitle;

  /// No description provided for @declineNow.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get declineNow;

  /// No description provided for @connectNow.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
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
  /// **'Connection not established'**
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

  /// No description provided for @contactPageModeHint.
  ///
  /// In en, this message translates to:
  /// **'This is a full contact page. Choose realtime contact or mail; going back preserves the previous page.'**
  String get contactPageModeHint;

  /// No description provided for @contactBackAction.
  ///
  /// In en, this message translates to:
  /// **'Back to contact methods'**
  String get contactBackAction;

  /// No description provided for @contactContextUser.
  ///
  /// In en, this message translates to:
  /// **'Contact {username}'**
  String contactContextUser(String username);

  /// No description provided for @contactPageTitle.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get contactPageTitle;

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

  /// No description provided for @contactModeMailDescription.
  ///
  /// In en, this message translates to:
  /// **'Send messages directly; visible as soon as they open the app.'**
  String get contactModeMailDescription;

  /// No description provided for @contactOpeningRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter an opening message.'**
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

  /// No description provided for @contactMailExpectationLabel.
  ///
  /// In en, this message translates to:
  /// **'When would you like them to look? (optional)'**
  String get contactMailExpectationLabel;

  /// No description provided for @contactMailExpectationOrdinary.
  ///
  /// In en, this message translates to:
  /// **'No time requirement'**
  String get contactMailExpectationOrdinary;

  /// No description provided for @contactMailExpectationToday.
  ///
  /// In en, this message translates to:
  /// **'Reply today'**
  String get contactMailExpectationToday;

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
  /// **'Enter your question and preferred reply time...'**
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
  /// **'Campus group chats'**
  String get conversationSectionSpaces;

  /// No description provided for @conversationSectionTools.
  ///
  /// In en, this message translates to:
  /// **'Xiaochang'**
  String get conversationSectionTools;

  /// No description provided for @conversationCreateGroupSuccess.
  ///
  /// In en, this message translates to:
  /// **'Group created and added to Messages'**
  String get conversationCreateGroupSuccess;

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
  /// **'Loading'**
  String get conversationThreadLoading;

  /// No description provided for @conversationReconnect.
  ///
  /// In en, this message translates to:
  /// **'Contact again'**
  String get conversationReconnect;

  /// No description provided for @conversationThreadLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Contact conversation failed to load'**
  String get conversationThreadLoadFailedTitle;

  /// No description provided for @conversationThreadEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No communication records'**
  String get conversationThreadEmptyTitle;

  /// No description provided for @conversationThreadEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start a new realtime conversation or message.'**
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
  /// **'After opening, you can reply, quote, or handle the connection.'**
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

  /// No description provided for @relationshipSpaceLastConnection.
  ///
  /// In en, this message translates to:
  /// **'Last connection'**
  String get relationshipSpaceLastConnection;

  /// No description provided for @relationshipSpaceNoEvent.
  ///
  /// In en, this message translates to:
  /// **'Long press a message to pin, or share items and files to keep them here'**
  String get relationshipSpaceNoEvent;

  /// No description provided for @relationshipSpacePin.
  ///
  /// In en, this message translates to:
  /// **'Pin to shared space'**
  String get relationshipSpacePin;

  /// No description provided for @relationshipSpaceUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get relationshipSpaceUnpin;

  /// No description provided for @relationshipSpacePinsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} pinned'**
  String relationshipSpacePinsCount(int count);

  /// No description provided for @relationshipSpaceObjectsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} shared items'**
  String relationshipSpaceObjectsCount(int count);

  /// No description provided for @relationshipSpaceSharedObjectsTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared content'**
  String get relationshipSpaceSharedObjectsTitle;

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

  /// No description provided for @relationshipSpacePinsTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned messages'**
  String get relationshipSpacePinsTitle;

  /// No description provided for @relationshipSpaceRecentRecords.
  ///
  /// In en, this message translates to:
  /// **'Recent records'**
  String get relationshipSpaceRecentRecords;

  /// No description provided for @relationshipSpaceNoRecentRecords.
  ///
  /// In en, this message translates to:
  /// **'No time records to revisit yet'**
  String get relationshipSpaceNoRecentRecords;

  /// No description provided for @relationshipSpaceRecentRecovery.
  ///
  /// In en, this message translates to:
  /// **'Last connection record'**
  String get relationshipSpaceRecentRecovery;

  /// No description provided for @relationshipSpaceExpandAction.
  ///
  /// In en, this message translates to:
  /// **'Expand shared space'**
  String get relationshipSpaceExpandAction;

  /// No description provided for @relationshipSpaceCollapseAction.
  ///
  /// In en, this message translates to:
  /// **'Collapse shared space'**
  String get relationshipSpaceCollapseAction;

  /// No description provided for @relationshipSpaceEventSentMessage.
  ///
  /// In en, this message translates to:
  /// **'Sent a message'**
  String get relationshipSpaceEventSentMessage;

  /// No description provided for @relationshipSpaceEventOpeningMessage.
  ///
  /// In en, this message translates to:
  /// **'Sent opening message'**
  String get relationshipSpaceEventOpeningMessage;

  /// No description provided for @relationshipSpaceEventConnectionStarted.
  ///
  /// In en, this message translates to:
  /// **'Started a connection'**
  String get relationshipSpaceEventConnectionStarted;

  /// No description provided for @relationshipSpaceEventConnectionEnded.
  ///
  /// In en, this message translates to:
  /// **'Ended a connection'**
  String get relationshipSpaceEventConnectionEnded;

  /// No description provided for @relationshipSpaceEventConnectionAccepted.
  ///
  /// In en, this message translates to:
  /// **'Accepted connection'**
  String get relationshipSpaceEventConnectionAccepted;

  /// No description provided for @relationshipSpaceEventConnectionDeclined.
  ///
  /// In en, this message translates to:
  /// **'Declined connection'**
  String get relationshipSpaceEventConnectionDeclined;

  /// No description provided for @relationshipSpaceEventConversationCreated.
  ///
  /// In en, this message translates to:
  /// **'Conversation started'**
  String get relationshipSpaceEventConversationCreated;

  /// No description provided for @relationshipSpaceEventPinChanged.
  ///
  /// In en, this message translates to:
  /// **'Pinned messages changed'**
  String get relationshipSpaceEventPinChanged;

  /// No description provided for @relationshipSpaceEventAcknowledgementChanged.
  ///
  /// In en, this message translates to:
  /// **'Responded to a message'**
  String get relationshipSpaceEventAcknowledgementChanged;

  /// No description provided for @relationshipSpaceEventSharedObjectChanged.
  ///
  /// In en, this message translates to:
  /// **'Shared content changed'**
  String get relationshipSpaceEventSharedObjectChanged;

  /// No description provided for @relationshipSpaceEventDefault.
  ///
  /// In en, this message translates to:
  /// **'Added a new record'**
  String get relationshipSpaceEventDefault;

  /// No description provided for @createGroup.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get createGroup;

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
  /// **'{count} members · {role}'**
  String spaceMembersRoleLine(int count, String role);

  /// No description provided for @spaceMessagesLoadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Space messages could not load'**
  String get spaceMessagesLoadFailedTitle;

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

  /// No description provided for @cancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get cancelReply;

  /// No description provided for @startGroupTopic.
  ///
  /// In en, this message translates to:
  /// **'Start a topic'**
  String get startGroupTopic;

  /// No description provided for @groupTopicTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what you want to discuss'**
  String get groupTopicTitleHint;

  /// No description provided for @groupTopicCreateHint.
  ///
  /// In en, this message translates to:
  /// **'Every reply will stay inside this topic.'**
  String get groupTopicCreateHint;

  /// No description provided for @createTopicAction.
  ///
  /// In en, this message translates to:
  /// **'Create topic'**
  String get createTopicAction;

  /// No description provided for @groupTopicEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No topics yet'**
  String get groupTopicEmptyTitle;

  /// No description provided for @groupTopicEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'A group topic must be started before members can discuss it.'**
  String get groupTopicEmptySubtitle;

  /// No description provided for @groupTopicReplyHint.
  ///
  /// In en, this message translates to:
  /// **'Reply in this topic...'**
  String get groupTopicReplyHint;

  /// No description provided for @groupTopicNoRepliesTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first reply'**
  String get groupTopicNoRepliesTitle;

  /// No description provided for @groupTopicNoRepliesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your reply will only appear in this topic.'**
  String get groupTopicNoRepliesSubtitle;

  /// No description provided for @groupTopicStartedBy.
  ///
  /// In en, this message translates to:
  /// **'Started by {name}'**
  String groupTopicStartedBy(String name);

  /// No description provided for @groupTopicReplyCount.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String groupTopicReplyCount(int count);

  /// No description provided for @spaceFallbackDescription.
  ///
  /// In en, this message translates to:
  /// **'{count} members · {kind}'**
  String spaceFallbackDescription(int count, String kind);

  /// No description provided for @spaceKindGroupLong.
  ///
  /// In en, this message translates to:
  /// **'Campus group'**
  String get spaceKindGroupLong;

  /// No description provided for @spaceKindGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get spaceKindGroup;

  /// No description provided for @spacePostsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Group posts'**
  String get spacePostsTooltip;

  /// No description provided for @spacePostsTitle.
  ///
  /// In en, this message translates to:
  /// **'Group posts'**
  String get spacePostsTitle;

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
  /// **'Reply suggestions are unavailable. Enter a reply directly.'**
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
  /// **'Preparing this conversation'**
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
  /// **'Audio call'**
  String get audioCallMvp;

  /// No description provided for @videoCallMvp.
  ///
  /// In en, this message translates to:
  /// **'Video call'**
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
  /// **'Generate reply suggestion'**
  String get replyAssistantButton;

  /// No description provided for @mailFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Mail'**
  String get mailFallbackTitle;

  /// No description provided for @incomingRealtimeTitle.
  ///
  /// In en, this message translates to:
  /// **'Realtime conversation invitation received'**
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

  /// No description provided for @relationshipContextScrollHint.
  ///
  /// In en, this message translates to:
  /// **'Swipe up to see more'**
  String get relationshipContextScrollHint;

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

  /// No description provided for @loadFailedWithError.
  ///
  /// In en, this message translates to:
  /// **'Load failed: {error}'**
  String loadFailedWithError(String error);

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages'**
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

  /// No description provided for @socialPersonaCharacter.
  ///
  /// In en, this message translates to:
  /// **'Avatar character'**
  String get socialPersonaCharacter;

  /// No description provided for @characterSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the character that accompanies you in chat. Tap your avatar anytime to change it.'**
  String get characterSettingsSubtitle;

  /// No description provided for @characterSettingsUpdated.
  ///
  /// In en, this message translates to:
  /// **'Companion character updated'**
  String get characterSettingsUpdated;

  /// No description provided for @socialPersonaCharacterDoro.
  ///
  /// In en, this message translates to:
  /// **'Doro'**
  String get socialPersonaCharacterDoro;

  /// No description provided for @composerMoreTools.
  ///
  /// In en, this message translates to:
  /// **'More tools'**
  String get composerMoreTools;

  /// No description provided for @composerHideTools.
  ///
  /// In en, this message translates to:
  /// **'Hide tools'**
  String get composerHideTools;

  /// No description provided for @composerSendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get composerSendTooltip;

  /// No description provided for @composerImageAction.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get composerImageAction;

  /// No description provided for @composerReferenceAction.
  ///
  /// In en, this message translates to:
  /// **'Reference'**
  String get composerReferenceAction;

  /// No description provided for @referenceChipPost.
  ///
  /// In en, this message translates to:
  /// **'Quoted post'**
  String get referenceChipPost;

  /// No description provided for @referenceChipListing.
  ///
  /// In en, this message translates to:
  /// **'Quoted listing'**
  String get referenceChipListing;

  /// No description provided for @referencePickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick something to reference'**
  String get referencePickerTitle;

  /// No description provided for @referencePickerSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search posts or listings'**
  String get referencePickerSearchHint;

  /// No description provided for @referenceRecentSection.
  ///
  /// In en, this message translates to:
  /// **'Recently viewed'**
  String get referenceRecentSection;

  /// No description provided for @referenceRemoveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove reference'**
  String get referenceRemoveTooltip;

  /// No description provided for @assistantStageCollapsed.
  ///
  /// In en, this message translates to:
  /// **'Show companion'**
  String get assistantStageCollapsed;

  /// No description provided for @assistantClearHistoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear chat history'**
  String get assistantClearHistoryTooltip;

  /// No description provided for @assistantClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear assistant chat history?'**
  String get assistantClearHistoryTitle;

  /// No description provided for @assistantClearHistoryBody.
  ///
  /// In en, this message translates to:
  /// **'All messages will be deleted permanently.'**
  String get assistantClearHistoryBody;

  /// No description provided for @assistantClearHistoryAction.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get assistantClearHistoryAction;

  /// No description provided for @assistantHistoryCleared.
  ///
  /// In en, this message translates to:
  /// **'Chat history cleared'**
  String get assistantHistoryCleared;

  /// No description provided for @assistantMessagesEmpty.
  ///
  /// In en, this message translates to:
  /// **'Say hi to your companion!'**
  String get assistantMessagesEmpty;

  /// No description provided for @composerVoiceMessageAction.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get composerVoiceMessageAction;

  /// No description provided for @dictationStartAction.
  ///
  /// In en, this message translates to:
  /// **'Speech to text'**
  String get dictationStartAction;

  /// No description provided for @dictationStopAction.
  ///
  /// In en, this message translates to:
  /// **'Stop dictation'**
  String get dictationStopAction;

  /// No description provided for @dictationListening.
  ///
  /// In en, this message translates to:
  /// **'Listening — recognized text appears in the input'**
  String get dictationListening;

  /// No description provided for @dictationPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission is required for speech to text'**
  String get dictationPermissionDenied;

  /// No description provided for @dictationUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device does not support speech to text'**
  String get dictationUnsupported;

  /// No description provided for @dictationNetworkError.
  ///
  /// In en, this message translates to:
  /// **'The speech recognition service is unavailable'**
  String get dictationNetworkError;

  /// No description provided for @dictationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Speech to text is temporarily unavailable'**
  String get dictationUnavailable;

  /// No description provided for @groupToolRelay.
  ///
  /// In en, this message translates to:
  /// **'Sign-up list'**
  String get groupToolRelay;

  /// No description provided for @groupToolCollection.
  ///
  /// In en, this message translates to:
  /// **'Group collection'**
  String get groupToolCollection;

  /// No description provided for @groupToolPoll.
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get groupToolPoll;

  /// No description provided for @groupToolRelayTemplate.
  ///
  /// In en, this message translates to:
  /// **'[Sign-up list]\nTopic:\nDeadline:'**
  String get groupToolRelayTemplate;

  /// No description provided for @groupToolCollectionTemplate.
  ///
  /// In en, this message translates to:
  /// **'[Group collection]\nName:\nDetails:'**
  String get groupToolCollectionTemplate;

  /// No description provided for @groupToolPollTemplate.
  ///
  /// In en, this message translates to:
  /// **'[Poll]\nQuestion:\nOption 1:\nOption 2:'**
  String get groupToolPollTemplate;

  /// No description provided for @assistantToolFind.
  ///
  /// In en, this message translates to:
  /// **'Find an item'**
  String get assistantToolFind;

  /// No description provided for @assistantToolPublish.
  ///
  /// In en, this message translates to:
  /// **'Publish an item'**
  String get assistantToolPublish;

  /// No description provided for @assistantToolEstimate.
  ///
  /// In en, this message translates to:
  /// **'Price guidance'**
  String get assistantToolEstimate;

  /// No description provided for @assistantToolFindPrompt.
  ///
  /// In en, this message translates to:
  /// **'Help me find an item:'**
  String get assistantToolFindPrompt;

  /// No description provided for @assistantToolPublishPrompt.
  ///
  /// In en, this message translates to:
  /// **'Help me publish an item using these details:'**
  String get assistantToolPublishPrompt;

  /// No description provided for @assistantToolEstimatePrompt.
  ///
  /// In en, this message translates to:
  /// **'Estimate a fair campus-market price for this item:'**
  String get assistantToolEstimatePrompt;

  /// No description provided for @agentToolSearchingPosts.
  ///
  /// In en, this message translates to:
  /// **'Flipping through posts…'**
  String get agentToolSearchingPosts;

  /// No description provided for @agentToolInspectingListing.
  ///
  /// In en, this message translates to:
  /// **'Taking a close look at this listing…'**
  String get agentToolInspectingListing;

  /// No description provided for @agentToolFindingRelated.
  ///
  /// In en, this message translates to:
  /// **'Looking for similar posts…'**
  String get agentToolFindingRelated;

  /// No description provided for @agentToolBrowsingUserPosts.
  ///
  /// In en, this message translates to:
  /// **'Seeing what else they posted…'**
  String get agentToolBrowsingUserPosts;

  /// No description provided for @agentToolReadingComments.
  ///
  /// In en, this message translates to:
  /// **'Reading the comments…'**
  String get agentToolReadingComments;

  /// No description provided for @agentToolOrganizingListings.
  ///
  /// In en, this message translates to:
  /// **'Organizing your listings…'**
  String get agentToolOrganizingListings;

  /// No description provided for @agentToolDraftingMessage.
  ///
  /// In en, this message translates to:
  /// **'Drafting a message for you…'**
  String get agentToolDraftingMessage;

  /// No description provided for @agentToolPreparingPublish.
  ///
  /// In en, this message translates to:
  /// **'Preparing your listing…'**
  String get agentToolPreparingPublish;

  /// No description provided for @agentToolPreparingOffer.
  ///
  /// In en, this message translates to:
  /// **'Preparing an offer…'**
  String get agentToolPreparingOffer;

  /// No description provided for @agentToolWorking.
  ///
  /// In en, this message translates to:
  /// **'Working on your request…'**
  String get agentToolWorking;

  /// No description provided for @assistantAgentResultTitle.
  ///
  /// In en, this message translates to:
  /// **'Real posts found by Xiaochang'**
  String get assistantAgentResultTitle;

  /// No description provided for @assistantFallbackCategory.
  ///
  /// In en, this message translates to:
  /// **'Campus post'**
  String get assistantFallbackCategory;

  /// No description provided for @assistantDraftReadyBubble.
  ///
  /// In en, this message translates to:
  /// **'I\'ve drafted it — send after you confirm:'**
  String get assistantDraftReadyBubble;

  /// No description provided for @assistantConfirmSendMessage.
  ///
  /// In en, this message translates to:
  /// **'Confirm sending message'**
  String get assistantConfirmSendMessage;

  /// No description provided for @assistantDraftEditBubble.
  ///
  /// In en, this message translates to:
  /// **'Edit it in the composer before sending'**
  String get assistantDraftEditBubble;

  /// No description provided for @assistantSentBubble.
  ///
  /// In en, this message translates to:
  /// **'Sent!'**
  String get assistantSentBubble;

  /// No description provided for @assistantSendFailedBubble.
  ///
  /// In en, this message translates to:
  /// **'Sending failed — please retry'**
  String get assistantSendFailedBubble;

  /// No description provided for @assistantThinkingBubble.
  ///
  /// In en, this message translates to:
  /// **'Xiaochang is thinking, searching campus memories...'**
  String get assistantThinkingBubble;

  /// No description provided for @assistantIdleReplyBubble.
  ///
  /// In en, this message translates to:
  /// **'Got it! Xiaochang is here whenever you need~'**
  String get assistantIdleReplyBubble;

  /// No description provided for @assistantHistorySheetTitle.
  ///
  /// In en, this message translates to:
  /// **'📜 History & smart memory'**
  String get assistantHistorySheetTitle;

  /// No description provided for @assistantHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get assistantHistoryEmpty;

  /// No description provided for @assistantSuggestionVehicles.
  ///
  /// In en, this message translates to:
  /// **'🚲 Campus bikes'**
  String get assistantSuggestionVehicles;

  /// No description provided for @assistantSuggestionTextbooks.
  ///
  /// In en, this message translates to:
  /// **'📚 Grad-exam textbooks'**
  String get assistantSuggestionTextbooks;

  /// No description provided for @assistantSuggestionGadgets.
  ///
  /// In en, this message translates to:
  /// **'🎒 Gadgets & iPads'**
  String get assistantSuggestionGadgets;

  /// No description provided for @assistantSuggestionOrders.
  ///
  /// In en, this message translates to:
  /// **'📦 My campus orders'**
  String get assistantSuggestionOrders;

  /// No description provided for @assistantComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Talk to Xiaochang — find goods or errands...'**
  String get assistantComposerHint;

  /// No description provided for @assistantHeaderName.
  ///
  /// In en, this message translates to:
  /// **'Xiaochang · Digital human'**
  String get assistantHeaderName;

  /// No description provided for @assistantHeaderTagline.
  ///
  /// In en, this message translates to:
  /// **'Live motion · Memory · Campus assistant'**
  String get assistantHeaderTagline;

  /// No description provided for @assistantHistoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Conversation history'**
  String get assistantHistoryTooltip;

  /// No description provided for @assistantToolsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Assistant tools'**
  String get assistantToolsTooltip;

  /// No description provided for @assistantMemoryEntry.
  ///
  /// In en, this message translates to:
  /// **'Memory & skills'**
  String get assistantMemoryEntry;

  /// No description provided for @assistantConfirmSendReply.
  ///
  /// In en, this message translates to:
  /// **'Confirm posting reply'**
  String get assistantConfirmSendReply;

  /// No description provided for @postDiscoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get postDiscoveryTitle;

  /// No description provided for @postDiscoverySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Discussions and listings from your campus'**
  String get postDiscoverySubtitle;

  /// No description provided for @postFilterAll.
  ///
  /// In en, this message translates to:
  /// **'For you'**
  String get postFilterAll;

  /// No description provided for @postFilterDiscussion.
  ///
  /// In en, this message translates to:
  /// **'Discussions'**
  String get postFilterDiscussion;

  /// No description provided for @postFilterListing.
  ///
  /// In en, this message translates to:
  /// **'Listings'**
  String get postFilterListing;

  /// No description provided for @postSortLatest.
  ///
  /// In en, this message translates to:
  /// **'Latest'**
  String get postSortLatest;

  /// No description provided for @postSortActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get postSortActive;

  /// No description provided for @postSortReplies.
  ///
  /// In en, this message translates to:
  /// **'Most replied'**
  String get postSortReplies;

  /// No description provided for @postTypeDiscussion.
  ///
  /// In en, this message translates to:
  /// **'Discussion'**
  String get postTypeDiscussion;

  /// No description provided for @postTypeListing.
  ///
  /// In en, this message translates to:
  /// **'Listing'**
  String get postTypeListing;

  /// No description provided for @postAnonymousAuthor.
  ///
  /// In en, this message translates to:
  /// **'Campus member'**
  String get postAnonymousAuthor;

  /// No description provided for @postCreateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Start a discussion'**
  String get postCreateTooltip;

  /// No description provided for @postCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'Start a discussion'**
  String get postCreateTitle;

  /// No description provided for @postCreateIntro.
  ///
  /// In en, this message translates to:
  /// **'Share a campus question, guide, or idea. To sell or request an item, use the listing publisher so price and condition stay structured.'**
  String get postCreateIntro;

  /// No description provided for @postTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get postTitleLabel;

  /// No description provided for @postTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Summarize what you want to discuss'**
  String get postTitleHint;

  /// No description provided for @postTitleRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a title'**
  String get postTitleRequired;

  /// No description provided for @postBodyLabel.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get postBodyLabel;

  /// No description provided for @postBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Add context that will help classmates respond'**
  String get postBodyHint;

  /// No description provided for @postBodyRequired.
  ///
  /// In en, this message translates to:
  /// **'Add some details'**
  String get postBodyRequired;

  /// No description provided for @postCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get postCategoryLabel;

  /// No description provided for @postCategoryHint.
  ///
  /// In en, this message translates to:
  /// **'For example: Campus life'**
  String get postCategoryHint;

  /// No description provided for @postTagsLabel.
  ///
  /// In en, this message translates to:
  /// **'Tags (optional)'**
  String get postTagsLabel;

  /// No description provided for @publishCategoryOffer.
  ///
  /// In en, this message translates to:
  /// **'Offer'**
  String get publishCategoryOffer;

  /// No description provided for @publishCategoryWanted.
  ///
  /// In en, this message translates to:
  /// **'Wanted'**
  String get publishCategoryWanted;

  /// No description provided for @publishCategoryDiscussion.
  ///
  /// In en, this message translates to:
  /// **'Discussion'**
  String get publishCategoryDiscussion;

  /// No description provided for @publishGoodsSection.
  ///
  /// In en, this message translates to:
  /// **'Item details (creates a listing)'**
  String get publishGoodsSection;

  /// No description provided for @publishPriceRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid price'**
  String get publishPriceRequired;

  /// No description provided for @postTagsHint.
  ///
  /// In en, this message translates to:
  /// **'Separate up to five tags with spaces or commas'**
  String get postTagsHint;

  /// No description provided for @postPublishAction.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get postPublishAction;

  /// No description provided for @postKindDiscussion.
  ///
  /// In en, this message translates to:
  /// **'Discussion'**
  String get postKindDiscussion;

  /// No description provided for @postKindMutualAid.
  ///
  /// In en, this message translates to:
  /// **'Mutual aid'**
  String get postKindMutualAid;

  /// No description provided for @postMutualAidNotes.
  ///
  /// In en, this message translates to:
  /// **'Additional details'**
  String get postMutualAidNotes;

  /// No description provided for @postPublishFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not publish the discussion. Try again.'**
  String get postPublishFailed;

  /// No description provided for @postDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Discussion'**
  String get postDetailTitle;

  /// No description provided for @postLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load this discussion.'**
  String get postLoadFailed;

  /// No description provided for @postRepliesTitle.
  ///
  /// In en, this message translates to:
  /// **'Replies'**
  String get postRepliesTitle;

  /// No description provided for @postThreadOrder.
  ///
  /// In en, this message translates to:
  /// **'Oldest first'**
  String get postThreadOrder;

  /// No description provided for @postNoReplies.
  ///
  /// In en, this message translates to:
  /// **'No replies yet. Add the first helpful response.'**
  String get postNoReplies;

  /// No description provided for @postLockedNotice.
  ///
  /// In en, this message translates to:
  /// **'This discussion is closed to new replies.'**
  String get postLockedNotice;

  /// No description provided for @postReplyHint.
  ///
  /// In en, this message translates to:
  /// **'Write a constructive reply…'**
  String get postReplyHint;

  /// No description provided for @postReplyAction.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get postReplyAction;

  /// No description provided for @postReplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not send your reply. Try again.'**
  String get postReplyFailed;

  /// No description provided for @postReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to {username}'**
  String postReplyingTo(String username);

  /// No description provided for @postLinkedListing.
  ///
  /// In en, this message translates to:
  /// **'Marketplace listing'**
  String get postLinkedListing;

  /// No description provided for @postViewListing.
  ///
  /// In en, this message translates to:
  /// **'View item'**
  String get postViewListing;

  /// No description provided for @listingDiscussionAction.
  ///
  /// In en, this message translates to:
  /// **'Open discussion'**
  String get listingDiscussionAction;

  /// No description provided for @listingDiscussionHint.
  ///
  /// In en, this message translates to:
  /// **'This product is also a post. Read or join its campus discussion.'**
  String get listingDiscussionHint;

  /// No description provided for @postEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get postEmptyTitle;

  /// No description provided for @postEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Start a useful campus conversation and classmates can build the thread with you.'**
  String get postEmptyBody;

  /// No description provided for @postEmptyListingBody.
  ///
  /// In en, this message translates to:
  /// **'No marketplace posts match this filter yet.'**
  String get postEmptyListingBody;

  /// No description provided for @postStartAction.
  ///
  /// In en, this message translates to:
  /// **'Start a discussion'**
  String get postStartAction;
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
