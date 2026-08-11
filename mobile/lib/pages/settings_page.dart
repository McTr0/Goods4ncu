import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../components/payment_qr_image.dart';
import '../l10n/app_localizations.dart';
import '../services/locale_service.dart';
import '../services/user_service.dart';
import '../services/base_service.dart';
import '../services/feed_feedback_service.dart';
import '../theme/app_theme.dart';

class SettingsPage extends StatefulWidget {
  final UserService? userService;
  final FeedFeedbackService? feedbackService;

  const SettingsPage({super.key, this.userService, this.feedbackService});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final UserService _userService;
  late final FeedFeedbackService _feedbackService;

  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;
  bool? _personalizationEnabled;
  bool _preferencesLoading = true;
  bool _preferencesUpdating = false;
  bool _personalizationClearing = false;

  @override
  void initState() {
    super.initState();
    _userService = widget.userService ?? context.read<UserService>();
    _feedbackService =
        widget.feedbackService ?? context.read<FeedFeedbackService>();
    _loadProfile();
    _loadFeedPreferences();
  }

  Future<void> _loadFeedPreferences() async {
    try {
      final preferences = await _feedbackService.getPreferences();
      if (!mounted) return;
      setState(() {
        _personalizationEnabled = preferences.personalizationEnabled;
        _preferencesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _personalizationEnabled = null;
        _preferencesLoading = false;
      });
    }
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await _userService.getUserProfile();
      if (mounted) {
        setState(() {
          _profile = profile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _loadProfile, child: Text(l.retry)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppTheme.sp16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAvatarHeader(),
                  const SizedBox(height: AppTheme.sp24),

                  // Nickname
                  _SettingsCard(
                    icon: Icons.person_outline,
                    title: l.nickname,
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        _profile?['username'] ?? '',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onTap: () => _showNicknameDialog(context),
                  ),
                  const SizedBox(height: 12),

                  // Email
                  _SettingsCard(
                    icon: Icons.email_outlined,
                    title: l.emailLabel,
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        _profile?['email'] ?? l.notSet,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onTap: () => _showEmailDialog(context),
                  ),
                  const SizedBox(height: 12),

                  _buildDiscoverySettings(),
                  const SizedBox(height: 12),

                  _buildFeedSettings(),
                  const SizedBox(height: 12),

                  _buildPaymentQrSettings(),
                  const SizedBox(height: 12),

                  // Language
                  _SettingsCard(
                    icon: Icons.language,
                    title: l.language,
                    trailing: Text(
                      context.localeNotifier().locale.languageCode == 'zh'
                          ? l.chinese
                          : l.english,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    onTap: () => _showLanguageDialog(context),
                  ),
                  const SizedBox(height: 24),

                  // User agreement section
                  _SectionHeader(title: l.userAgreement),
                  const SizedBox(height: 8),

                  _SettingsCard(
                    icon: Icons.description_outlined,
                    title: l.userAgreement,
                    subtitle: l.userAgreementSubtitle,
                    onTap: () => _showAboutDialog(context),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildAvatarHeader() {
    final avatarUrl = _profile?['avatar_url'] as String?;
    final username = _profile?['username'] as String? ?? '';

    return Center(
      child: GestureDetector(
        onTap: () => _pickAndUploadAvatar(context),
        child: Stack(
          children: [
            CircleAvatar(
              radius: 52,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
              backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                  ? NetworkImage(avatarUrl)
                  : null,
              child: avatarUrl == null || avatarUrl.isEmpty
                  ? Text(
                      username.isNotEmpty ? username[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primary,
                      ),
                    )
                  : null,
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: AppTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverySettings() {
    final l = AppLocalizations.of(context)!;
    final discoverability =
        (_profile?['discoverability'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final email = _profile?['email'] as String?;
    final studentId = _profile?['student_id'] as String?;
    final canUseStudentId = studentId != null && studentId.isNotEmpty;
    final usernameEnabled = discoverability['username'] != false;
    final emailEnabled = discoverability['email'] == true;
    final studentIdEnabled =
        canUseStudentId && discoverability['student_id'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l.discoverabilitySettingsTitle),
        const SizedBox(height: 8),
        _DiscoverySwitchCard(
          icon: Icons.badge_outlined,
          title: l.discoverByUsernameTitle,
          subtitle: l.discoverByUsernameSubtitle,
          value: usernameEnabled,
          onChanged: (value) => _updateDiscoverySetting('username', value),
        ),
        const SizedBox(height: 8),
        _DiscoverySwitchCard(
          icon: Icons.alternate_email_rounded,
          title: l.discoverByEmailTitle,
          subtitle: email == null || email.isEmpty
              ? l.discoverByEmailMissingSubtitle
              : l.discoverByEmailSubtitle(email),
          value: emailEnabled,
          onChanged: email == null || email.isEmpty
              ? null
              : (value) => _updateDiscoverySetting('email', value),
        ),
        const SizedBox(height: 8),
        _DiscoverySwitchCard(
          icon: Icons.school_outlined,
          title: l.discoverByStudentIdTitle,
          subtitle: canUseStudentId
              ? l.discoverByStudentIdSubtitle(studentId)
              : l.discoverByStudentIdMissingSubtitle,
          value: studentIdEnabled,
          onChanged: canUseStudentId
              ? (value) => _updateDiscoverySetting('student_id', value)
              : null,
        ),
      ],
    );
  }

  Future<void> _updateDiscoverySetting(String key, bool value) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await _userService.updateProfile(
        discoverability: {key: value},
      );
      if (!mounted) return;
      setState(() => _profile = updated);
      messenger.showSnackBar(SnackBar(content: Text(l.discoverabilityUpdated)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.settingsUpdateFailed(error.toString()))),
      );
    }
  }

  Widget _buildFeedSettings() {
    final l = AppLocalizations.of(context)!;
    final enabled = _personalizationEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l.feedPreferencesSectionTitle),
        const SizedBox(height: 8),
        _DiscoverySwitchCard(
          icon: Icons.auto_awesome_outlined,
          title: l.feedPersonalizationTitle,
          subtitle: _preferencesLoading || enabled == null
              ? l.feedPersonalizationUnavailable
              : enabled
              ? l.feedPersonalizationOnSubtitle
              : l.feedPersonalizationOffSubtitle,
          value: enabled ?? false,
          onChanged:
              _preferencesLoading || _preferencesUpdating || enabled == null
              ? null
              : _updatePersonalization,
        ),
        const SizedBox(height: 8),
        _SettingsCard(
          icon: Icons.restart_alt_outlined,
          title: l.feedPersonalizationClearTitle,
          subtitle: l.feedPersonalizationClearSubtitle,
          trailing: _personalizationClearing
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: () {
            if (!_personalizationClearing) _confirmClearPersonalization();
          },
        ),
      ],
    );
  }

  Future<void> _updatePersonalization(bool enabled) async {
    if (_preferencesUpdating) return;
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _preferencesUpdating = true);
    try {
      final updated = await _feedbackService.updatePersonalization(enabled);
      if (!mounted) return;
      setState(() => _personalizationEnabled = updated.personalizationEnabled);
      messenger.showSnackBar(
        SnackBar(content: Text(l.feedPersonalizationUpdated)),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.feedPreferencesUpdateFailed)),
      );
    } finally {
      if (mounted) setState(() => _preferencesUpdating = false);
    }
  }

  Future<void> _confirmClearPersonalization() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.feedPersonalizationClearConfirmTitle),
        content: Text(l.feedPersonalizationClearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.feedPersonalizationClearAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _personalizationClearing) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _personalizationClearing = true);
    try {
      await _feedbackService.clearPersonalization();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.feedPersonalizationCleared)),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.feedPersonalizationClearFailed)),
      );
    } finally {
      if (mounted) setState(() => _personalizationClearing = false);
    }
  }

  Widget _buildPaymentQrSettings() {
    final l = AppLocalizations.of(context)!;
    final paymentQr =
        (_profile?['payment_qr'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final wechatUrl = paymentQr['wechat_url'] as String?;
    final alipayUrl = paymentQr['alipay_url'] as String?;
    final showWechat = paymentQr['show_wechat'] == true;
    final showAlipay = paymentQr['show_alipay'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l.paymentQrSettingsTitle),
        const SizedBox(height: 8),
        Text(
          l.paymentQrSettingsSubtitle,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        _PaymentQrCard(
          icon: Icons.qr_code_2_rounded,
          title: l.wechatPayQr,
          uploadLabel: l.uploadWechatQr,
          showLabel: l.showWechatQr,
          imageUrl: wechatUrl,
          visible: showWechat,
          onUpload: () => _pickAndUploadPaymentQr('wechat'),
          onClear: wechatUrl == null || wechatUrl.isEmpty
              ? null
              : () => _clearPaymentQr('wechat'),
          onVisibilityChanged: (value) =>
              _updatePaymentQrVisibility('wechat', value),
        ),
        const SizedBox(height: 8),
        _PaymentQrCard(
          icon: Icons.account_balance_wallet_outlined,
          title: l.alipayQr,
          uploadLabel: l.uploadAlipayQr,
          showLabel: l.showAlipayQr,
          imageUrl: alipayUrl,
          visible: showAlipay,
          onUpload: () => _pickAndUploadPaymentQr('alipay'),
          onClear: alipayUrl == null || alipayUrl.isEmpty
              ? null
              : () => _clearPaymentQr('alipay'),
          onVisibilityChanged: (value) =>
              _updatePaymentQrVisibility('alipay', value),
        ),
        const SizedBox(height: 8),
        Text(
          l.paymentQrSafetyHint,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Future<void> _updatePaymentQrVisibility(String provider, bool value) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final paymentQr =
        (_profile?['payment_qr'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final urlKey = provider == 'wechat' ? 'wechat_url' : 'alipay_url';
    final showKey = provider == 'wechat' ? 'show_wechat' : 'show_alipay';
    final url = paymentQr[urlKey] as String?;
    if (value && (url == null || url.isEmpty)) {
      messenger.showSnackBar(SnackBar(content: Text(l.paymentQrMissingHint)));
      return;
    }

    try {
      final updated = await _userService.updateProfile(
        paymentQr: {showKey: value},
      );
      if (!mounted) return;
      setState(() => _profile = updated);
      messenger.showSnackBar(SnackBar(content: Text(l.paymentQrUpdated)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.operationFailed(error.toString()))),
      );
    }
  }

  Future<void> _clearPaymentQr(String provider) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final urlKey = provider == 'wechat' ? 'wechat_url' : 'alipay_url';
    final showKey = provider == 'wechat' ? 'show_wechat' : 'show_alipay';
    try {
      final updated = await _userService.updateProfile(
        paymentQr: {urlKey: '', showKey: false},
      );
      if (!mounted) return;
      setState(() => _profile = updated);
      messenger.showSnackBar(SnackBar(content: Text(l.paymentQrCleared)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.operationFailed(error.toString()))),
      );
    }
  }

  Future<void> _pickAndUploadPaymentQr(String provider) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final source = await _pickImageSource(context);
    if (source == null) return;

    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 92,
    );
    if (pickedFile == null) return;

    try {
      messenger.showSnackBar(SnackBar(content: Text('${l.uploading}...')));
      final url = await _uploadImageToOss(
        pickedFile,
        folder: 'payment_qr',
        prefix: provider,
      );
      final updated = await _userService.updateProfile(
        paymentQr: provider == 'wechat'
            ? {'wechat_url': url, 'show_wechat': true}
            : {'alipay_url': url, 'show_alipay': true},
      );
      if (!mounted) return;
      setState(() => _profile = updated);
      messenger.showSnackBar(SnackBar(content: Text(l.paymentQrUpdated)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('${l.uploadFailed}: $error')),
      );
    }
  }

  Future<ImageSource?> _pickImageSource(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l.gallery),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(l.camera),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _uploadImageToOss(
    XFile pickedFile, {
    required String folder,
    required String prefix,
  }) async {
    final stsToken = await _userService.getUploadToken();
    final imageBytes = await pickedFile.readAsBytes();
    final userId = _profile?['user_id'] ?? 'unknown';
    final ext = pickedFile.path.split('.').last.toLowerCase();
    final objectKey = '$folder/$userId/$prefix-${const Uuid().v4()}.$ext';
    final endpointHost = stsToken.endpoint
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final ossUrl = Uri.https('${stsToken.bucket}.$endpointHost', objectKey);
    final contentType = 'image/${ext == 'jpg' ? 'jpeg' : ext}';
    final ossDate = _buildOssDateHeader();
    final authorization = _buildOssAuthorization(
      method: 'PUT',
      contentType: contentType,
      date: ossDate,
      bucket: stsToken.bucket,
      objectKey: objectKey,
      accessKeyId: stsToken.accessKeyId,
      accessKeySecret: stsToken.accessKeySecret,
      securityToken: stsToken.securityToken,
    );

    final ossResponse = await http
        .put(
          ossUrl,
          headers: {
            'Date': ossDate,
            'Authorization': authorization,
            'x-oss-security-token': stsToken.securityToken,
            'Content-Type': contentType,
          },
          body: imageBytes,
        )
        .timeout(const Duration(seconds: 30));

    if (ossResponse.statusCode != 200) {
      throw Exception('OSS upload failed: ${ossResponse.statusCode}');
    }

    return ossUrl.toString();
  }

  Future<void> _pickAndUploadAvatar(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final source = await _pickImageSource(context);
    if (source == null) return;

    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (pickedFile == null) return;

    try {
      messenger.showSnackBar(SnackBar(content: Text('${l.uploading}...')));

      final avatarUrl = await _uploadImageToOss(
        pickedFile,
        folder: 'avatars',
        prefix: 'avatar',
      );
      final updated = await _userService.updateProfile(avatarUrl: avatarUrl);
      if (mounted) {
        setState(() => _profile = updated);
        messenger.showSnackBar(SnackBar(content: Text(l.avatarUpdated)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('${l.uploadFailed}: $e')),
        );
      }
    }
  }

  String _buildOssDateHeader() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final now = DateTime.now().toUtc();
    final weekday = weekdays[now.weekday - 1];
    final day = now.day.toString().padLeft(2, '0');
    final month = months[now.month - 1];
    final year = now.year;
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    return '$weekday, $day $month $year $hour:$minute:$second GMT';
  }

  String _buildOssAuthorization({
    required String method,
    required String contentType,
    required String date,
    required String bucket,
    required String objectKey,
    required String accessKeyId,
    required String accessKeySecret,
    required String securityToken,
  }) {
    final canonicalHeaders = 'x-oss-security-token:$securityToken\n';
    final canonicalResource = '/$bucket/$objectKey';
    final stringToSign =
        '$method\n\n$contentType\n$date\n$canonicalHeaders$canonicalResource';
    final hmac = Hmac(sha1, utf8.encode(accessKeySecret));
    final signature = base64Encode(
      hmac.convert(utf8.encode(stringToSign)).bytes,
    );
    return 'OSS $accessKeyId:$signature';
  }

  void _showNicknameDialog(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: _profile?['username'] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.nicknameChange),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: l.nickname,
                hintText: l.nicknameChangeHint,
              ),
              maxLength: 50,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              final nickname = controller.text.trim();
              if (nickname.isEmpty) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l.nicknameEmpty)));
                return;
              }
              Navigator.pop(ctx);
              await _updateNickname(context, nickname);
            },
            child: Text(l.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _updateNickname(BuildContext context, String nickname) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await _userService.updateProfile(username: nickname);
      if (mounted) {
        setState(() => _profile = updated);
        messenger.showSnackBar(
          SnackBar(content: Text(l.nicknameChangeSuccess)),
        );
      }
    } on ConflictException catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l.operationFailed(e.toString()))),
        );
      }
    }
  }

  void _showEmailDialog(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: _profile?['email'] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.emailChange),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: l.emailLabel,
                hintText: l.emailChangeHint,
              ),
              maxLength: 100,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = controller.text.trim();
              Navigator.pop(ctx);
              await _updateEmail(context, email);
            },
            child: Text(l.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _updateEmail(BuildContext context, String email) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    // Campus email domains are validated server-side against the active
    // campus list — a hardcoded single-campus check here would block every
    // newly onboarded campus.
    if (email.isNotEmpty && !email.contains('@')) {
      messenger.showSnackBar(SnackBar(content: Text(l.emailDomainError)));
      return;
    }
    try {
      final updated = await _userService.updateProfile(
        email: email.isEmpty ? null : email,
      );
      if (mounted) {
        setState(() => _profile = updated);
        messenger.showSnackBar(SnackBar(content: Text(l.emailChangeSuccess)));
      }
    } on ConflictException catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l.operationFailed(e.toString()))),
        );
      }
    }
  }

  void _showLanguageDialog(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.language),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(l.english),
              onTap: () {
                ctx.localeNotifier().setLocale(const Locale('en'));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: Text(l.chinese),
              onTap: () {
                ctx.localeNotifier().setLocale(const Locale('zh'));
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    showAboutDialog(
      context: context,
      applicationName: l.appTitle,
      applicationVersion: '1.0.0',
      applicationLegalese: l.platformDisclaimer,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SettingsCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.sp16,
          vertical: AppTheme.sp8,
        ),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppTheme.primary),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              )
            : null,
        trailing:
            trailing ??
            const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: onTap,
      ),
    );
  }
}

class _DiscoverySwitchCard extends StatelessWidget {
  const _DiscoverySwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.sp16,
          vertical: AppTheme.sp6,
        ),
        secondary: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: enabled ? 0.1 : 0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: enabled ? AppTheme.primary : AppTheme.textSecondary,
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _PaymentQrCard extends StatelessWidget {
  const _PaymentQrCard({
    required this.icon,
    required this.title,
    required this.uploadLabel,
    required this.showLabel,
    required this.imageUrl,
    required this.visible,
    required this.onUpload,
    required this.onClear,
    required this.onVisibilityChanged,
  });

  final IconData icon;
  final String title;
  final String uploadLabel;
  final String showLabel;
  final String? imageUrl;
  final bool visible;
  final VoidCallback onUpload;
  final VoidCallback? onClear;
  final ValueChanged<bool> onVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp12),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: hasImage
                      ? PaymentQrImage(
                          url: imageUrl!,
                          label: title,
                          fit: BoxFit.cover,
                        )
                      : Icon(icon, color: AppTheme.primary),
                ),
                const SizedBox(width: AppTheme.sp12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasImage ? uploadLabel : '$uploadLabel · ${l.notSet}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: AppTheme.sp8),
                      Wrap(
                        spacing: AppTheme.sp8,
                        runSpacing: AppTheme.sp8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: onUpload,
                            icon: const Icon(Icons.upload_file_rounded),
                            label: Text(uploadLabel),
                          ),
                          if (hasImage)
                            TextButton.icon(
                              onPressed: onClear,
                              icon: const Icon(Icons.delete_outline),
                              label: Text(l.delete),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(showLabel),
              subtitle: Text(
                hasImage ? l.paymentQrSafetyHint : l.paymentQrMissingHint,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              value: visible && hasImage,
              onChanged: onVisibilityChanged,
            ),
          ],
        ),
      ),
    );
  }
}
