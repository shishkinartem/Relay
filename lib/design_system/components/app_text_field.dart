import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// `.input` — a square, hairline-bordered field on the system surface.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.label,
    this.readOnly = false,
    this.monospace = false,
    this.obscureText = false,
    this.minHeight = 36,
    this.onSubmitted,
    this.onChanged,
    this.inputFormatters,
    this.semanticLabel,
    this.focusNode,
  });

  final TextEditingController controller;
  final String? label;
  final bool readOnly;

  /// Masks the value as it is typed — a bot token, an API key. The field is
  /// still never read back out of storage for display (§27).
  final bool obscureText;

  /// The recording-name field is monospaced (design `1i`).
  final bool monospace;

  final double minHeight;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final String? semanticLabel;
  final FocusNode? focusNode;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool focused = _focusNode.hasFocus;
    final Color border = focused
        ? AppColors.accent
        : _hovered
        ? AppColors.ink(45)
        : AppColors.divider;

    final TextStyle style = widget.monospace
        ? AppTypography.mono.copyWith(
            fontSize: 11.5,
            height: 1.4,
            color: AppColors.text,
          )
        : AppTypography.input;

    final Widget field = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.text,
      child: Container(
        constraints: BoxConstraints(minHeight: widget.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: border),
        ),
        child: EditableText(
          controller: widget.controller,
          focusNode: _focusNode,
          readOnly: widget.readOnly,
          style: style,
          cursorColor: AppColors.accent,
          backgroundCursorColor: AppColors.neutral400,
          selectionColor: AppColors.selection,
          maxLines: 1,
          obscureText: widget.obscureText,
          inputFormatters: widget.inputFormatters,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          rendererIgnoresPointer: false,
          enableInteractiveSelection: true,
        ),
      ),
    );

    final Widget labelled = widget.label == null
        ? field
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  widget.label!,
                  style: AppTypography.fieldLabel.copyWith(
                    color: AppColors.textLabel,
                  ),
                ),
              ),
              field,
            ],
          );

    return Semantics(
      textField: true,
      label: widget.semanticLabel ?? widget.label,
      readOnly: widget.readOnly,
      child: labelled,
    );
  }
}
