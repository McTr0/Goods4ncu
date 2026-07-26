// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get aiAssistantTab => 'AI Assistant';

  @override
  String get aiError => 'Sorry, something went wrong. Please try again.';

  @override
  String get aiGreeting =>
      'Hello! I\'m your campus secondhand trading assistant. How can I help you today?';

  @override
  String get aiWillAutoRecognize => 'AI will auto-recognize item info';

  @override
  String get allCategories => 'All';

  @override
  String get appTitle => 'Campus Marketplace';

  @override
  String get brand => 'Brand';

  @override
  String get brandLabel => 'Brand';

  @override
  String get books => 'Books';

  @override
  String get buyNow => 'Start deal intent';

  @override
  String get buyer => 'Buyer';

  @override
  String get cancel => 'Cancel';

  @override
  String get category => 'Category';

  @override
  String get categoryLabel => 'Category';

  @override
  String get chinese => 'Chinese (Simplified)';

  @override
  String get chat => 'Chat';

  @override
  String get chatWithSelf => 'Cannot chat with yourself';

  @override
  String get clothingShoes => 'Clothing & Shoes';

  @override
  String get comingSoon => 'Coming soon...';

  @override
  String get condition => 'Condition';

  @override
  String get conditionLabel => 'Condition';

  @override
  String get confirm => 'Confirm';

  @override
  String get confirmPassword => 'Confirm Password';

  @override
  String get connectionFailedRetry =>
      'Connection failed, please try again later';

  @override
  String get connectionRequestSent =>
      'Connection request sent, waiting for acceptance';

  @override
  String get contactSeller => 'Contact Seller';

  @override
  String get counterOfferAmount => 'Counter offer amount';

  @override
  String counterOfferBySeller(String amount) {
    return 'Seller counter-offered ¥$amount';
  }

  @override
  String get createError => 'Failed to create listing';

  @override
  String get createListing => 'Create Listing';

  @override
  String get createListingAiNeedsRetry => 'Needs retry';

  @override
  String get createListingAiReady => 'AI recognition complete';

  @override
  String get createListingAiRecognizing => 'Assistant is recognizing...';

  @override
  String get createListingAiSubtitle =>
      'Take or upload a photo, and the assistant will draft the title, category, brand, and condition for you to confirm.';

  @override
  String get createListingAiTitle => 'Let the assistant take a look first';

  @override
  String get createListingModeOffer => 'I am offering';

  @override
  String get createListingModeWanted => 'I am looking for';

  @override
  String get createWantedPanelTitle => 'Describe what you want';

  @override
  String get createWantedPanelSubtitle =>
      'Add budget, minimum condition, and the details you care about. The system will match classmates\' active offers.';

  @override
  String get createListingBasicInfo => 'Listing basics';

  @override
  String get createListingBasicInfoSubtitle =>
      'These details decide whether classmates will open the listing.';

  @override
  String get createWantedBasicInfo => 'Wanted basics';

  @override
  String get createWantedBasicInfoSubtitle =>
      'A clear request helps classmates know whether their item matches.';

  @override
  String get createListingBrandHint => 'For example: Apple, Casio, NCU';

  @override
  String get createWantedBrandLabel => 'Preferred brand';

  @override
  String get createWantedBrandHint => 'Any, or for example: Apple, Casio';

  @override
  String get createListingBrandRequired => 'Please enter the brand or source';

  @override
  String get createListingChangeImage => 'Change image';

  @override
  String get createListingConditionSection => 'Condition & defects';

  @override
  String get createListingConditionSubtitle =>
      'Being clear about flaws makes the listing easier to trust.';

  @override
  String get createWantedConditionSection => 'Minimum requirements';

  @override
  String get createWantedConditionSubtitle =>
      'Set the lowest condition and notes you can accept.';

  @override
  String get createListingDefectHint => 'For example: minor screen scratch';

  @override
  String get createWantedRequirementHint =>
      'For example: charger included, minor scratches acceptable';

  @override
  String get createWantedRequirementsLabel => 'Requirements / notes';

  @override
  String get createWantedBudgetLabel => 'Budget ceiling (CNY) *';

  @override
  String get createListingDescriptionHint =>
      'Describe purchase time, usage, accessories, pickup location, etc...';

  @override
  String get createListingDescriptionLabel => 'Description (optional)';

  @override
  String get createListingDescriptionSection => 'Extra details';

  @override
  String get createListingDescriptionSubtitle =>
      'Optional, but concrete details reduce back-and-forth.';

  @override
  String get createWantedDescriptionHint =>
      'Describe how you will use it, pickup preference, and deal breakers...';

  @override
  String get createWantedDescriptionLabel => 'Wanted description (optional)';

  @override
  String get createWantedDescriptionSection => 'Extra request details';

  @override
  String get createWantedDescriptionSubtitle =>
      'Optional, but details help you get better recommendations.';

  @override
  String createListingMissingFields(String fields) {
    return 'Missing $fields';
  }

  @override
  String get createListingPriceInvalid => 'Please enter a valid price number';

  @override
  String get createListingPriceLabel => 'Price (CNY) *';

  @override
  String get createListingPriceRequired => 'Please enter a price';

  @override
  String get createListingProgressBasics => 'Basics complete';

  @override
  String get createListingProgressCondition => 'Condition confirmed';

  @override
  String get createListingProgressDescription => 'Extra details';

  @override
  String get createListingProgressImage => 'Image-assisted recognition';

  @override
  String get createListingProgressSubtitle =>
      'Follow this rhythm and the listing will stay tidy.';

  @override
  String get createListingProgressTitle => 'Publish progress';

  @override
  String get createListingReadyHint => 'Everything is ready to publish';

  @override
  String get createListingTitleHint => 'For example: iPhone 13 Pro Max 256G';

  @override
  String get createWantedTitleHint =>
      'For example: Looking for an iPad Air or similar tablet';

  @override
  String get createSuccess => 'Listing created successfully';

  @override
  String get dailyGoods => 'Daily Goods';

  @override
  String get defects => 'Defects';

  @override
  String get defectsLabel => 'Defects';

  @override
  String get delete => 'Delete';

  @override
  String get deleteConfirm => 'Are you sure you want to delete this listing?';

  @override
  String get removeFavoriteConfirm => 'Remove this item from favorites?';

  @override
  String get favoriteRemoved => 'Removed from favorites';

  @override
  String get undo => 'Undo';

  @override
  String get description => 'Description';

  @override
  String get descriptionLabel => 'Description';

  @override
  String get digitalAccessories => 'Digital Accessories';

  @override
  String get edit => 'Edit';

  @override
  String get electronics => 'Electronics';

  @override
  String get english => 'English';

  @override
  String get enterValidCounterAmount =>
      'Please enter a valid counter offer amount';

  @override
  String get error => 'Error';

  @override
  String get fromGallery => 'From gallery';

  @override
  String get homeTab => 'Home';

  @override
  String get language => 'Language';

  @override
  String get listSeparator => ', ';

  @override
  String get listingDirectionAll => 'All';

  @override
  String get listingDirectionOffer => 'Offer';

  @override
  String get listingDirectionWanted => 'Wanted';

  @override
  String get listingDetail => 'Listing Details';

  @override
  String loadFailed(String error) {
    return 'Load failed: $error';
  }

  @override
  String get loading => 'Loading...';

  @override
  String get loadMore => 'Load more';

  @override
  String get login => 'Login';

  @override
  String get loginError => 'Login error';

  @override
  String get loginSuccess => 'Login successful';

  @override
  String get logout => 'Logout';

  @override
  String get logoutConfirm => 'Are you sure you want to logout?';

  @override
  String get logoutSuccess => 'Logout successful';

  @override
  String memberSince(String date) {
    return 'Member since $date';
  }

  @override
  String get messagesTab => 'Messages';

  @override
  String get notificationsCenter => 'Notifications';

  @override
  String get notificationsCenterSubtitle => 'System messages and reminders';

  @override
  String get myFavorites => 'My Favorites';

  @override
  String get myFavoritesSubtitle => 'Your favorite items';

  @override
  String get watchlistEmpty => 'No favorites yet';

  @override
  String get notificationsEmpty => 'No notifications for now';

  @override
  String get markAllRead => 'Mark all as read';

  @override
  String get markAllReadSuccess => 'All notifications marked as read';

  @override
  String get myListings => 'My Listings';

  @override
  String get myListingsMenu => 'View and manage your listings';

  @override
  String get myListingsTab => 'My Listings';

  @override
  String get myOrders => 'Deal Records';

  @override
  String get myOrdersSubtitle => 'View offline deal intents and confirmations';

  @override
  String get allOrders => 'All';

  @override
  String get allNotifications => 'All';

  @override
  String get unreadOnly => 'Unread';

  @override
  String get buyerOrders => 'Wanted by Me';

  @override
  String get sellerOrders => 'Offered by Me';

  @override
  String get orderAsBuyer => 'Wanted';

  @override
  String get orderAsSeller => 'Offered';

  @override
  String get pay => 'Pay';

  @override
  String get markPaid => 'Intent confirmed';

  @override
  String get reason => 'Reason (optional)';

  @override
  String get negotiationDetails => 'Negotiation details';

  @override
  String get negotiationExpired => 'Negotiation expired and cancelled';

  @override
  String get connectionAccepted => 'Connection accepted';

  @override
  String get connectionRejected => 'Connection rejected';

  @override
  String get negotiationRejected => 'Negotiation rejected';

  @override
  String get noProducts => 'No products available';

  @override
  String get notFound => 'Not found';

  @override
  String operationFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String get other => 'Other';

  @override
  String get optional => 'optional';

  @override
  String get owner => 'Owner';

  @override
  String get pendingNegotiation => 'Pending negotiation';

  @override
  String get password => 'Password';

  @override
  String get price => 'Price';

  @override
  String get priceLabel => 'Price';

  @override
  String get wantedBudgetShort => 'Budget';

  @override
  String get wantedMinimumCondition => 'Minimum condition';

  @override
  String get wantedRequester => 'Requester';

  @override
  String get wantedMatchesTitle => 'Matching offers';

  @override
  String get contactRequester => 'Contact requester';

  @override
  String get recommendMyOffer => 'Recommend my offer';

  @override
  String get wantedOwnerHint => 'This is your own request';

  @override
  String get wantedNoOfferToRecommend =>
      'You do not have an active offer to recommend';

  @override
  String get wantedRecommendSuccess => 'Recommended to the requester';

  @override
  String get profile => 'Profile';

  @override
  String get profileLoadFailed => 'Failed to load profile';

  @override
  String get profileTab => 'Profile';

  @override
  String get campusMembershipVerified => 'Campus verified';

  @override
  String get campusMembershipPending => 'Verification pending';

  @override
  String get campusMembershipSuspended => 'Membership suspended';

  @override
  String get campusMembershipRevoked => 'Membership revoked';

  @override
  String get campusEmail => 'Campus email';

  @override
  String get campusEmailHint => 'student-id@email.ncu.edu.cn';

  @override
  String get campusEmailRequired => 'A campus email is required to register';

  @override
  String get verifyCampusIdentity => 'Verify campus identity';

  @override
  String get campusVerificationSendHint =>
      'We will send a code to your current campus email. It expires in 5 minutes.';

  @override
  String get sendVerificationCode => 'Send verification code';

  @override
  String get verificationCodeSent => 'Code sent. Check your campus inbox.';

  @override
  String get verificationCode => '6-digit code';

  @override
  String get confirmVerification => 'Confirm verification';

  @override
  String get campusVerificationSuccess => 'Campus identity verified';

  @override
  String get campusSwitchTitle => 'Switch active campus';

  @override
  String get campusSwitchDescription =>
      'Browsing, publishing, and communication stay within this campus. Each device can choose independently.';

  @override
  String get campusActive => 'Active campus';

  @override
  String get campusSwitchSuccess => 'Active campus switched';

  @override
  String get publishTab => 'Publish';

  @override
  String get purchaseFailed => 'Purchase failed, please try again';

  @override
  String get purchaseSuccess =>
      'Deal intent sent. Waiting for seller confirmation.';

  @override
  String recognitionFailed(String error) {
    return 'Recognition failed: $error';
  }

  @override
  String get recognitionSuccess => 'Recognition successful, info auto-filled';

  @override
  String get register => 'Register';

  @override
  String get registerError => 'Registration error';

  @override
  String get registerSuccess => 'Registration successful';

  @override
  String requestFailed(int code) {
    return 'Request failed: $code';
  }

  @override
  String get retry => 'Retry';

  @override
  String get searchHint => 'Search products...';

  @override
  String get sellerAcceptedDealComplete => 'Seller accepted, deal complete';

  @override
  String get sellerCounterOffered => 'Seller counter-offered';

  @override
  String get send => 'Send';

  @override
  String get sessionExpired => 'Session expired. Please login again.';

  @override
  String get settings => 'Settings';

  @override
  String get settingsSubtitle => 'App settings';

  @override
  String get nickname => 'Nickname';

  @override
  String get nicknameChange => 'Change nickname';

  @override
  String get nicknameChangeSuccess => 'Nickname updated';

  @override
  String get nicknameChangeHint =>
      'Others will see your new nickname after update';

  @override
  String get nicknameConflict => 'This nickname is already taken';

  @override
  String get nicknameEmpty => 'Nickname cannot be empty';

  @override
  String get userAgreement => 'User Agreement';

  @override
  String get userAgreementTitle => 'User Agreement & Terms';

  @override
  String get userAgreementSubtitle =>
      'Understand platform rules and usage responsibilities.';

  @override
  String get sold => 'Sold';

  @override
  String get status => 'Status';

  @override
  String get submit => 'Submit';

  @override
  String get takePhoto => 'Take photo';

  @override
  String get tapCameraIconHint =>
      'Tap camera icon to take photo or select image';

  @override
  String get title => 'Title';

  @override
  String get titleRequired => 'Title is required';

  @override
  String totalListings(int count) {
    return '$count listings';
  }

  @override
  String get tradeProtection => 'Offline deal reminder';

  @override
  String get tradeProtectionSubtitle =>
      'The platform does not escrow funds. Confirm inspection, handoff, and payment with each other.';

  @override
  String get typeMessage => 'Type a message...';

  @override
  String get uploadFromCamera => 'Upload from camera';

  @override
  String get uploadFromGallery => 'Upload from gallery';

  @override
  String get username => 'Username';

  @override
  String get adminConsole => 'Admin Console';

  @override
  String get adminConsoleSubtitle => 'System overview & management';

  @override
  String get adminOnly => 'Admin only';

  @override
  String get adminStatsTab => 'Stats';

  @override
  String get adminListingsTab => 'Listings';

  @override
  String get adminOrdersTab => 'Deal Records';

  @override
  String get adminUsersTab => 'Users';

  @override
  String get adminTotalListings => 'Total Listings';

  @override
  String get adminActive => 'Active';

  @override
  String get adminUsers => 'Users';

  @override
  String get adminOrders => 'Deal Records';

  @override
  String get adminTrend7Days => 'Trend (7 days)';

  @override
  String get changeRole => 'Change Role';

  @override
  String get markShipped => 'Confirm deal';

  @override
  String get markCompleted => 'Deal confirmed';

  @override
  String get orderStatusUpdated => 'Deal record updated';

  @override
  String get userRoleUpdated => 'User role updated';

  @override
  String get adminTakedown => 'Takedown';

  @override
  String get adminTakedownConfirm => 'Confirm Takedown';

  @override
  String adminTakedownConfirmMessage(String title) {
    return 'Are you sure you want to takedown \"$title\"?';
  }

  @override
  String get adminTakedownSuccess => 'Listing taken down';

  @override
  String get adminBan => 'Ban';

  @override
  String get adminBanConfirm => 'Confirm Ban';

  @override
  String get adminBanConfirmMessage =>
      'Are you sure you want to ban this user? All their sessions will be terminated.';

  @override
  String get adminBanSuccess => 'User banned';

  @override
  String get adminUnban => 'Unban';

  @override
  String get adminUnbanSuccess => 'User unbanned';

  @override
  String get adminSearchListingsPlaceholder => 'Search listings...';

  @override
  String get adminSearchUsersPlaceholder => 'Search users...';

  @override
  String get adminNoUsersFound => 'No users found';

  @override
  String get adminNoListingsFound => 'No listings found';

  @override
  String get adminSensitiveActionsLocked => 'Sensitive actions are locked';

  @override
  String get adminSensitiveActionsLockedSubtitle =>
      'Viewing is unaffected. Bans, takedowns, role changes, and moderation decisions require password verification.';

  @override
  String get adminUnlockActions => 'Verify and unlock';

  @override
  String get adminReauthenticateTitle => 'Verify administrator identity';

  @override
  String get adminReauthenticateHint =>
      'Sensitive actions stay unlocked for 10 minutes';

  @override
  String get adminTotpCodeLabel => 'Authenticator code (if enabled)';

  @override
  String get adminTotpCodeHint => '6-digit code from your authenticator app';

  @override
  String get agentPlanPendingHeader =>
      'Pending actions (proposed by assistant, run only after you confirm)';

  @override
  String get agentPlanConfirmAction => 'Confirm';

  @override
  String get undoDoneHeader => 'Done — you can still undo';

  @override
  String get undoAction => 'Undo';

  @override
  String undoRemainingSeconds(int seconds) {
    return '${seconds}s left';
  }

  @override
  String get undoSucceeded => 'Undone';

  @override
  String get undoConflict => 'Could not undo';

  @override
  String get undoFailed => 'Undo failed, please try again';

  @override
  String get intentPageTitle => 'What I want';

  @override
  String get intentComposerPrompt =>
      'Say it however you like — no form. Selling, looking for something, looking for someone, asking a favour, or planning something.';

  @override
  String get intentComposerHint =>
      'e.g. Clearing out my dorm, will take whatever for the mini fridge / Looking for someone to play badminton with';

  @override
  String get intentKindGoodsOffer => 'Selling';

  @override
  String get intentKindGoodsSeek => 'Looking for';

  @override
  String get intentKindCompanion => 'Looking for company';

  @override
  String get intentKindHelp => 'Asking a favour';

  @override
  String get intentKindActivity => 'Planning something';

  @override
  String get intentPriceWhatever => 'Whatever you\'ll give me';

  @override
  String get intentPriceFree => 'Giving it away';

  @override
  String get intentPriceFlexible => 'Price open';

  @override
  String get intentTimeFlexible => 'Any time';

  @override
  String get intentSubmit => 'Post it';

  @override
  String get intentSaving => 'Saving…';

  @override
  String get intentSaved => 'Noted — you\'ll hear if something fits';

  @override
  String get intentSavedNotListed =>
      'Noted. Without a price it won\'t appear in the browse grid, but it will still be matched';

  @override
  String get intentMineHeader => 'What I\'ve said';

  @override
  String get intentMineEmpty => 'Nothing yet. One sentence above is enough.';

  @override
  String get intentDraftBadge => 'Awaiting your confirmation';

  @override
  String get intentConfirmDraft => 'Confirm';

  @override
  String get intentNoMatchesYet => 'Nothing fits yet';

  @override
  String get intentFulfilAction => 'Sorted';

  @override
  String get intentWithdrawAction => 'Never mind';

  @override
  String get intentFulfilled => 'Marked as sorted';

  @override
  String get intentWithdrawn => 'Withdrawn';

  @override
  String get intentFeedHeader => 'What people are looking for';

  @override
  String get intentFeedEmpty =>
      'Nobody is looking for anything yet. Say something first so others can see it.';

  @override
  String get intentRespondAction => 'I can help';

  @override
  String get intentRespondTitle => 'Reply';

  @override
  String get intentRespondHint => 'Say what you have, or how you can help';

  @override
  String get intentRespondSend => 'Send';

  @override
  String get intentRespondSent => 'Sent — they\'ll see it in their messages';

  @override
  String intentMatchCount(int count) {
    return '$count possible match(es)';
  }

  @override
  String get agentPlanExecuted => 'Action executed';

  @override
  String get agentPlanCancelled => 'Action cancelled';

  @override
  String get fulfillWantedAction => 'Mark fulfilled';

  @override
  String get reopenWantedAction => 'Reopen request';

  @override
  String get wantedFulfilledHint =>
      'This request is fulfilled and no longer receives matches';

  @override
  String get wantedFulfilledToast => 'Request marked fulfilled';

  @override
  String get wantedReopenedToast => 'Request reopened';

  @override
  String get agentPlanSecondConfirmTitle => 'High-risk action — confirm again';

  @override
  String get agentPlanSecondConfirmAction => 'Confirm and run';

  @override
  String get adminReauthenticateSuccess =>
      'Administrator verified. Sensitive actions are temporarily unlocked.';

  @override
  String get adminLoginAs => 'Login as user';

  @override
  String adminLoginAsSuccess(String username) {
    return 'Logged in as $username';
  }

  @override
  String get adminLoginAsFailed => 'Login failed';

  @override
  String get adminLoginAsConfirm => 'Confirm';

  @override
  String get adminLoginAsWarning =>
      'You are about to switch to this user\'s identity';

  @override
  String get adminViewListings => 'View Listings';

  @override
  String get orderId => 'Record ID';

  @override
  String get orderDetail => 'Deal Details';

  @override
  String get dealParties => 'Participants';

  @override
  String get dealTimeline => 'Deal Timeline';

  @override
  String get noOrders => 'No deal records';

  @override
  String get conditionLikeNew => 'Like New';

  @override
  String get conditionGood => 'Good';

  @override
  String get conditionFair => 'Fair';

  @override
  String get conditionPoor => 'Poor';

  @override
  String get buyerInitiatedNegotiation => 'Buyer initiated negotiation';

  @override
  String get cannotContactSeller =>
      'Unable to contact seller: missing seller info';

  @override
  String get itemAlreadyPurchased =>
      'Oops, this item is too popular, someone beat you to it!';

  @override
  String get unknown => 'Unknown';

  @override
  String get idLabel => 'ID:';

  @override
  String get ownerIdLabel => 'Owner ID:';

  @override
  String orderNumber(String id) {
    return 'Deal record #$id';
  }

  @override
  String get joinedLabel => 'Joined:';

  @override
  String get roleLabel => 'Role:';

  @override
  String unbanConfirmMessage(String username) {
    return 'Are you sure you want to unban user \"$username\"?';
  }

  @override
  String get adminLoginAsAuditLogWarning =>
      'This operation will log in as the selected user and leave an audit log. Continue?';

  @override
  String impersonationFailed(String error) {
    return 'Impersonation failed: $error';
  }

  @override
  String get infoDisclaimer =>
      'This product is for information publishing only, with no guarantee, no fund intermediary, and no transaction fees.';

  @override
  String get aboutPlatform => 'About This Platform';

  @override
  String get aboutPlatformSubtitle =>
      'How this platform works and key safety notice.';

  @override
  String get infoPublishing => 'Information Publishing';

  @override
  String get infoPublishingDesc =>
      'This platform is for information publishing only. Users share listing information through posts. No transactions or payments occur on this platform.';

  @override
  String get contactThroughChat => 'Contact Through Chat';

  @override
  String get contactThroughChatDesc =>
      'Contact sellers directly through the in-app chat feature. Communicate details and arrange transactions offline.';

  @override
  String get safetyTips => 'Safety Tips';

  @override
  String get safetyTipsDesc =>
      'Meet in safe public places when exchanging items. Verify item condition before completing any offline arrangement.';

  @override
  String get platformDisclaimer =>
      'This platform serves as an information listing service only. Any offline transactions are at your own risk. Please stay vigilant and protect your personal safety and property.';

  @override
  String get recommendedForYou => 'For You';

  @override
  String get similarRecommendations => 'Similar Items';

  @override
  String get camera => 'Camera';

  @override
  String get gallery => 'Gallery';

  @override
  String get uploading => 'Uploading';

  @override
  String get avatarUpdated => 'Avatar updated';

  @override
  String get uploadFailed => 'Upload failed';

  @override
  String get emailLabel => 'Email';

  @override
  String get emailChange => 'Change Email';

  @override
  String get emailChangeHint => 'Enter @email.ncu.edu.cn email';

  @override
  String get emailDomainError => 'Enter a valid campus email address';

  @override
  String get emailChangeSuccess => 'Email updated';

  @override
  String get notSet => 'Not set';

  @override
  String get homeHeroEyebrow => 'Goods4ncu Campus Market';

  @override
  String get homeHeroTitle => 'What are you looking for today?';

  @override
  String get homeHeroSubtitle =>
      'Tell Xiaobang what you need, your budget, or how you plan to use it. You can also keep scrolling through what classmates just listed.';

  @override
  String get homePromptHint =>
      'Find textbooks, lightweight laptops, or ask Xiaobang to help sell an item...';

  @override
  String get homePromptSubmitTooltip => 'Ask Xiaobang';

  @override
  String get homeSuggestionTitle => 'Try starting with';

  @override
  String get homeThoughtLaptopLabel => 'Find a laptop';

  @override
  String get homeThoughtLaptopPrompt =>
      'My budget is 3000 yuan. Help me find a lightweight laptop for coding and carrying to class.';

  @override
  String get homeThoughtPriceLabel => 'Price my item';

  @override
  String get homeThoughtPricePrompt =>
      'I have an unused item to sell. Ask me a few questions first, then estimate a fair price.';

  @override
  String get homeThoughtCopyLabel => 'Write listing copy';

  @override
  String get homeThoughtCopyPrompt =>
      'Help me organize the item details step by step and write an honest, trustworthy listing.';

  @override
  String get homeThoughtNegotiateLabel => 'Negotiate politely';

  @override
  String get homeThoughtNegotiatePrompt =>
      'Help me find worthwhile digital items and start a polite negotiation when the price makes sense.';

  @override
  String get homeRecentTitle => 'Recently Listed';

  @override
  String get homeRecentSubtitle => 'See what classmates are selling right now.';

  @override
  String get conversationLoadFailedTitle => 'Messages could not load';

  @override
  String get conversationEmptyTitle => 'No conversations yet';

  @override
  String get conversationEmptySubtitle =>
      'Contact someone from a listing, or search for a classmate to start a conversation.';

  @override
  String get findClassmate => 'Find classmate';

  @override
  String conversationWaitingCount(int count) {
    return 'Awaiting your reply · $count';
  }

  @override
  String get conversationFilterAll => 'All';

  @override
  String get conversationFilterRealtime => 'Realtime';

  @override
  String get conversationFilterMail => 'Mail';

  @override
  String get lookupDialogTitle => 'Find classmate';

  @override
  String get lookupDialogSubtitle =>
      'Enter a username, full email, or student ID. If they turned off that discovery method, they will not appear here.';

  @override
  String get lookupFieldLabel => 'Search value';

  @override
  String get lookupFieldHint =>
      'e.g. Alex / 2024123456 / name@email.ncu.edu.cn';

  @override
  String get lookupMethodLabel => 'Search by';

  @override
  String get lookupMethodAuto => 'Auto detect';

  @override
  String get lookupMethodUsername => 'Username';

  @override
  String get lookupMethodStudentId => 'Student ID';

  @override
  String get lookupMethodEmail => 'Email';

  @override
  String get lookupSearchAction => 'Search';

  @override
  String get lookupHint =>
      'Tip: email and student ID must be entered fully. Whether someone can be found is controlled by their settings.';

  @override
  String get lookupEmpty =>
      'No contactable user found. The input may be incomplete, or the other user may not have enabled this discovery method.';

  @override
  String lookupMatchedWithListings(String method, int count) {
    return 'Matched by $method · $count active listings';
  }

  @override
  String lookupMatchedIdentifierWithListings(
    String method,
    String identifier,
    int count,
  ) {
    return 'Matched by $method: $identifier · $count active listings';
  }

  @override
  String get viewClassmateListings => 'View listings';

  @override
  String get contactAction => 'Contact';

  @override
  String classmateActiveListingsTitle(String username) {
    return '$username\'s listings';
  }

  @override
  String get classmateListingsLoadFailedTitle => 'Listings could not load';

  @override
  String get classmateListingsEmptyTitle => 'No active listings';

  @override
  String get classmateListingsEmptySubtitle =>
      'This user does not have public active listings right now.';

  @override
  String get unnamedListing => 'Untitled listing';

  @override
  String listingPriceLine(String category, String price) {
    return '$category · ¥$price';
  }

  @override
  String get assistantName => 'Xiaobang';

  @override
  String get assistantSystemBadge => 'AI Assistant';

  @override
  String get assistantInboxSubtitle =>
      'Find items, price, publish, and negotiate from here';

  @override
  String get assistantHeaderSubtitle =>
      'Your campus trading assistant · important decisions ask for your confirmation first';

  @override
  String get assistantHistoryLoadFailed =>
      'History could not load. You can still keep asking Xiaobang.';

  @override
  String get assistantTyping => 'AI is typing...';

  @override
  String recordingStatus(int seconds) {
    return 'Recording ${seconds}s / 60s';
  }

  @override
  String get viewAction => 'View';

  @override
  String get invitationFallbackTitle => 'Wants to chat with you now';

  @override
  String get declineNow => 'Not now';

  @override
  String get connectNow => 'Connect';

  @override
  String get modeRealtime => 'Realtime';

  @override
  String get modeMail => 'Mail';

  @override
  String get conversationStateDelivered => 'Delivered';

  @override
  String get conversationStateSynSent => 'Waiting for them to connect';

  @override
  String get conversationStateSynAck =>
      'They replied, waiting for confirmation';

  @override
  String get conversationStateActive => 'This conversation is connected';

  @override
  String get conversationStateDeclined => 'This time did not connect';

  @override
  String get conversationStateCancelled => 'Invitation cancelled';

  @override
  String get conversationStateExpired => 'This conversation has ended';

  @override
  String get conversationStateClosed => 'This conversation is closed';

  @override
  String get conversationChooseTitle => 'Choose a conversation';

  @override
  String get conversationChooseSubtitle =>
      'Realtime conversations and mail threads stay clearly separated here.';

  @override
  String get contactModePromptTitle => 'How would you like to reach out?';

  @override
  String contactContextUser(String username) {
    return 'Contact $username';
  }

  @override
  String contactContextListing(String title) {
    return 'About \"$title\"';
  }

  @override
  String get contactFallbackUser => 'this classmate';

  @override
  String get contactModeRealtimeTitle => 'Chat now';

  @override
  String get contactModeRealtimeDescription =>
      'Send a 10-minute realtime invite. The conversation starts once they connect.';

  @override
  String get contactModeMailTitle => 'Leave a message';

  @override
  String get contactModeMailDescription =>
      'Deliver it directly without online, typing, or read indicators.';

  @override
  String get contactOpeningRequired =>
      'Please write what you want to say first.';

  @override
  String get contactMailSubjectRequired => 'Mail needs a subject.';

  @override
  String get contactRealtimeComposerTitle => 'Start a realtime invite';

  @override
  String get contactMailComposerTitle => 'Leave a message';

  @override
  String get contactMailSubjectLabel => 'Subject';

  @override
  String get contactMailSubjectHint => 'e.g. Asking about condition';

  @override
  String get contactMailBodyLabel => 'Body';

  @override
  String get contactRealtimeOpeningLabel =>
      'They will see this before connecting';

  @override
  String get contactMailBodyHint =>
      'Share your question and when it is convenient to reply...';

  @override
  String get contactRealtimeOpeningHint => 'Hi, is this item still available?';

  @override
  String get contactMailSubmit => 'Deliver message';

  @override
  String get contactRealtimeSubmit => 'Wait for them to connect';

  @override
  String get publicProfile => 'Classmate Profile';

  @override
  String get myPublicProfile => 'My public profile';

  @override
  String get myPublicProfileSubtitle => 'Preview how others see your profile.';

  @override
  String get viewPublicProfile => 'View profile';

  @override
  String get publicProfileLoadFailed => 'Profile could not load';

  @override
  String get publicProfileListingsTitle => 'Active listings';

  @override
  String get publicProfileListingsEmpty => 'No active listings right now.';

  @override
  String get paymentQrSectionTitle => 'Offline payment QR codes';

  @override
  String get paymentQrSectionSubtitle =>
      'Shown only when the user chooses to make them public. The platform does not process, verify, or escrow payments.';

  @override
  String get paymentQrPublicNotice =>
      'Use only after you have confirmed the item and seller. Offline payments are arranged between users.';

  @override
  String get wechatPayQr => 'WeChat Pay';

  @override
  String get alipayQr => 'Alipay';

  @override
  String get paymentQrSettingsTitle => 'Payment QR codes';

  @override
  String get paymentQrSettingsSubtitle =>
      'Optional. These are displayed on your public profile only after you turn them on.';

  @override
  String get uploadWechatQr => 'Upload WeChat Pay code';

  @override
  String get uploadAlipayQr => 'Upload Alipay code';

  @override
  String get showWechatQr => 'Show WeChat Pay code';

  @override
  String get showAlipayQr => 'Show Alipay code';

  @override
  String get paymentQrUpdated => 'Payment QR settings updated';

  @override
  String get paymentQrCleared => 'Payment QR code removed';

  @override
  String get paymentQrMissingHint =>
      'Upload a QR code before turning on public display.';

  @override
  String get paymentQrSafetyHint =>
      'The platform only displays your image and will not confirm whether anyone has paid.';

  @override
  String get createDealIntent => 'Start deal intent';

  @override
  String get dealIntentSent =>
      'Deal intent sent. Waiting for seller confirmation.';

  @override
  String get platformNoEscrowShort =>
      'The platform only records offline deal intent. It does not escrow funds or verify payment or handoff. Please confirm inspection, exchange, and payment in chat.';

  @override
  String get awaitingSellerConfirm => 'Waiting for seller confirmation';

  @override
  String get dealConfirmed => 'Offline deal confirmed';

  @override
  String get dealCancelled => 'Deal record cancelled';

  @override
  String get confirmOfflineDeal => 'Confirm deal';

  @override
  String get autoDelistAfterConfirm => 'Auto-delist item after confirmation';

  @override
  String get autoDelistAfterConfirmSubtitle =>
      'Best for one-off used items. Turn it off if you want the listing to keep receiving intents.';

  @override
  String get dealIntentCreated => 'Buyer started deal intent';

  @override
  String get sellerConfirmedDeal => 'Seller confirmed deal';

  @override
  String get itemAutoDelisted => 'Item auto-delisted';

  @override
  String get listingStatus => 'Listing status';

  @override
  String get chatReadReceiptSettingsTitle => 'Chat read receipts';

  @override
  String get chatReadReceiptDefaultTitle => 'Default read behavior';

  @override
  String get chatReadReceiptAutoTitle => 'Auto read';

  @override
  String get chatReadReceiptManualTitle => 'Manual read';

  @override
  String get chatReadReceiptAutoSubtitle =>
      'Mark received messages as read when you open an active realtime chat.';

  @override
  String get chatReadReceiptManualSubtitle =>
      'They only see read after you tap \"Mark read\".';

  @override
  String get chatReadReceiptAutoCurrent =>
      'Auto: opening an active realtime chat marks messages as read.';

  @override
  String get chatReadReceiptManualCurrent =>
      'Manual: opening chat does not automatically show read receipts.';

  @override
  String get chatReadReceiptUpdated => 'Chat read receipt setting updated';

  @override
  String get markConversationRead => 'Mark read';

  @override
  String get markConversationReadSuccess => 'Marked as read';

  @override
  String get manualReadUnreadOne =>
      'Unread messages are waiting; manual read is on';

  @override
  String manualReadUnreadMany(int count) {
    return '$count unread messages; manual read is on';
  }

  @override
  String get readPreferenceUpdated => 'Read preference updated';

  @override
  String get readPreferenceInherit => 'Read receipts: inherit default';

  @override
  String get readPreferenceAuto => 'Read receipts: auto';

  @override
  String get readPreferenceManual => 'Read receipts: manual';

  @override
  String get selectedSuffix => ' ✓';

  @override
  String get quoteListing => 'Listing';

  @override
  String get quoteOrder => 'Deal record';

  @override
  String get quoteHitlOffer => 'Negotiation';

  @override
  String get quoteGeneric => 'Quote';

  @override
  String get discoverabilitySettingsTitle => 'How others can find me';

  @override
  String get discoverByUsernameTitle => 'Find me by username';

  @override
  String get discoverByUsernameSubtitle =>
      'When off, others cannot find you by username. Required display in listings and existing conversations is not affected.';

  @override
  String get discoverByEmailTitle => 'Find me by email';

  @override
  String get discoverByEmailMissingSubtitle =>
      'Set a campus email first, then choose whether others can find you by entering the full email.';

  @override
  String discoverByEmailSubtitle(String email) {
    return 'Current email: $email. When enabled, others must enter the full email to find you.';
  }

  @override
  String get discoverByStudentIdTitle => 'Find me by student ID';

  @override
  String discoverByStudentIdSubtitle(String studentId) {
    return 'Student ID inferred from email: $studentId. When enabled, others must enter the full student ID to find you.';
  }

  @override
  String get discoverByStudentIdMissingSubtitle =>
      'The current email does not reveal a student ID. Use a campus email that starts with 8-12 digits.';

  @override
  String get discoverabilityUpdated => 'Discovery settings updated';

  @override
  String settingsUpdateFailed(String error) {
    return 'Settings update failed: $error';
  }

  @override
  String get conversationSectionDirect => 'Direct messages';

  @override
  String get conversationSectionSpaces => 'Campus groups and channels';

  @override
  String get conversationSectionTools => 'Xiaobang';

  @override
  String get conversationCreateGroupSuccess =>
      'Group created and added to Messages';

  @override
  String get conversationCreateChannelSuccess =>
      'Channel created and added to Messages';

  @override
  String conversationCreateFailed(String error) {
    return 'Create failed: $error';
  }

  @override
  String get conversationPeerFallback => 'Classmate';

  @override
  String get conversationThreadLoading => 'Loading thread';

  @override
  String conversationThreadStats(int realtime, int mail, int count) {
    return 'Realtime $realtime · Mail $mail · $count segments';
  }

  @override
  String get conversationReconnect => 'Reconnect';

  @override
  String get conversationThreadLoadFailedTitle =>
      'Contact thread could not load';

  @override
  String get conversationThreadEmptyTitle =>
      'No visible conversation history yet';

  @override
  String get conversationThreadEmptySubtitle =>
      'Reconnect to start a new realtime chat or mail thread.';

  @override
  String get conversationMailThreadTitle => 'Mail thread';

  @override
  String get conversationRealtimeThreadTitle => 'Realtime session';

  @override
  String get conversationSegmentHistoryHint =>
      'This segment is kept as history. Start a new conversation when you need to continue.';

  @override
  String get conversationSegmentOpenHint =>
      'Open this segment to view messages, reply, quote context, or handle connection state.';

  @override
  String get conversationViewHistory => 'View history';

  @override
  String get conversationOpenSegment => 'Open this segment';

  @override
  String conversationPendingCount(int count) {
    return 'Pending $count';
  }

  @override
  String get conversationTimelineFallback => 'View conversation timeline';

  @override
  String conversationRealtimeCount(int count) {
    return 'Realtime $count';
  }

  @override
  String conversationMailCount(int count) {
    return 'Mail $count';
  }

  @override
  String conversationSegmentCount(int count) {
    return '$count segments';
  }

  @override
  String get createGroup => 'Create group';

  @override
  String get createChannel => 'Create channel';

  @override
  String get spaceNameLabel => 'Name';

  @override
  String get spaceDescriptionOptionalLabel => 'Description (optional)';

  @override
  String get createAction => 'Create';

  @override
  String get unnamedSpace => 'Unnamed space';

  @override
  String get spaceFallbackTitle => 'Campus group';

  @override
  String get refresh => 'Refresh';

  @override
  String get spaceLoadFailedTitle => 'Space could not load';

  @override
  String get spaceNotFoundTitle => 'Space not found';

  @override
  String get spaceNotFoundSubtitle =>
      'It may have been deleted, or you may not be a member.';

  @override
  String spaceSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String spaceMembersRoleLine(int count, String role) {
    return '$count members · My role $role';
  }

  @override
  String get spaceMessagesLoadFailedTitle => 'Space messages could not load';

  @override
  String get spaceChannelCreatedTitle => 'Channel created';

  @override
  String get spaceGroupCreatedTitle => 'Group created';

  @override
  String get spaceChannelEmptySubtitle =>
      'Announcements will appear here. Channel members can read, react, and report.';

  @override
  String get spaceGroupEmptySubtitle =>
      'It is now in Messages. Send the first note to bring the group to life.';

  @override
  String get replyAction => 'Reply';

  @override
  String replyPreviewMissing(int messageId) {
    return 'Replied to message #$messageId';
  }

  @override
  String get spaceChannelReadOnlyNotice =>
      'You are a channel member. You can read, react, and report; only channel owners/admins can post announcements.';

  @override
  String get cancelReply => 'Cancel reply';

  @override
  String get channelComposerHint => 'Post an announcement...';

  @override
  String get groupComposerHint => 'Send a group message...';

  @override
  String spaceFallbackDescription(int count, String kind) {
    return '$count members · $kind';
  }

  @override
  String get spaceKindChannelLong => 'Announcement channel';

  @override
  String get spaceKindGroupLong => 'Campus group';

  @override
  String get spaceKindChannel => 'Channel';

  @override
  String get spaceKindGroup => 'Group';

  @override
  String get spaceRoleOwner => 'Owner';

  @override
  String get spaceRoleAdmin => 'Admin';

  @override
  String get spaceRoleBanned => 'Restricted';

  @override
  String get spaceRoleMember => 'Member';

  @override
  String get chatAcceptedLegacy => 'Connection accepted';

  @override
  String chatAcceptFailed(String error) {
    return 'Accept failed: $error';
  }

  @override
  String get chatRejectedLegacy => 'Connection rejected';

  @override
  String chatRejectFailed(String error) {
    return 'Reject failed: $error';
  }

  @override
  String get replyingToMessage => 'Replying to this message';

  @override
  String reactionFailed(String error) {
    return 'Reaction failed: $error';
  }

  @override
  String get hideMessageDialogTitle => 'Delete from my chat history?';

  @override
  String get hideMessageDialogBody =>
      'This only hides the message for you. The other person can still see it.';

  @override
  String get deleteAction => 'Delete';

  @override
  String get messageHiddenForMe => 'Hidden from your chat history';

  @override
  String messageHideFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get reportMessageTitle => 'Report this message';

  @override
  String get reportReasonDefault => 'Inappropriate content';

  @override
  String get reportReasonLabel => 'Reason';

  @override
  String get reportDetailsLabel => 'Additional details (optional)';

  @override
  String get submitAction => 'Submit';

  @override
  String get acceptAction => 'Accept';

  @override
  String get rejectAction => 'Reject';

  @override
  String get reportSubmitted => 'Report submitted';

  @override
  String reportFailed(String error) {
    return 'Report failed: $error';
  }

  @override
  String markReadFailed(String error) {
    return 'Mark read failed: $error';
  }

  @override
  String readPreferenceUpdateFailed(String error) {
    return 'Read preference update failed: $error';
  }

  @override
  String get quoteUnavailable =>
      'This conversation has no listing, order, or negotiation context to quote.';

  @override
  String get quotePickerTitle => 'Quote related info';

  @override
  String get quotePickerSubtitle =>
      'The server creates the fact snapshot, so price, title, and status cannot be forged by the client.';

  @override
  String get quoteListingFallback => 'Listing linked to this conversation';

  @override
  String get quoteListingSubtitle =>
      'Quote a snapshot of the listing title, price, condition, and cover image.';

  @override
  String get conversationCannotSendMessage =>
      'This conversation cannot send messages right now';

  @override
  String messageSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String get replyAssistantUnavailable =>
      'Xiaobang is not ready yet. You can still type directly.';

  @override
  String closeConversationFailed(String error) {
    return 'End conversation failed: $error';
  }

  @override
  String get blockUserTitle => 'Block this user?';

  @override
  String get blockUserBody =>
      'Neither side will be able to keep sending messages. Existing history will be preserved.';

  @override
  String get blockAction => 'Block';

  @override
  String blockFailed(String error) {
    return 'Block failed: $error';
  }

  @override
  String get callRequiresActiveConversation =>
      'You can start a call after the conversation is connected.';

  @override
  String get videoCallSignalSent => 'Video call signal sent';

  @override
  String get audioCallSignalSent => 'Audio call signal sent';

  @override
  String callStartFailed(String error) {
    return 'Start call failed: $error';
  }

  @override
  String get secretChatCreated =>
      'Secret chat session created. The server only stores ciphertext endpoints.';

  @override
  String secretChatCreateFailed(String error) {
    return 'Create secret chat failed: $error';
  }

  @override
  String quoteListingLabel(String title) {
    return 'Quote listing: $title';
  }

  @override
  String get conversationFallbackTitle => 'Conversation';

  @override
  String get conversationLoadingState => 'Loading conversation state';

  @override
  String get conversationUnavailable =>
      'This conversation is currently unavailable';

  @override
  String get conversationWaitingPeer => 'Waiting for them to connect';

  @override
  String get conversationAcceptToReply => 'Connect to reply';

  @override
  String get conversationCompletingHandshake =>
      'Completing connection confirmation';

  @override
  String get conversationDeclinedTitle => 'This time did not connect';

  @override
  String get conversationCancelledTitle => 'Invitation cancelled';

  @override
  String get conversationExpiredTitle => 'This conversation has ended';

  @override
  String get conversationClosedTitle => 'This conversation is closed';

  @override
  String conversationReadMenuHeader(String mode) {
    return 'Read settings · Current $mode';
  }

  @override
  String get readModeUnknown => 'Unknown';

  @override
  String get readModeManual => 'Manual';

  @override
  String get readModeAuto => 'Auto';

  @override
  String get readModeInherit => 'Inherit default';

  @override
  String get audioCallMvp => 'Audio call MVP';

  @override
  String get videoCallMvp => 'Video call MVP';

  @override
  String get secretChatMvp => 'Secret chat MVP';

  @override
  String get closeConversationAction => 'End this conversation';

  @override
  String get replyAssistantButton => 'Ask Xiaobang';

  @override
  String get mailFallbackTitle => 'Mail';

  @override
  String get mailProtocolSubtitle =>
      'Async delivery · no online, typing, or read status';

  @override
  String get incomingRealtimeTitle => 'They want to chat now';

  @override
  String get incomingRealtimeSubtitle => 'You can choose whether to connect';

  @override
  String incomingRealtimeExpiring(String remaining) {
    return 'Invitation expires in $remaining';
  }

  @override
  String get notConvenientNow => 'Not convenient now';

  @override
  String get connectAction => 'Connect';

  @override
  String get waitingPeerTitle => 'Waiting for them to connect';

  @override
  String get invitationDelivered => 'Invitation delivered';

  @override
  String timeRemaining(String remaining) {
    return '$remaining left';
  }

  @override
  String get cancelInvitation => 'Cancel invitation';

  @override
  String get confirmingConnectionTitle => 'Confirming connection';

  @override
  String get peerRespondedWaitingTitle =>
      'They responded; waiting for confirmation';

  @override
  String get confirmingConnectionSubtitle =>
      'You can chat after confirmation completes.';

  @override
  String connectionReleaseAfter(String remaining) {
    return 'This connection releases in $remaining';
  }

  @override
  String get realtimeConnectedTitle => 'Conversation connected';

  @override
  String get realtimeConnectedSubtitle => 'You can chat in realtime now';

  @override
  String realtimeExpiresAfterIdle(String remaining) {
    return 'Ends after $remaining with no new messages';
  }

  @override
  String get endAction => 'End';

  @override
  String get conversationTerminalSubtitle =>
      'History is kept. Reconnecting starts a new conversation.';

  @override
  String get conversationNaturallyEndedTitle =>
      'This conversation ended naturally';

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '${hours}h ${minutes}m';
  }

  @override
  String get connectionRequestTitle => 'Connection request';

  @override
  String connectionRequestReadReceiptNotice(String title, String body) {
    return '$title\n\n$body\n\nRead receipts will be enabled after you confirm.';
  }

  @override
  String get offlineStatus => 'Offline';

  @override
  String get onlineStatus => 'Online';

  @override
  String get pendingAcceptStatus => 'Pending';

  @override
  String get connectingStatus => 'Connecting...';

  @override
  String get replyPreviewGeneric => 'Quoted a message';

  @override
  String get editedSuffix => '(edited)';

  @override
  String get editAction => 'Edit';

  @override
  String get hideMessageAction => 'Delete from my chat history';

  @override
  String get hideMessageActionSubtitle =>
      'Only hides it for you; the other person can still see it';

  @override
  String get reportAction => 'Report';

  @override
  String get sendFailedShort => 'Send failed';

  @override
  String get messageSentStatus => 'Sent';

  @override
  String get messageReadStatus => 'Read';

  @override
  String get messageDeliveredStatus => 'Delivered';

  @override
  String typingIndicator(String username) {
    return '$username is typing...';
  }

  @override
  String loadFailedWithError(String error) {
    return 'Load failed: $error';
  }

  @override
  String get noMessagesYet => 'No messages yet. Start the conversation.';

  @override
  String get stopAction => 'Stop';

  @override
  String get replyMediaMessage => 'Reply to a media message';

  @override
  String get cancelQuote => 'Cancel quote';

  @override
  String get quoteContextTooltip => 'Quote a listing, order, or negotiation';

  @override
  String get editMessageHint => 'Edit message...';

  @override
  String get messageInputHint => 'Type a message...';

  @override
  String offerPriceLine(String price) {
    return 'Offer: ¥$price';
  }

  @override
  String reasonLine(String reason) {
    return 'Reason: $reason';
  }

  @override
  String expiresAtLine(String time) {
    return 'Valid until: $time';
  }

  @override
  String get counterOfferAction => 'Counter';

  @override
  String get acceptCounterAction => 'Accept counter';

  @override
  String sellerCounterPriceLine(String price) {
    return 'Seller countered ¥$price';
  }

  @override
  String yourOriginalOfferLine(String price) {
    return 'Your original offer: ¥$price';
  }

  @override
  String get connectionFailedNetwork =>
      'Connection failed. Please check the network.';

  @override
  String get emptyReplyPlaceholder => '(no reply)';

  @override
  String listingLine(String listingId) {
    return 'Listing: $listingId';
  }

  @override
  String buyerOfferLine(String price) {
    return 'Buyer offer: ¥$price';
  }

  @override
  String statusLine(String status) {
    return 'Status: $status';
  }

  @override
  String counterPriceLine(String price) {
    return 'Counter: ¥$price';
  }

  @override
  String negotiationStatusLine(String status) {
    return 'Negotiation $status';
  }

  @override
  String get adminModerationTab => 'Review';

  @override
  String get moderationCenter => 'Content review';

  @override
  String get moderationCenterSubtitle =>
      'View decisions affecting your content and submit appeals';

  @override
  String get moderationNoCases => 'There are no moderation cases affecting you';

  @override
  String get moderationReadOnly =>
      'You can inspect cases for this campus. Only platform admins can take action.';

  @override
  String get moderationCase => 'Moderation case';

  @override
  String get moderationResource => 'Related content';

  @override
  String get moderationReason => 'Public reason';

  @override
  String get moderationCreatedAt => 'Created';

  @override
  String get moderationResolution => 'Resolution';

  @override
  String get moderationInternalEvidence => 'Internal evidence';

  @override
  String get moderationStartReview => 'Start review';

  @override
  String get moderationRestrict => 'Restrict content';

  @override
  String get moderationDismiss => 'No violation';

  @override
  String get moderationRestore => 'Restore content';

  @override
  String get moderationActionNote => 'Internal decision note';

  @override
  String get moderationPublicReason => 'Reason shown to the user (optional)';

  @override
  String get moderationActionSuccess => 'Case status updated';

  @override
  String get moderationStatusOpen => 'Open';

  @override
  String get moderationStatusReviewing => 'In review';

  @override
  String get moderationStatusActioned => 'Action taken';

  @override
  String get moderationStatusDismissed => 'No violation';

  @override
  String get moderationStatusAppealed => 'Under appeal';

  @override
  String get moderationStatusResolved => 'Resolved';

  @override
  String get moderationSourceMachine => 'Automated review';

  @override
  String get moderationSourceUserReport => 'User report';

  @override
  String get moderationSourceManual => 'Manual case';

  @override
  String get moderationAppeal => 'Submit appeal';

  @override
  String get moderationAppealHint =>
      'Explain why the decision may be wrong and what another reviewer should check (10–2000 characters).';

  @override
  String get moderationAppealSubmitted =>
      'Appeal submitted for independent review';

  @override
  String get moderationPendingAppeal => 'Appeal awaiting review';

  @override
  String get moderationCannotAppeal =>
      'This case cannot be appealed in its current state';

  @override
  String get moderationFilterAll => 'All';

  @override
  String get moderationNoInternalDetails => 'No additional internal evidence';

  @override
  String get listingImage => 'Listing image';

  @override
  String get imageMessage => 'Chat image';

  @override
  String get avatar => 'Avatar';

  @override
  String get warning => 'Warning';
}
