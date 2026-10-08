import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/media_segment.dart';
import '../../../l10n/app_localizations.dart';
import '../../../playback/cinema_mode_controller.dart';
import '../../../preference/preference_constants.dart';
import '../../../util/platform_detection.dart';
import 'skip_segment_overlay.dart';

String? cinemaRequestLabel(
  CinemaModeController controller,
  AppLocalizations l10n,
) => switch (controller.seerrState) {
  CinemaSeerrState.hidden => null,
  CinemaSeerrState.request =>
    controller.isSeries
        ? l10n.requestSeriesOrMovie(l10n.series)
        : l10n.cinemaRequestMovie,
  CinemaSeerrState.requesting => l10n.cinemaRequesting,
  CinemaSeerrState.requested => l10n.seerrRequestedStatus,
  CinemaSeerrState.pending => l10n.pendingStatus,
  CinemaSeerrState.processing => l10n.processing,
  CinemaSeerrState.partiallyAvailable => l10n.partiallyAvailable,
  CinemaSeerrState.available => l10n.seerrAvailableStatus,
};

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
    final status = cinemaRequestLabel(controller, l10n);
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
                child: _seerrAction(
                  context,
                  label: status,
                  focusNode: requestFocus,
                  enabled: controller.canRequest,
                  focused:
                      isTv && controller.focusedAction == CinemaAction.request,
                  onPressed: () => controller.request(),
                ),
              ),
              const SizedBox(width: 12),
            ],
            // The shared dismiss chip lives inside this column, directly above
            // Skip. Neither a Seerr label nor a resolved title changes its anchor.
            SkipSegmentOverlay(
              key: const ValueKey('cinema-skip'),
              inline: true,
              segment: MediaSegment(
                id: '__preroll__',
                itemId: '',
                type: MediaSegmentType.preview,
                start: Duration.zero,
                end: controller.duration,
              ),
              actionLabel: controller.media == null
                  ? l10n.cinemaSkip
                  : skipLabel,
              labelAlternatives: [l10n.cinemaSkip, skipLabel],
              countdownStyle: countdownStyle,
              focusNode: skipFocus,
              handleActivationKeys: false,
              isFocused:
                  isTv && controller.focusedAction == CinemaAction.skip,
              outlineColor: isTv
                  ? AppColorScheme.onSurface
                  : AppColorScheme.accent,
              countdownColor: AppColorScheme.onSurface,
              focusRingColor: isTv ? AppColorScheme.accent : null,
              onSkip: controller.skip,
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

Widget _seerrAction(
  BuildContext context, {
  required String label,
  required FocusNode focusNode,
  required bool enabled,
  required bool focused,
  required VoidCallback onPressed,
}) {
  final isTv = PlatformDetection.isTV;
  final focusColor = isTv ? AppColorScheme.accent : null;
  return Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        focusNode: focusNode,
        canRequestFocus: enabled,
        onTap: enabled ? onPressed : null,
        borderRadius: AppRadius.circular(playbackActionFocusRadius(focusColor)),
        child: playbackGlassAction(
          context: context,
          focusKey: const ValueKey('cinema-request-focus-ring'),
          outlineKey: const ValueKey('cinema-request-outline'),
          isFocused: focused,
          focusRingColor: focusColor,
          outlineColor: enabled
              ? (isTv ? AppColorScheme.onSurface : AppColorScheme.accent)
              : AppColorScheme.onSurface.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
  );
}
