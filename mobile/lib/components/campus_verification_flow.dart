import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/user_service.dart';

/// Walks a pending campus membership through school-email OTP verification.
///
/// Shared by the profile entry, the post-registration prompt and the
/// `campus_verification_required` (403) handler so every gate leads to the
/// same flow. Returns the verified membership, or null if the user cancelled
/// or a step failed (failures are surfaced as snackbars and stay retryable).
Future<CampusMembership?> runCampusVerificationFlow(
  BuildContext context, {
  required UserService userService,
  required CampusMembership membership,
}) async {
  final l = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  final send = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.verifyCampusIdentity),
      content: Text(l.campusVerificationSendHint),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l.cancel),
        ),
        ElevatedButton(
          key: const Key('campus-verification-send'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l.sendVerificationCode),
        ),
      ],
    ),
  );
  if (send != true) return null;

  try {
    await userService.requestCampusVerification(membership.id);
  } catch (e) {
    // Delivery failures are retryable immediately (cooldown only applies to
    // codes that were actually delivered), so just report and let them retry.
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    return null;
  }
  messenger.showSnackBar(SnackBar(content: Text(l.verificationCodeSent)));

  if (!context.mounted) return null;
  final code = await showDialog<String>(
    context: context,
    builder: (_) => const _VerificationCodeDialog(),
  );
  if (code == null || code.isEmpty) return null;

  try {
    final verified = await userService.confirmCampusVerification(
      membership.id,
      code,
    );
    messenger.showSnackBar(
      SnackBar(content: Text(l.campusVerificationSuccess)),
    );
    return verified;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    return null;
  }
}

/// Owns its controller so it is disposed with the dialog route, after the
/// exit animation has stopped rebuilding the field.
class _VerificationCodeDialog extends StatefulWidget {
  const _VerificationCodeDialog();

  @override
  State<_VerificationCodeDialog> createState() =>
      _VerificationCodeDialogState();
}

class _VerificationCodeDialogState extends State<_VerificationCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.verifyCampusIdentity),
      content: TextField(
        key: const Key('campus-verification-code'),
        controller: _controller,
        keyboardType: TextInputType.number,
        maxLength: 6,
        autofocus: true,
        decoration: InputDecoration(labelText: l.verificationCode),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        ElevatedButton(
          key: const Key('campus-verification-confirm'),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l.confirmVerification),
        ),
      ],
    );
  }
}
