import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class SubtitleAppearanceFooter extends StatefulWidget {
  const SubtitleAppearanceFooter({
    super.key,
    required this.initialFontSize,
    required this.initialOffset,
    required this.initialTextColor,
    required this.defaultTextColor,
    required this.onFontSizeChanged,
    required this.onOffsetChanged,
    required this.onTextColorChanged,
    this.secondary = false,
    this.showStyle = true,
    this.showPosition = true,
    this.showColor = true,
    this.minFontSize,
    this.maxFontSize,
    this.maxOffset = 0.4,
  });

  final double initialFontSize;
  final bool secondary;
  final double initialOffset;
  final int? initialTextColor;
  final int defaultTextColor;
  final bool showStyle;
  final bool showPosition;
  final bool showColor;
  final double? minFontSize;
  final double? maxFontSize;
  final double maxOffset;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onOffsetChanged;
  final ValueChanged<int?> onTextColorChanged;

  @override
  State<SubtitleAppearanceFooter> createState() =>
      _SubtitleAppearanceFooterState();
}

class _SubtitleAppearanceFooterState extends State<SubtitleAppearanceFooter> {
  late double _fontSize = _clampFontSize(widget.initialFontSize);
  late double _offset = _clampOffset(widget.initialOffset);
  late int? _textColor = widget.initialTextColor;

  double _clampFontSize(double value) => value
      .clamp(
        widget.minFontSize ?? (widget.secondary ? -50.0 : 12.0),
        widget.maxFontSize ?? (widget.secondary ? 50.0 : 48.0),
      )
      .toDouble();

  double _clampOffset(double value) =>
      value.clamp(widget.secondary ? -0.4 : 0.0, widget.maxOffset).toDouble();

  @override
  void didUpdateWidget(covariant SubtitleAppearanceFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFontSize != oldWidget.initialFontSize ||
        widget.minFontSize != oldWidget.minFontSize ||
        widget.maxFontSize != oldWidget.maxFontSize) {
      _fontSize = _clampFontSize(widget.initialFontSize);
    }
    if (widget.initialOffset != oldWidget.initialOffset ||
        widget.maxOffset != oldWidget.maxOffset) {
      _offset = _clampOffset(widget.initialOffset);
    }
    if (widget.initialTextColor != oldWidget.initialTextColor) {
      _textColor = widget.initialTextColor;
    }
  }

  double _stepFontSize(bool increase) {
    if (!widget.secondary) return _fontSize + (increase ? 2 : -2);
    // A shortened final step (for example +9%) returns to the regular grid.
    return (increase
            ? (_fontSize / 10).floor() + 1
            : (_fontSize / 10).ceil() - 1) *
        10.0;
  }

  String _relativeLabel(double value) => value == 0
      ? AppLocalizations.of(context).defaultLabel
      : '${value > 0 ? '+' : ''}${value.round()}%';

  void _update({double? fontSize, double? offset}) {
    setState(() {
      if (fontSize != null) {
        _fontSize = _clampFontSize(fontSize);
      }
      _offset = _clampOffset(((offset ?? _offset) * 100).round() / 100);
    });
    if (fontSize != null) widget.onFontSizeChanged(_fontSize);
    if (offset != null) widget.onOffsetChanged(_offset);
  }

  void _updateTextColor(int? textColor) {
    setState(() => _textColor = textColor);
    widget.onTextColorChanged(_textColor);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showStyle)
          _AppearanceControlRow(
            label: AppLocalizations.of(context).subtitleSize,
            value: widget.secondary
                ? _relativeLabel(_fontSize)
                : _fontSize.toStringAsFixed(0),
            onDecrease: () => _update(fontSize: _stepFontSize(false)),
            onIncrease: () => _update(fontSize: _stepFontSize(true)),
            valueWidth: widget.secondary ? 80 : 48,
          ),
        if (widget.showStyle && widget.showColor) _buildColorControl(context),
        if (widget.showPosition)
          _AppearanceControlRow(
            label: AppLocalizations.of(context).verticalOffset,
            value: widget.secondary
                ? _relativeLabel(_offset * 100)
                : '${(_offset * 100).round()}%',
            valueWidth: widget.secondary ? 80 : 48,
            onDecrease: () => _update(offset: _offset - 0.02),
            onIncrease: () => _update(offset: _offset + 0.02),
          ),
      ],
    ),
  );

  Widget _buildColorControl(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = <({String label, int? value})>[
      (label: l10n.defaultLabel, value: null),
      (label: l10n.white, value: 0xFFFFFFFF),
      (label: l10n.yellow, value: 0xFFFFFF00),
    ];
    final selectedIndex = colors.indexWhere(
      (entry) => entry.value == _textColor,
    );
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    final selected = colors[index];
    int? nextColor(int step) =>
        colors[(index + step + colors.length) % colors.length].value;

    return Row(
      children: [
        Expanded(
          child: Text(
            AppLocalizations.of(context).subtitleColour,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        IconButton(
          tooltip: AppLocalizations.of(context).playerTooltipPrevious,
          onPressed: () => _updateTextColor(nextColor(-1)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
          width: 112,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: Color(_textColor ?? widget.defaultTextColor),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white54),
                ),
              ),
              Flexible(
                child: Text(
                  selected.label,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: AppLocalizations.of(context).next,
          onPressed: () => _updateTextColor(nextColor(1)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

class _AppearanceControlRow extends StatelessWidget {
  const _AppearanceControlRow({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    this.valueWidth = 48,
  });

  final String label;
  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final double valueWidth;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Colors.white70)),
      ),
      IconButton(
        tooltip: AppLocalizations.of(context).decreaseValue(label),
        onPressed: onDecrease,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: valueWidth,
        child: Text(value, textAlign: TextAlign.center),
      ),
      IconButton(
        tooltip: AppLocalizations.of(context).increaseValue(label),
        onPressed: onIncrease,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}
