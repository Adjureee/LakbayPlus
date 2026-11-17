import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../lakbay_tokens.dart';
import '../lakbay_type.dart';
import 'lk_buttons.dart';

/// Asks before a destructive or hard-to-undo action. Resolves to `true` only
/// when the person taps the confirm button.
Future<bool> showLkConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    backgroundColor: LkColors.s1,
    shape: const RoundedRectangleBorder(borderRadius: LkRadius.sheetTop),
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(
        LkSpace.gutter,
        0,
        LkSpace.gutter,
        LkSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(title, style: LkType.h3)),
          const SizedBox(height: LkSpace.s),
          Text(message, style: LkType.body.copyWith(color: LkColors.muted)),
          const SizedBox(height: LkSpace.xxl),
          if (destructive)
            _DangerButton(
              label: confirmLabel,
              onPressed: () => Navigator.of(context).pop(true),
            )
          else
            LkButton(
              label: confirmLabel,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          const SizedBox(height: LkSpace.s),
          LkButton(
            label: cancelLabel,
            variant: LkButtonVariant.secondary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: LkColors.danger.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: LkColors.danger.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: kLkMinTarget,
            child: Center(
              child: Text(
                label,
                style: LkType.button.copyWith(
                  fontSize: 14,
                  color: LkColors.danger,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows "Trip deleted · Undo". [onUndo] runs only if Undo is tapped.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showLkUndoSnack(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 5),
}) {
  HapticFeedback.lightImpact();
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      persist: false,
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
    ),
  );
}
