import '../models/models.dart';
import 'base_service.dart';
import 'auth_service.dart';
import 'chat_service.dart';
import 'user_service.dart';
import 'listing_service.dart';
import 'admin_service.dart';
import 'negotiate_service.dart';

/// Remaining ApiService methods after domain split.
/// Routes to split services internally; all UI pages have migrated to individual domain services.
@Deprecated(
  'Use domain-specific services (AuthService, UserService, ListingService, AdminService, ChatService, NegotiateService) directly.',
)
class ApiService extends BaseService {
  // Static navigatorKey is inherited from BaseService — accessible as ApiService.navigatorKey
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final ListingService _listingService = ListingService();
  final AdminService _adminService = AdminService();
  final NegotiateService _negotiateService = NegotiateService();

  // -----------------------------------------------------------------
  // Conversations (legacy — prefer ChatService)
  // -----------------------------------------------------------------

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

  Future<CampusMembershipState> getCampusMembershipState() =>
      _userService.getCampusMembershipState();

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

  Future<Listing> getListingDetail(String id) =>
      _listingService.getListingDetail(id);

  Future<void> fulfillWanted(String id) => _listingService.fulfillWanted(id);

  Future<void> relistListing(String id) => _listingService.relistListing(id);

  Future<void> deleteListing(String id, {int? expectedContentRevision}) =>
      _listingService.deleteListing(
        id,
        expectedContentRevision: expectedContentRevision,
      );

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
