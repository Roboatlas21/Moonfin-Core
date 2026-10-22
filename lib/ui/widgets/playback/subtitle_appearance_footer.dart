import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class SubtitleAppearanceFooter extends StatefulWidget {
  const SubtitleAppearanceFooter({
    super.key,
    required this.initialFontSize,
    required this.initialOffset,
    required this.initialTextColor,
    required this.defaultTextColor,
    required this.onChanged,
    this.defaultFontSize,
    this.showStyle = true,
    this.showPosition = true,
    this.showColor = true,
    this.minFontSize = 8,
    this.maxFontSize = 72,
  }) : assert(initialFontSize != null || defaultFontSize != null);

  final double? initialFontSize;
  final double? defaultFontSize;
  final double initialOffset;
  final int? initialTextColor;
  final int defaultTextColor;
  final bool showStyle;
  final bool showPosition;
  final bool showColor;
  final double minFontSize;
  final double maxFontSize;
  final void Function(double? fontSize, double offset, int? textColor)
  onChanged;

  @override
  State<SubtitleAppearanceFooter> createState() =>
      _SubtitleAppearanceFooterState();
}

class _SubtitleAppearanceFooterState extends State<SubtitleAppearanceFooter> {
  late double? _fontSize = widget.initialFontSize;
  late double _offset = widget.initialOffset;
  late int? _textColor = widget.initialTextColor;

  double get _effectiveFontSize => _fontSize ?? widget.defaultFontSize!;

  void _update({double? fontSize, double? offset}) {
    setState(() {
      if (fontSize != null) {
        _fontSize = fontSize
            .clamp(widget.minFontSize, widget.maxFontSize)
            .toDouble();
      }
      _offset = (offset ?? _offset).clamp(0.0, 0.4).toDouble();
    });
    widget.onChanged(_fontSize, _offset, _textColor);
  }

  void _resetFontSize() {
    setState(() => _fontSize = null);
    widget.onChanged(null, _offset, _textColor);
  }

  void _updateTextColor(int? textColor) {
    setState(() => _textColor = textColor);
    widget.onChanged(_fontSize, _offset, _textColor);
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
            value: _fontSize == null
                ? '${AppLocalizations.of(context).defaultLabel} (${_effectiveFontSize.toStringAsFixed(0)})'
                : _fontSize!.toStringAsFixed(0),
            onDecrease: () => _update(fontSize: _effectiveFontSize - 2),
            onIncrease: () => _update(fontSize: _effectiveFontSize + 2),
            valueWidth: widget.defaultFontSize == null ? 48 : 112,
            onReset: widget.defaultFontSize != null && _fontSize != null
                ? _resetFontSize
                : null,
          ),
        if (widget.showPosition)
          _AppearanceControlRow(
            label: AppLocalizations.of(context).verticalOffset,
            value: '${(_offset * 100).round()}%',
            onDecrease: () => _update(offset: _offset - 0.02),
            onIncrease: () => _update(offset: _offset + 0.02),
          ),
        if (widget.showStyle && widget.showColor) _buildColorControl(context),
      ],
    ),
  );

  Widget _buildColorControl(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = <({String label, int? value})>[
      (label: l10n.defaultLabel, value: null),
      (label: l10n.white, value: 0xFFFFFFFF),
      (label: l10n.yellow, value: 0xFFFFFF00),
      (label: l10n.green, value: 0xFF00FF00),
      (label: l10n.cyan, value: 0xFF00FFFF),
      (label: l10n.blue, value: 0xFF0000FF),
      (label: l10n.magenta, value: 0xFFFF00FF),
      (label: l10n.red, value: 0xFFFF0000),
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
    this.onReset,
    this.valueWidth = 48,
  });

  final String label;
  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback? onReset;
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
        child: onReset == null
            ? Text(value, textAlign: TextAlign.center)
            : Tooltip(
                message: AppLocalizations.of(context).resetToDefaults,
                child: TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.restore, size: 18),
                  label: Text(value),
                ),
              ),
      ),
      IconButton(
        tooltip: AppLocalizations.of(context).increaseValue(label),
        onPressed: onIncrease,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}
