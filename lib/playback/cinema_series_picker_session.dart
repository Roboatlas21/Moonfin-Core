import 'dart:async';

/// A picker may outlive its trailer briefly, but never its account or player.
class CinemaSeriesPickerSession {
  CinemaSeriesPickerSession({
    required Object Function() accountKey,
    required bool Function() isMounted,
  }) : _accountKey = accountKey,
       _isMounted = isMounted,
       _account = accountKey();

  final Object Function() _accountKey;
  final bool Function() _isMounted;
  final Object _account;
  Timer? _graceTimer;
  void Function()? _dismissDialog;
  bool _active = true;
  bool _submitting = false;
  bool _closeRequested = false;

  bool get isCurrent => _active && _isMounted() && _account == _accountKey();

  set dismissDialog(void Function() dismiss) {
    _dismissDialog = dismiss;
    if (_closeRequested && _isMounted()) dismiss();
  }

  void beginGrace() {
    if (!isCurrent || _submitting || _graceTimer != null) return;
    _graceTimer = Timer(const Duration(seconds: 10), close);
  }

  void markSubmitting() {
    if (!isCurrent) return;
    _submitting = true;
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  /// Skip advances playback but must not cancel an in-flight submission.
  /// Return whether the picker was closed so the player can clear its handle.
  bool closeForSkip() {
    if (_submitting && isCurrent) return false;
    close();
    return true;
  }

  void close() {
    if (_closeRequested) return;
    _closeRequested = true;
    dispose();
    if (_isMounted()) _dismissDialog?.call();
  }

  void dispose() {
    _active = false;
    _graceTimer?.cancel();
    _graceTimer = null;
  }
}
