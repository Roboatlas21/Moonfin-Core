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
      .clamp(widget.secondary ? -50.0 : 12.0, widget.secondary ? 50.0 : 48.0)
      .toDouble();

  double _clampOffset(double value) =>
      value.clamp(widget.secondary ? -0.4 : 0.0, widget.maxOffset).toDouble();

  String _relativeLabel(double value) => value == 0
      ? AppLocalizations.of(context).defaultLabel
      : '${value > 0 ? '+' : ''}${value.round()}%';

  void _update({double? fontSize, double? offset}) {
    if (fontSize != null) {
      final next = _clampFontSize(fontSize);
      if (next == _fontSize) return;
      setState(() => _fontSize = next);
      widget.onFontSizeChanged(next);
    } else if (offset != null) {
      final next = _clampOffset(((offset * 100).round() / 100));
      if (next == _offset) return;
      setState(() => _offset = next);
      widget.onOffsetChanged(next);
    }
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
            onDecrease: () =>
                _update(fontSize: _fontSize - (widget.secondary ? 10 : 2)),
            onIncrease: () =>
                _update(fontSize: _fontSize + (widget.secondary ? 10 : 2)),
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
            AppLocalizations.of(context).textFillColor,
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
