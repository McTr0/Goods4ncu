import '../models/models.dart';
import 'base_service.dart';
import 'auth_service.dart';
import 'chat_service.dart';
import 'user_service.dart';
import 'listing_service.dart';
import 'admin_service.dart';
import 'negotiate_service.dart';

/// Remaining ApiService methods after domain split.
/// Routes to split services internally; pages migrate to individual services over time.
class ApiService extends BaseService {
  // Static navigatorKey is inherited from BaseService — accessible as ApiService.navigatorKey
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final ListingService _listingService = ListingService();
  final AdminService _adminService = AdminService();
  final NegotiateService _negotiateService = NegotiateService();

  // -----------------------------------------------------------------
  // Stats
  // -----------------------------------------------------------------

  /// Get platform statistics (no auth required).
  /// GET /api/stats
  Future<Map<String, dynamic>> getStats() async {
    final response = await get(Uri.parse('$baseUrl/api/stats'), {
      'Content-Type': 'application/json',
    });
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------
  // Recommendations
  // -----------------------------------------------------------------

  /// Get personalized recommendations (no auth required).
  /// GET /api/recommendations
  Future<Map<String, dynamic>> getRecommendations() async {
    final response = await get(Uri.parse('$baseUrl/api/recommendations'), {
      'Content-Type': 'application/json',
    });
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------
  // Conversations (legacy — prefer ChatService)
  // -----------------------------------------------------------------

  /// Get conversations (legacy endpoint — prefer ChatService.getConnections).
  /// GET /api/conversations
  Future<List<dynamic>> getConversations() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/conversations'),
      headers,
    );
    return handleResponse(response, (data) => data as List<dynamic>);
  }

  /// Get conversation messages (legacy — prefer ChatService.getChatConversationMessages).
  /// GET /api/conversations/{conversationId}/messages
  Future<Map<String, dynamic>> getConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse(
        '$baseUrl/api/conversations/$conversationId/messages?limit=$limit&offset=$offset',
      ),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to ChatService)
  // -----------------------------------------------------------------

  Future<ConversationMessage> sendMessage(
    String conversationId, {
    required String content,
    String? clientMessageId,
    String? replyToMessageId,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
    Map<String, String>? quote,
  }) => _chatService.sendMessage(
    conversationId,
    content: content,
    clientMessageId: clientMessageId,
    replyToMessageId: replyToMessageId,
    imageBase64: imageBase64,
    audioBase64: audioBase64,
    imageUrl: imageUrl,
    audioUrl: audioUrl,
    quote: quote,
  );

  Future<ConversationMessage> editMessage(String messageId, String content) =>
      _chatService.editMessage(messageId, content);

  Future<List<Conversation>> getConnections() => _chatService.getConnections();

  Future<ConnectionPreferences> getConnectionPreferences() =>
      _chatService.getConnectionPreferences();

  Future<ConnectionPreferences> updateConnectionPreferences({
    required bool allowStrangers,
    DateTime? busyUntil,
  }) => _chatService.updateConnectionPreferences(
    allowStrangers: allowStrangers,
    busyUntil: busyUntil,
  );

  Future<List<ContactPermission>> getContactPermissions() =>
      _chatService.getContactPermissions();

  Future<ContactPermission> setContactPermission(
    String peerUserId, {
    required bool allowConnection,
    DateTime? mutedUntil,
  }) => _chatService.setContactPermission(
    peerUserId,
    allowConnection: allowConnection,
    mutedUntil: mutedUntil,
  );

  Future<void> deleteContactPermission(String peerUserId) =>
      _chatService.deleteContactPermission(peerUserId);

  Future<void> requestConnection(String receiverId, {String? listingId}) =>
      _chatService.requestConnection(receiverId, listingId: listingId);

  Future<void> acceptConnection(String connectionId) =>
      _chatService.acceptConnection(connectionId);

  Future<void> rejectConnection(String connectionId) =>
      _chatService.rejectConnection(connectionId);

  Future<List<ConversationMessage>> getChatConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) => _chatService.getChatConversationMessages(
    conversationId,
    limit: limit,
    offset: offset,
  );

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to AuthService)
  // -----------------------------------------------------------------

  Future<String> login(String username, String password) =>
      _authService.login(username, password);

  Future<String> register(String username, String password, {String? email}) =>
      _authService.register(username, password, email: email);

  Future<DateTime?> reauthenticate(String password, {String? totpCode}) =>
      _authService.reauthenticate(password, totpCode: totpCode);

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to UserService)
  // -----------------------------------------------------------------

  Future<Map<String, dynamic>> getUserProfile() =>
      _userService.getUserProfile();

  Future<SocialPersona?> getSocialPersona() => _userService.getSocialPersona();

  Future<SocialPersona> upsertSocialPersona({
    required String representationMode,
    String? styleVersion,
    required Map<String, String> appearanceConfig,
    required List<String> selfDescriptions,
    required String contactPosture,
  }) => _userService.upsertSocialPersona(
    representationMode: representationMode,
    styleVersion: styleVersion,
    appearanceConfig: appearanceConfig,
    selfDescriptions: selfDescriptions,
    contactPosture: contactPosture,
  );

  Future<SocialPersona> publishSocialPersona() =>
      _userService.publishSocialPersona();

  Future<SocialPersona> archiveSocialPersona() =>
      _userService.archiveSocialPersona();

  Future<SocialPersona?> getPublicSocialPersona(String userId) =>
      _userService.getPublicSocialPersona(userId);

  Future<List<CampusMembership>> getCampusMemberships() =>
      _userService.getCampusMemberships();

  Future<CampusMembershipState> getCampusMembershipState() =>
      _userService.getCampusMembershipState();

  Future<String> switchActiveCampus(String campusId) =>
      _authService.switchActiveCampus(campusId);

  Future<void> requestCampusVerification(String membershipId) =>
      _userService.requestCampusVerification(membershipId);

  Future<CampusMembership> confirmCampusVerification(
    String membershipId,
    String code,
  ) => _userService.confirmCampusVerification(membershipId, code);

  Future<Map<String, dynamic>> getUserListings({
    int limit = 20,
    int offset = 0,
    String? status,
  }) => _userService.getUserListings(
    limit: limit,
    offset: offset,
    status: status,
  );

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to ListingService)
  // -----------------------------------------------------------------

  Future<ListingsResponse> getListings({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
    List<String>? categories,
    double? minPriceCny,
    double? maxPriceCny,
    String sort = 'newest',
    String direction = 'offer',
  }) => _listingService.getListings(
    limit: limit,
    offset: offset,
    category: category,
    search: search,
    categories: categories,
    minPriceCny: minPriceCny,
    maxPriceCny: maxPriceCny,
    sort: sort,
    direction: direction,
  );

  Future<Listing> getListingDetail(String id) =>
      _listingService.getListingDetail(id);

  Future<String> createListing({
    required String title,
    required String category,
    required String brand,
    required int conditionScore,
    required double suggestedPriceCny,
    required List<String> defects,
    String? description,
    String direction = 'offer',
    String? idempotencyKey,
  }) => _listingService.createListing(
    title: title,
    category: category,
    brand: brand,
    conditionScore: conditionScore,
    suggestedPriceCny: suggestedPriceCny,
    defects: defects,
    description: description,
    direction: direction,
    idempotencyKey: idempotencyKey,
  );

  Future<void> updateListing(String id, Map<String, dynamic> updates) =>
      _listingService.updateListing(id, updates);

  Future<void> fulfillWanted(String id) => _listingService.fulfillWanted(id);

  Future<void> relistListing(String id) => _listingService.relistListing(id);

  Future<void> deleteListing(String id) => _listingService.deleteListing(id);

  Future<ListingsResponse> getWantedMatches(String wantedId) =>
      _listingService.getWantedMatches(wantedId);

  Future<String> recommendOfferForWanted({
    required String wantedId,
    required String offerListingId,
    String? message,
    String? idempotencyKey,
  }) => _listingService.recommendOfferForWanted(
    wantedId: wantedId,
    offerListingId: offerListingId,
    message: message,
    idempotencyKey: idempotencyKey,
  );

  Future<WantedResponsesResponse> getWantedResponses({
    String role = 'requester',
    String? wantedListingId,
    String? status,
    int limit = 20,
    int offset = 0,
  }) => _listingService.getWantedResponses(
    role: role,
    wantedListingId: wantedListingId,
    status: status,
    limit: limit,
    offset: offset,
  );

  Future<WantedResponseActionResult> acceptWantedResponse(String id) =>
      _listingService.acceptWantedResponse(id);

  Future<WantedResponseActionResult> dismissWantedResponse(String id) =>
      _listingService.dismissWantedResponse(id);

  Future<WantedResponseActionResult> withdrawWantedResponse(String id) =>
      _listingService.withdrawWantedResponse(id);

  Future<RecognizedItem> recognizeItem(String imageBase64) =>
      _listingService.recognizeItem(imageBase64);

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to NegotiateService)
  // -----------------------------------------------------------------

  Future<List<HitlRequest>> getNegotiations() =>
      _negotiateService.getNegotiations();

  Future<List<AgentPlan>> getAgentPlans() => _chatService.getAgentPlans();

  Future<AgentPlanConfirmResult> confirmAgentPlan(
    String id,
    String confirmationToken,
  ) => _chatService.confirmAgentPlan(id, confirmationToken);

  Future<void> cancelAgentPlan(String id) => _chatService.cancelAgentPlan(id);

  Future<List<UndoableAction>> getUndoableActions() =>
      _chatService.getUndoableActions();

  Future<UndoResult> undoAction(String id) => _chatService.undoAction(id);

  Future<Map<String, dynamic>> respondNegotiation(
    String id, {
    required String action,
    double? counterPrice,
  }) => _negotiateService.respondNegotiation(
    id,
    action: action,
    counterPrice: counterPrice,
  );

  Future<Map<String, dynamic>> acceptCounterNegotiation(String id) =>
      _negotiateService.acceptCounterNegotiation(id);

  Future<Map<String, dynamic>> rejectCounterNegotiation(String id) =>
      _negotiateService.rejectCounterNegotiation(id);

  // -----------------------------------------------------------------
  // Backward-compatibility wrappers (delegate to AdminService)
  // -----------------------------------------------------------------

  Future<Map<String, dynamic>> getAdminStats() => _adminService.getAdminStats();

  Future<Map<String, dynamic>> getAdminCapabilities() =>
      _adminService.getCapabilities();

  Future<Map<String, dynamic>> getAdminListings({
    String? status,
    int limit = 50,
    int offset = 0,
  }) => _adminService.getAdminListings(
    status: status,
    limit: limit,
    offset: offset,
  );

  Future<void> takedownListing(String listingId) =>
      _adminService.takedownListing(listingId);

  Future<void> restoreListing(String listingId, {required String reason}) =>
      _adminService.restoreListing(listingId, reason: reason);

  Future<Map<String, dynamic>> getAdminOrders({
    String? status,
    int limit = 50,
    int offset = 0,
  }) => _adminService.getAdminOrders(
    status: status,
    limit: limit,
    offset: offset,
  );

  Future<void> updateAdminOrderStatus(
    String orderId,
    String status, {
    bool? autoDelist,
    String? reason,
  }) => _adminService.updateAdminOrderStatus(
    orderId,
    status,
    autoDelist: autoDelist,
    reason: reason,
  );

  Future<Map<String, dynamic>> getAdminUsers({
    String? q,
    int limit = 20,
    int offset = 0,
  }) => _adminService.getAllUsers(q: q, limit: limit, offset: offset);

  Future<void> banUser(String userId) => _adminService.banUser(userId);

  Future<void> unbanUser(String userId) => _adminService.unbanUser(userId);

  Future<String> impersonateUserToken(String userId) =>
      _adminService.impersonateUserToken(userId);

  Future<Map<String, dynamic>> getAdminModerationCases({
    String? status,
    int limit = 50,
    int offset = 0,
  }) => _adminService.getModerationCases(
    status: status,
    limit: limit,
    offset: offset,
  );

  Future<Map<String, dynamic>> reviewModerationCase(
    String caseId, {
    required String action,
    String? note,
    String? publicReason,
  }) => _adminService.reviewModerationCase(
    caseId,
    action: action,
    note: note,
    publicReason: publicReason,
  );

  Future<Map<String, dynamic>> reviewModerationAppeal(
    String appealId, {
    required String decision,
    required String note,
  }) => _adminService.reviewModerationAppeal(
    appealId,
    decision: decision,
    note: note,
  );

  Future<Map<String, dynamic>> getModerationCases({
    String? status,
    int limit = 20,
    int offset = 0,
  }) => _userService.getModerationCases(
    status: status,
    limit: limit,
    offset: offset,
  );

  Future<Map<String, dynamic>> submitModerationAppeal(
    String caseId,
    String reason,
  ) => _userService.submitModerationAppeal(caseId, reason);
}
