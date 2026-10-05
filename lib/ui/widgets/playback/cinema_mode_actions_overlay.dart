import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/media_segment.dart';
import '../../../l10n/app_localizations.dart';
import '../../../playback/cinema_mode_controller.dart';
import '../../../preference/preference_constants.dart';
import '../../../util/platform_detection.dart';
import '../adaptive/adaptive_glass.dart';
import '../focus/focus_theme.dart';
import 'skip_segment_overlay.dart';

/// The same action rail on every device. Only placement and focus presentation
/// differ; the controller owns requests, visibility, navigation and timing.
class CinemaModeActionsOverlay extends StatelessWidget {
  const CinemaModeActionsOverlay({
    super.key,
    required this.controller,
    required this.skipFocus,
    required this.requestFocus,
    required this.positionStream,
    required this.position,
    required this.countdownStyle,
    required this.onDismiss,
  });

  final CinemaModeController controller;
  final FocusNode skipFocus;
  final FocusNode requestFocus;
  final Stream<Duration> positionStream;
  final Duration position;
  final MediaSegmentCountdown countdownStyle;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final isTv = PlatformDetection.isTV;
    final mobile = PlatformDetection.isMobile && !isTv;
    final skipLabel = l10n.skipSegment(l10n.trailer);
    final status = switch (controller.seerrState) {
      CinemaSeerrState.hidden => null,
      CinemaSeerrState.request => l10n.cinemaRequestMovie,
      CinemaSeerrState.requesting => l10n.cinemaRequesting,
      CinemaSeerrState.requested => l10n.seerrRequestedStatus,
      CinemaSeerrState.pending => l10n.pendingStatus,
      CinemaSeerrState.processing => l10n.processing,
      CinemaSeerrState.partiallyAvailable => l10n.partiallyAvailable,
      CinemaSeerrState.available => l10n.seerrAvailableStatus,
    };
    final right = 24.0 + (mobile ? safe.right : 0);
    return Positioned(
      right: right,
      bottom: safe.bottom + (mobile ? 16 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - right - safe.left - 24,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (status != null) ...[
              Flexible(
                child: _SeerrAction(
                  label: status,
                  focusNode: requestFocus,
                  enabled: controller.canRequest,
                  focused:
                      isTv && controller.focusedAction == CinemaAction.request,
                  onPressed: () {
                    controller.request();
                  },
                ),
              ),
              const SizedBox(width: 12),
            ],
            // The shared dismiss chip lives inside this column, directly above
            // Skip. Neither a Seerr label nor a resolved title changes its anchor.
            SkipSegmentButton(
              key: const ValueKey('cinema-skip'),
              segment: MediaSegment(
                id: '__preroll__',
                itemId: '',
                type: MediaSegmentType.preview,
                start: Duration.zero,
                end: controller.duration,
              ),
              actionLabel: controller.movieId == null
                  ? l10n.cinemaSkip
                  : skipLabel,
              labelAlternatives: [l10n.cinemaSkip, skipLabel],
              countdownStyle: countdownStyle,
              focusNode: skipFocus,
              handleActivationKeys: false,
              isFocused: !isTv || controller.focusedAction == CinemaAction.skip,
              onSkip: () {
                if (controller.visible) controller.skip();
              },
              onDismiss: onDismiss,
              positionStream: positionStream,
              initialPosition: position,
            ),
          ],
        ),
      ),
    );
  }
}

class _SeerrAction extends StatelessWidget {
  const _SeerrAction({
    required this.label,
    required this.focusNode,
    required this.enabled,
    required this.focused,
    required this.onPressed,
  });
  final String label;
  final FocusNode focusNode;
  final bool enabled;
  final bool focused;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = AppColorScheme.isPixel ? 0.0 : 28.0;
    return Focus(
      focusNode: focusNode,
      canRequestFocus: enabled,
      skipTraversal: !enabled,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: enabled ? onPressed : null,
            borderRadius: AppRadius.circular(radius),
            child: Container(
              decoration: FocusTheme.focusDecoration(
                isFocused: focused,
                radius: radius,
              ),
              child: adaptiveGlass(
                context: context,
                cornerRadius: radius,
                blur: 24,
                fallbackColor: AppColorScheme.surface.withValues(alpha: 0.55),
                tint: AppColorScheme.surface.withValues(alpha: 0.18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColorScheme.onSurface.withValues(
                        alpha: enabled ? 1 : 0.65,
                      ),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
