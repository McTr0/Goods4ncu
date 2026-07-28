import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class ContentReportResult {
  const ContentReportResult({required this.reason, this.details});

  final String reason;
  final String? details;
}

Future<ContentReportResult?> showContentReportDialog({
  required BuildContext context,
  required String title,
}) => showDialog<ContentReportResult>(
  context: context,
  builder: (_) => _ContentReportDialog(title: title),
);

class _ContentReportDialog extends StatefulWidget {
  const _ContentReportDialog({required this.title});

  final String title;

  @override
  State<_ContentReportDialog> createState() => _ContentReportDialogState();
}

class _ContentReportDialogState extends State<_ContentReportDialog> {
  final _formKey = GlobalKey<FormState>();
  TextEditingController? _reasonController;
  final TextEditingController _detailsController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reasonController ??= TextEditingController(
      text: AppLocalizations.of(context)!.reportReasonDefault,
    );
  }

  @override
  void dispose() {
    _reasonController?.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final details = _detailsController.text.trim();
    Navigator.pop(
      context,
      ContentReportResult(
        reason: _reasonController!.text.trim(),
        details: details.isEmpty ? null : details,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('content-report-reason'),
                controller: _reasonController,
                decoration: InputDecoration(labelText: l.reportReasonLabel),
                maxLength: 80,
                textInputAction: TextInputAction.next,
                validator: (value) => value == null || value.trim().isEmpty
                    ? l.reportReasonRequired
                    : null,
              ),
              TextFormField(
                key: const Key('content-report-details'),
                controller: _detailsController,
                decoration: InputDecoration(labelText: l.reportDetailsLabel),
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const Key('content-report-submit'),
          onPressed: _submit,
          child: Text(l.submitAction),
        ),
      ],
    );
  }
}
