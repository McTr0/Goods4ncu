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
  String get aiError => 'Service unavailable. Try again.';

  @override
  String get aiGreeting => 'Goods4ncu intelligent services';

  @override
  String get aiWillAutoRecognize => 'AI will auto-recognize item info';

  @override
  String get allCategories => 'All';

  @override
  String get appTitle => 'Goods4ncu';

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
  String get connectionPrivacyTitle => 'Connection privacy';

  @override
  String get connectionPrivacySubtitle =>
      'Choose who may interrupt you with realtime requests.';

  @override
  String get allowStrangersTitle => 'Allow strangers to connect';

  @override
  String get allowStrangersSubtitle =>
      'When off, strangers can still leave a message but cannot start realtime.';

  @override
  String get busyModeTitle => 'Pause realtime requests for one hour';

  @override
  String get busyModeSubtitle => 'Mail remains available while you are busy.';

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
  String get createListingAiRecognizing => 'Identifying…';

  @override
  String get createListingAiSubtitle =>
      'Upload an image to identify the title, category, brand, and condition. Confirmation is required before publishing.';

  @override
  String get createListingAiTitle => 'Image recognition';

  @override
  String get createListingModeOffer => 'Sell';

  @override
  String get createListingModeWanted => 'Request';

  @override
  String get createWantedPanelTitle => 'Request details';

  @override
  String get createWantedPanelSubtitle =>
      'Enter a budget, minimum condition, and other requirements for campus listing matching.';

  @override
  String get createListingBasicInfo => 'Listing basics';

  @override
  String get createListingBasicInfoSubtitle =>
      'Used to generate the item list and detail view.';

  @override
  String get createWantedBasicInfo => 'Wanted basics';

  @override
  String get createWantedBasicInfoSubtitle => 'Enter clear request criteria.';

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
      'Accurately describe the item\'s condition and defects.';

  @override
  String get createWantedConditionSection => 'Minimum requirements';

  @override
  String get createWantedConditionSubtitle =>
      'Enter the minimum acceptable condition and requirements.';

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
      'Optional. Used to reduce follow-up questions.';

  @override
  String get createWantedDescriptionHint =>
      'Describe how you will use it, pickup preference, and deal breakers...';

  @override
  String get createWantedDescriptionLabel => 'Wanted description (optional)';

  @override
  String get createWantedDescriptionSection => 'Extra request details';

  @override
  String get createWantedDescriptionSubtitle =>
      'Optional. Used to improve matching accuracy.';

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
  String get createListingProgressSubtitle => 'Complete the required fields.';

  @override
  String get createListingProgressTitle => 'Publish progress';

  @override
  String get createListingReadyHint => 'Information complete';

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
  String get homeColdStartTitle => 'No listings or requests yet';

  @override
  String get homeColdStartBody => 'No offers or requests at this school.';

  @override
  String get homeColdStartAction => 'Post';

  @override
  String get homeVoicesTitle => 'Campus Requests';

  @override
  String get homeVoicesBody => 'Items classmates are looking for.';

  @override
  String get homeFilterEmpty => 'No content under this filter.';

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
  String get agentPlanPendingHeader => 'Pending actions';

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
  String get intentRespondAction => 'Contact publisher';

  @override
  String get intentRespondTitle => 'Reply';

  @override
  String get intentRespondHint =>
      'Describe the item or relevant information you can provide';

  @override
  String get intentRespondSend => 'Send';

  @override
  String get intentRespondSent => 'Sent — they\'ll see it in their messages';

  @override
  String get priceDiscoveryTitle => 'Price negotiation';

  @override
  String get priceDiscoveryStart => 'Start price negotiation';

  @override
  String get priceDiscoveryYourLimit => 'Your limit (CNY)';

  @override
  String get priceDiscoveryBuyerHint => 'The most you\'d pay';

  @override
  String get priceDiscoverySellerHint => 'The least you\'d accept';

  @override
  String get priceDiscoverySubmit => 'Submit offer';

  @override
  String get priceDiscoveryWaiting =>
      'Offer submitted. Offers remain hidden until both parties submit.';

  @override
  String get priceDiscoveryNoDeal =>
      'The submitted offers do not currently overlap.';

  @override
  String get priceDiscoveryAcceptInvite => 'Price negotiation request received';

  @override
  String get priceDiscoveryAgree => 'Confirm';

  @override
  String get priceDiscoveryPreferHaggle => 'Switch to direct negotiation';

  @override
  String get priceDiscoveryDeclined => 'Switched to talking it over';

  @override
  String get priceDiscoveryInvalid => 'Enter a sensible price';

  @override
  String get reputationNewcomer => 'No record';

  @override
  String reputationSummary(int completed, int onTime) {
    return 'Completed $completed, on time $onTime';
  }

  @override
  String priceDiscoveryMatched(String price) {
    return 'Agreed at ¥$price';
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
  String get wantedFulfillConfirmTitle => 'Mark this request fulfilled?';

  @override
  String get wantedFulfillConfirmBody =>
      'New matches and recommendations will stop. Existing conversations and recommendation history will remain, and you can reopen the request later.';

  @override
  String get wantedClosedResponderHint =>
      'This request is closed, so it cannot receive new recommendations.';

  @override
  String get wantedResponsesReceivedTitle => 'Recommendations received';

  @override
  String get wantedResponsesSentTitle => 'Recommendations sent';

  @override
  String get wantedResponsesReceivedEmpty =>
      'No one has recommended an offer for this request yet.';

  @override
  String get wantedResponsesSentEmpty =>
      'You have not recommended an offer yet.';

  @override
  String get wantedResponseLoadFailed =>
      'Recommendations could not be loaded. Try again.';

  @override
  String wantedResponseActionFailed(String error) {
    return 'The recommendation could not be updated: $error';
  }

  @override
  String get wantedResponseRoundClosedToast =>
      'This recommendation belongs to a closed request round and is now read-only.';

  @override
  String get wantedResponseClosedRoundLabel =>
      'Closed request round · Read-only';

  @override
  String get wantedResponseAcceptedToast => 'Recommendation accepted';

  @override
  String get wantedResponseDismissedToast => 'Recommendation dismissed';

  @override
  String get wantedResponseWithdrawnToast => 'Recommendation withdrawn';

  @override
  String get wantedResponseStatusPending => 'Awaiting decision';

  @override
  String get wantedResponseStatusAccepted => 'Accepted';

  @override
  String get wantedResponseStatusDismissed => 'Dismissed';

  @override
  String get wantedResponseStatusWithdrawn => 'Withdrawn';

  @override
  String get wantedResponseStatusUnknown => 'Status unavailable';

  @override
  String get wantedResponseListingStatusActive => 'Active';

  @override
  String get wantedResponseListingStatusFulfilled => 'Fulfilled';

  @override
  String get wantedResponseListingStatusSold => 'Sold';

  @override
  String get wantedResponseListingStatusDeleted => 'Unavailable';

  @override
  String get wantedResponseListingStatusUnknown => 'Status unavailable';

  @override
  String wantedResponseWantedContext(String title, String status) {
    return 'Request: $title · $status';
  }

  @override
  String wantedResponseOfferContext(String title, String status) {
    return 'Offer: $title · $status';
  }

  @override
  String get wantedResponseMessageLabel => 'Message';

  @override
  String get wantedResponseOpenOfferAction => 'View offer';

  @override
  String get wantedResponseAcceptAction => 'Accept';

  @override
  String get wantedResponseDismissAction => 'Dismiss';

  @override
  String get wantedResponseWithdrawAction => 'Withdraw';

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
  String get homePromptHint => 'Search items or requests';

  @override
  String get homePromptSubmitTooltip => 'Search';

  @override
  String get homeActionOffer => 'Post Offer';

  @override
  String get homeActionWanted => 'Post Request';

  @override
  String get homeSectionTitle => 'Classmates Buying & Selling';

  @override
  String get homeSectionSubtitle => 'Listings and requests from your campus';

  @override
  String get homeLoadFailed => 'Could not load right now';

  @override
  String get homeLoadFailedRetry => 'Reload';

  @override
  String get conversationLoadFailedTitle => 'Messages could not load';

  @override
  String get conversationEmptyTitle => 'No conversations';

  @override
  String get conversationEmptySubtitle =>
      'Conversations appear here after contact is initiated.';

  @override
  String get conversationEmptyAction => 'Post offer / wanted';

  @override
  String get conversationEmptyAskAssistant => 'Xiaochang';

  @override
  String get conversationSearchHint =>
      'Search contacts, messages, items, or groups';

  @override
  String get conversationSearchClear => 'Clear search';

  @override
  String get conversationSearchEmptyTitle => 'No matching messages';

  @override
  String get conversationSearchEmptySubtitle =>
      'Try a contact, item, recent message, or group name.';

  @override
  String get findClassmate => 'Find classmate';

  @override
  String conversationWaitingCount(int count) {
    return 'Awaiting your reply · $count';
  }

  @override
  String get conversationFilterAll => 'All';

  @override
  String get conversationFilterRealtime => 'Connections';

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
  String get contactConnectAction => 'Connect';

  @override
  String get contactMailAction => 'Message';

  @override
  String get chatHistoryAction => 'Chat history';

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
  String get assistantName => 'Xiaochang';

  @override
  String get assistantSystemBadge => 'Core Avatar';

  @override
  String get assistantInboxSubtitle =>
      'Item search, pricing, publishing, and negotiation';

  @override
  String get assistantHeaderSubtitle =>
      'Personal transaction assistant · important actions require confirmation';

  @override
  String get assistantHistoryLoadFailed => 'History failed to load.';

  @override
  String get assistantTyping => 'Processing…';

  @override
  String get assistantAskAboutPage => 'Ask Xiaochang';

  @override
  String get relationshipSpacePokeAction => 'Poke';

  @override
  String relationshipSpacePokeFeedback(String name) {
    return 'You poked $name';
  }

  @override
  String recordingStatus(int seconds) {
    return 'Recording ${seconds}s / 60s';
  }

  @override
  String get viewAction => 'View';

  @override
  String get invitationFallbackTitle => 'Realtime conversation invitation';

  @override
  String get declineNow => 'Decline';

  @override
  String get connectNow => 'Accept';

  @override
  String get modeRealtime => 'Realtime';

  @override
  String get modeMail => 'Mail';

  @override
  String get conversationStateDelivered => 'Sent';

  @override
  String get conversationStateSynSent => 'Waiting for them to connect';

  @override
  String get conversationStateSynAck =>
      'They replied, waiting for confirmation';

  @override
  String get conversationStateActive => 'This conversation is connected';

  @override
  String get conversationStateDeclined => 'Connection not established';

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
  String get contactPageModeHint =>
      'This is a full contact page. Choose realtime contact or mail; going back preserves the previous page.';

  @override
  String get contactBackAction => 'Back to contact methods';

  @override
  String contactContextUser(String username) {
    return 'Contact $username';
  }

  @override
  String get contactPageTitle => 'New conversation';

  @override
  String contactContextListing(String title) {
    return 'About \"$title\"';
  }

  @override
  String get contactFallbackUser => 'this classmate';

  @override
  String get contactModeMailDescription =>
      'Send messages directly; visible as soon as they open the app.';

  @override
  String get contactOpeningRequired => 'Enter an opening message.';

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
  String get contactMailExpectationLabel =>
      'When would you like them to look? (optional)';

  @override
  String get contactMailExpectationOrdinary => 'No time requirement';

  @override
  String get contactMailExpectationToday => 'Reply today';

  @override
  String get contactMailBodyLabel => 'Body';

  @override
  String get contactRealtimeOpeningLabel =>
      'They will see this before connecting';

  @override
  String get contactMailBodyHint =>
      'Enter your question and preferred reply time...';

  @override
  String get contactRealtimeOpeningHint => 'Hi, is this item still available?';

  @override
  String get contactMailSubmit => 'Send message';

  @override
  String get contactRealtimeSubmit => 'Wait for them to connect';

  @override
  String get publicProfile => 'Classmate Profile';

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
  String get conversationSectionSpaces => 'Campus group chats';

  @override
  String get conversationSectionTools => 'Xiaochang';

  @override
  String get conversationCreateGroupSuccess =>
      'Group created and added to Messages';

  @override
  String conversationCreateFailed(String error) {
    return 'Create failed: $error';
  }

  @override
  String get conversationPeerFallback => 'Classmate';

  @override
  String get conversationThreadLoading => 'Loading';

  @override
  String get conversationReconnect => 'Contact again';

  @override
  String get conversationThreadLoadFailedTitle =>
      'Contact conversation failed to load';

  @override
  String get conversationThreadEmptyTitle => 'No communication records';

  @override
  String get conversationThreadEmptySubtitle =>
      'Start a new realtime conversation or message.';

  @override
  String get conversationMailThreadTitle => 'Mail thread';

  @override
  String get conversationRealtimeThreadTitle => 'Realtime session';

  @override
  String get conversationSegmentHistoryHint =>
      'This segment is kept as history. Start a new conversation when you need to continue.';

  @override
  String get conversationSegmentOpenHint =>
      'After opening, you can reply, quote, or handle the connection.';

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
  String get relationshipSpaceTitle => 'Shared space';

  @override
  String get relationshipSpaceMe => 'Me';

  @override
  String get relationshipSpaceAsync => 'Leave a message';

  @override
  String get relationshipSpaceConnected => 'Connected';

  @override
  String get relationshipSpaceLastConnection => 'Last connection';

  @override
  String get relationshipSpaceNoEvent =>
      'Long press a message to pin, or share items and files to keep them here';

  @override
  String get relationshipSpacePin => 'Pin to shared space';

  @override
  String get relationshipSpaceUnpin => 'Unpin';

  @override
  String relationshipSpacePinsCount(int count) {
    return '$count pinned';
  }

  @override
  String relationshipSpaceObjectsCount(int count) {
    return '$count shared items';
  }

  @override
  String get relationshipSpaceSharedObjectsTitle => 'Shared content';

  @override
  String get relationshipSpaceObjectFile => 'File';

  @override
  String get relationshipSpaceObjectLink => 'Link';

  @override
  String get relationshipSpaceObjectReference => 'Reference';

  @override
  String get relationshipSpacePinsTitle => 'Pinned messages';

  @override
  String get relationshipSpaceRecentRecords => 'Recent records';

  @override
  String get relationshipSpaceNoRecentRecords =>
      'No time records to revisit yet';

  @override
  String get relationshipSpaceRecentRecovery => 'Last connection record';

  @override
  String get relationshipSpaceExpandAction => 'Expand shared space';

  @override
  String get relationshipSpaceCollapseAction => 'Collapse shared space';

  @override
  String get relationshipSpaceEventSentMessage => 'Sent a message';

  @override
  String get relationshipSpaceEventOpeningMessage => 'Sent opening message';

  @override
  String get relationshipSpaceEventConnectionStarted => 'Started a connection';

  @override
  String get relationshipSpaceEventConnectionEnded => 'Ended a connection';

  @override
  String get relationshipSpaceEventConnectionAccepted => 'Accepted connection';

  @override
  String get relationshipSpaceEventConnectionDeclined => 'Declined connection';

  @override
  String get relationshipSpaceEventConversationCreated =>
      'Conversation started';

  @override
  String get relationshipSpaceEventPinChanged => 'Pinned messages changed';

  @override
  String get relationshipSpaceEventAcknowledgementChanged =>
      'Responded to a message';

  @override
  String get relationshipSpaceEventSharedObjectChanged =>
      'Shared content changed';

  @override
  String get relationshipSpaceEventDefault => 'Added a new record';

  @override
  String get createGroup => 'Create group';

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
    return '$count members · $role';
  }

  @override
  String get spaceMessagesLoadFailedTitle => 'Space messages could not load';

  @override
  String get replyAction => 'Reply';

  @override
  String replyPreviewMissing(int messageId) {
    return 'Replied to message #$messageId';
  }

  @override
  String get cancelReply => 'Cancel reply';

  @override
  String get startGroupTopic => 'Start a topic';

  @override
  String get groupTopicTitleHint => 'Describe what you want to discuss';

  @override
  String get groupTopicCreateHint => 'Every reply will stay inside this topic.';

  @override
  String get createTopicAction => 'Create topic';

  @override
  String get groupTopicEmptyTitle => 'No topics yet';

  @override
  String get groupTopicEmptySubtitle =>
      'A group topic must be started before members can discuss it.';

  @override
  String get groupTopicReplyHint => 'Reply in this topic...';

  @override
  String get groupTopicNoRepliesTitle => 'Waiting for the first reply';

  @override
  String get groupTopicNoRepliesSubtitle =>
      'Your reply will only appear in this topic.';

  @override
  String groupTopicStartedBy(String name) {
    return 'Started by $name';
  }

  @override
  String groupTopicReplyCount(int count) {
    return '$count';
  }

  @override
  String spaceFallbackDescription(int count, String kind) {
    return '$count members · $kind';
  }

  @override
  String get spaceKindGroupLong => 'Campus group';

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
  String get reportListingAction => 'Report listing';

  @override
  String get reportUserAction => 'Report user';

  @override
  String get reportListingTitle => 'Report this listing';

  @override
  String get reportUserTitle => 'Report this user';

  @override
  String get reportReasonDefault => 'Inappropriate content';

  @override
  String get reportReasonLabel => 'Reason';

  @override
  String get reportReasonRequired => 'Please enter a reason';

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
      'Reply suggestions are unavailable. Enter a reply directly.';

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
  String get conversationLoadingState => 'Preparing this conversation';

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
  String get audioCallMvp => 'Audio call';

  @override
  String get videoCallMvp => 'Video call';

  @override
  String get secretChatMvp => 'Secret chat MVP';

  @override
  String get closeConversationAction => 'End this conversation';

  @override
  String get replyAssistantButton => 'Generate reply suggestion';

  @override
  String get mailFallbackTitle => 'Mail';

  @override
  String get incomingRealtimeTitle =>
      'Realtime conversation invitation received';

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
  String get invitationDelivered => 'Invitation sent';

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
  String get relationshipContextScrollHint => 'Swipe up to see more';

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
  String get offlineStatus => 'Offline';

  @override
  String get onlineStatus => 'Online';

  @override
  String get connectedStatus => 'Connected';

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
  String get messageActionsHint => 'Open message actions';

  @override
  String get messageDeliveredStatus => 'Sent';

  @override
  String get acknowledgementReceived => 'Received';

  @override
  String get acknowledgementWillReview => 'I\'ll review';

  @override
  String get acknowledgementCompleted => 'Completed';

  @override
  String get acknowledgementWithdraw => 'Withdraw acknowledgement';

  @override
  String loadFailedWithError(String error) {
    return 'Load failed: $error';
  }

  @override
  String get noMessagesYet => 'No messages';

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
  String get moderationManagedEnforcementHint =>
      'Use the Listings or Users management tab to take down a listing or act on an account. Those enforcement actions are audited separately.';

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
  String get feedFeedbackMenuTooltip => 'Recommendation options';

  @override
  String get feedFeedbackHide => 'Hide this';

  @override
  String get feedFeedbackLessLikeThis => 'Show me fewer like this';

  @override
  String get feedFeedbackNotRelevant => 'Not relevant';

  @override
  String get feedFeedbackSaved =>
      'Thanks. This recommendation has been removed.';

  @override
  String get feedFeedbackFailed =>
      'Couldn\'t save that preference. The item is still here.';

  @override
  String get feedReasonRecent => 'Recently posted';

  @override
  String get feedReasonSameCategory => 'Matches categories you view';

  @override
  String get feedReasonCategoryMatch => 'Category matches your request';

  @override
  String get feedReasonSimilar => 'Similar to something you viewed';

  @override
  String get feedReasonWithinBudget => 'Within your budget';

  @override
  String get feedReasonConditionMatch => 'Matches the condition you wanted';

  @override
  String get feedReasonIntentKind => 'Matches what you are looking for';

  @override
  String get feedReasonKeywordMatch => 'Matches the words in your request';

  @override
  String get feedReasonRequirementsMatch => 'Matches the details you specified';

  @override
  String get feedReasonTimeOverlap => 'The available time overlaps with yours';

  @override
  String get feedReasonRecommended => 'Recommended for you';

  @override
  String get feedPreferencesSectionTitle => 'Feed controls';

  @override
  String get feedPersonalizationTitle => 'Personalized recommendations';

  @override
  String get feedPersonalizationOnSubtitle =>
      'Use your feed preferences to make suggestions more relevant.';

  @override
  String get feedPersonalizationOffSubtitle =>
      'Show a non-personalized feed instead.';

  @override
  String get feedPersonalizationUnavailable =>
      'Feed preferences are temporarily unavailable.';

  @override
  String get feedPersonalizationUpdated => 'Feed preference updated';

  @override
  String get feedPreferencesUpdateFailed =>
      'Couldn\'t update your feed preference. Try again.';

  @override
  String get feedPersonalizationClearTitle =>
      'Reset personalized recommendations';

  @override
  String get feedPersonalizationClearSubtitle =>
      'Stop using past watchlist, deal activity, and “show fewer” signals. Items you hid stay hidden.';

  @override
  String get feedPersonalizationClearConfirmTitle =>
      'Reset personalized recommendations?';

  @override
  String get feedPersonalizationClearConfirmBody =>
      'Recommendations will no longer use your previous watchlist, deal activity, or “show fewer” signals. The underlying records are not deleted, and specific items you hid stay hidden.';

  @override
  String get feedPersonalizationClearAction => 'Reset recommendations';

  @override
  String get feedPersonalizationCleared => 'Personalized recommendations reset';

  @override
  String get feedPersonalizationClearFailed =>
      'Couldn\'t reset personalized recommendations. Try again.';

  @override
  String get warning => 'Warning';

  @override
  String get listingLifecycleActive => 'Active';

  @override
  String get listingLifecycleFulfilled => 'Fulfilled';

  @override
  String get listingLifecycleSold => 'Sold';

  @override
  String get listingLifecycleOwnerDeleted => 'Deleted by you';

  @override
  String get listingLifecycleUnknown => 'Status unavailable';

  @override
  String get listingRestrictedBadge => 'Restricted by moderation';

  @override
  String get listingRestrictionTitle => 'This listing is restricted';

  @override
  String get listingRestrictionGeneric =>
      'It is hidden from marketplace activity until an administrator restores it.';

  @override
  String get viewModerationCase => 'View moderation case';

  @override
  String get deleteListingAction => 'Delete listing';

  @override
  String get relistListingAction => 'Relist';

  @override
  String get listingDeletedToast => 'Listing deleted';

  @override
  String get listingRelistedToast => 'Listing relisted';

  @override
  String get deleteListingConfirmTitle => 'Delete this listing?';

  @override
  String get listingPolicyChangedToast =>
      'The listing changed. Actions have been refreshed.';

  @override
  String get adminRestoreListing => 'Restore listing';

  @override
  String get adminRestoreListingConfirm => 'Restore this listing?';

  @override
  String get adminRestoreReasonHint =>
      'Explain why this administrative restriction should be removed.';

  @override
  String get adminRestoreListingSuccess => 'Listing restriction removed';

  @override
  String get adminListingNoActions =>
      'No administrative action is available for this listing.';

  @override
  String get socialPersonaCharacter => 'Avatar character';

  @override
  String get characterSettingsSubtitle =>
      'Choose the character that accompanies you in chat. Tap your avatar anytime to change it.';

  @override
  String get characterSettingsUpdated => 'Companion character updated';

  @override
  String get socialPersonaCharacterDoro => 'Doro';

  @override
  String get composerMoreTools => 'More tools';

  @override
  String get composerHideTools => 'Hide tools';

  @override
  String get composerSendTooltip => 'Send message';

  @override
  String get composerImageAction => 'Image';

  @override
  String get composerVoiceMessageAction => 'Voice message';

  @override
  String get dictationStartAction => 'Speech to text';

  @override
  String get dictationStopAction => 'Stop dictation';

  @override
  String get dictationListening =>
      'Listening — recognized text appears in the input';

  @override
  String get dictationPermissionDenied =>
      'Microphone permission is required for speech to text';

  @override
  String get dictationUnsupported =>
      'This device does not support speech to text';

  @override
  String get dictationNetworkError =>
      'The speech recognition service is unavailable';

  @override
  String get dictationUnavailable =>
      'Speech to text is temporarily unavailable';

  @override
  String get groupToolRelay => 'Sign-up list';

  @override
  String get groupToolCollection => 'Group collection';

  @override
  String get groupToolPoll => 'Poll';

  @override
  String get groupToolRelayTemplate => '[Sign-up list]\nTopic:\nDeadline:';

  @override
  String get groupToolCollectionTemplate =>
      '[Group collection]\nName:\nDetails:';

  @override
  String get groupToolPollTemplate => '[Poll]\nQuestion:\nOption 1:\nOption 2:';

  @override
  String get assistantToolFind => 'Find an item';

  @override
  String get assistantToolPublish => 'Publish an item';

  @override
  String get assistantToolEstimate => 'Price guidance';

  @override
  String get assistantToolFindPrompt => 'Help me find an item:';

  @override
  String get assistantToolPublishPrompt =>
      'Help me publish an item using these details:';

  @override
  String get assistantToolEstimatePrompt =>
      'Estimate a fair campus-market price for this item:';

  @override
  String get agentToolSearchingPosts => 'Flipping through posts…';

  @override
  String get agentToolInspectingListing =>
      'Taking a close look at this listing…';

  @override
  String get agentToolFindingRelated => 'Looking for similar posts…';

  @override
  String get agentToolBrowsingUserPosts => 'Seeing what else they posted…';

  @override
  String get agentToolReadingComments => 'Reading the comments…';

  @override
  String get agentToolOrganizingListings => 'Organizing your listings…';

  @override
  String get agentToolDraftingMessage => 'Drafting a message for you…';

  @override
  String get agentToolPreparingPublish => 'Preparing your listing…';

  @override
  String get agentToolPreparingOffer => 'Preparing an offer…';

  @override
  String get agentToolWorking => 'Working on your request…';

  @override
  String get assistantAgentResultTitle => 'Real posts found by Xiaochang';

  @override
  String get assistantFallbackCategory => 'Campus post';

  @override
  String get assistantDraftReadyBubble =>
      'I\'ve drafted it — send after you confirm:';

  @override
  String get assistantConfirmSendMessage => 'Confirm sending message';

  @override
  String get assistantDraftEditBubble =>
      'Edit it in the composer before sending';

  @override
  String get assistantSentBubble => 'Sent!';

  @override
  String get assistantSendFailedBubble => 'Sending failed — please retry';

  @override
  String get assistantThinkingBubble =>
      'Xiaochang is thinking, searching campus memories...';

  @override
  String get assistantIdleReplyBubble =>
      'Got it! Xiaochang is here whenever you need~';

  @override
  String get assistantHistorySheetTitle => '📜 History & smart memory';

  @override
  String get assistantHistoryEmpty => 'No conversations yet';

  @override
  String get assistantSuggestionVehicles => '🚲 Campus bikes';

  @override
  String get assistantSuggestionTextbooks => '📚 Grad-exam textbooks';

  @override
  String get assistantSuggestionGadgets => '🎒 Gadgets & iPads';

  @override
  String get assistantSuggestionOrders => '📦 My campus orders';

  @override
  String get assistantComposerHint =>
      'Talk to Xiaochang — find goods or errands...';

  @override
  String get assistantHeaderName => 'Xiaochang · Digital human';

  @override
  String get assistantHeaderTagline =>
      'Live motion · Memory · Campus assistant';

  @override
  String get assistantHistoryTooltip => 'Conversation history';

  @override
  String get assistantConfirmSendReply => 'Confirm posting reply';

  @override
  String get postDiscoveryTitle => 'Campus discovery';

  @override
  String get postDiscoverySubtitle =>
      'Discussions and listings from your campus';

  @override
  String get postFilterAll => 'For you';

  @override
  String get postFilterDiscussion => 'Discussions';

  @override
  String get postFilterListing => 'Listings';

  @override
  String get postSortLatest => 'Latest';

  @override
  String get postSortActive => 'Active';

  @override
  String get postSortReplies => 'Most replied';

  @override
  String get postTypeDiscussion => 'Discussion';

  @override
  String get postTypeListing => 'Listing';

  @override
  String get postAnonymousAuthor => 'Campus member';

  @override
  String get postCreateTooltip => 'Start a discussion';

  @override
  String get postCreateTitle => 'Start a discussion';

  @override
  String get postCreateIntro =>
      'Share a campus question, guide, or idea. To sell or request an item, use the listing publisher so price and condition stay structured.';

  @override
  String get postTitleLabel => 'Title';

  @override
  String get postTitleHint => 'Summarize what you want to discuss';

  @override
  String get postTitleRequired => 'Enter a title';

  @override
  String get postBodyLabel => 'Details';

  @override
  String get postBodyHint => 'Add context that will help classmates respond';

  @override
  String get postBodyRequired => 'Add some details';

  @override
  String get postCategoryLabel => 'Category (optional)';

  @override
  String get postCategoryHint => 'For example: Campus life';

  @override
  String get postTagsLabel => 'Tags (optional)';

  @override
  String get postTagsHint => 'Separate up to five tags with spaces or commas';

  @override
  String get postPublishAction => 'Publish';

  @override
  String get postKindDiscussion => 'Discussion';

  @override
  String get postKindMutualAid => 'Mutual aid';

  @override
  String get postMutualAidWanted => 'Need help';

  @override
  String get postMutualAidOffer => 'Can help';

  @override
  String get postMutualAidMode => 'Help type';

  @override
  String get postMutualAidModePickup => 'Pickup';

  @override
  String get postMutualAidModeBuy => 'Purchase';

  @override
  String get postMutualAidModeQueue => 'Queueing';

  @override
  String get postMutualAidModePrint => 'Printing';

  @override
  String get postMutualAidModeReturn => 'Return';

  @override
  String get postMutualAidModeOther => 'Other';

  @override
  String get postMutualAidPickup => 'Pickup location';

  @override
  String get postMutualAidDropoff => 'Handoff location';

  @override
  String get postMutualAidTime => 'Time details';

  @override
  String get postMutualAidReward => 'Reward (yuan)';

  @override
  String get postMutualAidRewardInvalid =>
      'Enter a reward from 0 to 100,000 yuan';

  @override
  String get postMutualAidValidity => 'Keep open for';

  @override
  String get postMutualAidOneDay => '1 day';

  @override
  String get postMutualAidThreeDays => '3 days';

  @override
  String get postMutualAidSevenDays => '7 days';

  @override
  String get postResolutionOpen => 'Open';

  @override
  String get postResolutionResolved => 'Resolved';

  @override
  String get postResolutionClosed => 'Closed';

  @override
  String get postResolutionUpdate => 'Update mutual-aid status';

  @override
  String get postMutualAidNotes => 'Additional details';

  @override
  String get postPublishFailed =>
      'Could not publish the discussion. Try again.';

  @override
  String get postDetailTitle => 'Discussion';

  @override
  String get postLoadFailed => 'Could not load this discussion.';

  @override
  String get postRepliesTitle => 'Replies';

  @override
  String get postThreadOrder => 'Oldest first';

  @override
  String get postNoReplies => 'No replies yet. Add the first helpful response.';

  @override
  String get postLockedNotice => 'This discussion is closed to new replies.';

  @override
  String get postReplyHint => 'Write a constructive reply…';

  @override
  String get postReplyAction => 'Reply';

  @override
  String get postReplyFailed => 'Could not send your reply. Try again.';

  @override
  String postReplyingTo(String username) {
    return 'Replying to $username';
  }

  @override
  String get postLinkedListing => 'Marketplace listing';

  @override
  String get postViewListing => 'View item';

  @override
  String get listingDiscussionAction => 'Open discussion';

  @override
  String get listingDiscussionHint =>
      'This product is also a post. Read or join its campus discussion.';

  @override
  String get postEmptyTitle => 'Nothing here yet';

  @override
  String get postEmptyBody =>
      'Start a useful campus conversation and classmates can build the thread with you.';

  @override
  String get postEmptyListingBody =>
      'No marketplace posts match this filter yet.';

  @override
  String get postStartAction => 'Start a discussion';
}
