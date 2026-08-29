import 'package:flutter/material.dart';

import '../../state/app_state.dart';

const _reportReasons = <(String, String)>[
  ('harassment', 'Harassment'),
  ('hate', 'Hate or discrimination'),
  ('threats', 'Threats or violence'),
  ('sexual_content', 'Unwanted sexual content'),
  ('spam', 'Spam or impersonation'),
  ('other', 'Something else'),
];

/// Opens the same safety surface from a roster entry or a chat message.
Future<void> showMemberSafetyActions(
  BuildContext context,
  AppState state, {
  required String memberId,
  required String memberName,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text('Report $memberName'),
            subtitle: const Text('A private report for the safety team.'),
            onTap: () => Navigator.pop(sheetContext, 'report'),
          ),
          ListTile(
            leading: const Icon(Icons.block_outlined),
            title: Text('Block $memberName and leave'),
            subtitle: const Text(
              'Leave this room now and never be matched together again.',
            ),
            onTap: () => Navigator.pop(sheetContext, 'block'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'report') {
    await _showReportDialog(
      context,
      state,
      memberId: memberId,
      memberName: memberName,
    );
  } else if (action == 'block') {
    await _blockAndLeave(
      context,
      state,
      memberId: memberId,
      memberName: memberName,
    );
  }
}

Future<void> _showReportDialog(
  BuildContext context,
  AppState state, {
  required String memberId,
  required String memberName,
}) async {
  final details = TextEditingController();
  var reason = _reportReasons.first.$1;
  var busy = false;
  String? error;

  final submitted = await showDialog<bool>(
    context: context,
    barrierDismissible: !busy,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Report $memberName'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: reason,
                decoration: const InputDecoration(labelText: 'Reason'),
                items: [
                  for (final item in _reportReasons)
                    DropdownMenuItem(value: item.$1, child: Text(item.$2)),
                ],
                onChanged: busy
                    ? null
                    : (value) => setDialogState(() => reason = value ?? reason),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: details,
                enabled: !busy,
                maxLength: 2000,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'What happened? (optional)',
                  alignLabelWithHint: true,
                ),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setDialogState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await state.repo.reportUser(
                        groupId: state.group!.id,
                        reportedUserId: memberId,
                        reason: reason,
                        details: details.text.trim().isEmpty
                            ? null
                            : details.text.trim(),
                      );
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } catch (_) {
                      if (!dialogContext.mounted) return;
                      setDialogState(() {
                        busy = false;
                        error = 'Could not send the report. Try again.';
                      });
                    }
                  },
            child: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send report'),
          ),
        ],
      ),
    ),
  );
  details.dispose();
  if (submitted == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report sent privately.')));
  }
}

Future<void> _blockAndLeave(
  BuildContext context,
  AppState state, {
  required String memberId,
  required String memberName,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Block $memberName and leave?'),
      content: const Text(
        'You will immediately lose access to this room. You will not be matched together again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Block and leave'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    // Persist the block first while the shared-group authorization still exists, then revoke the
    // membership. If leaving fails, the future-match exclusion remains safely in place.
    await state.repo.blockUser(memberId);
    await state.leaveCurrentGroup();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not leave the group. Try again.')),
    );
  }
}

Future<void> confirmLeaveGroup(BuildContext context, AppState state) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leave this group?'),
      content: const Text(
        'You will immediately lose access to the chat, roster, and group photos.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Stay'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Leave group'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await state.leaveCurrentGroup();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not leave the group. Try again.')),
    );
  }
}
