
import 'package:flutter/material.dart';

/// A circular control button that can display an icon, image, or text
class ControlButton extends StatelessWidget {
  const ControlButton({
    super.key,
    required this.content,
    this.onPressed,
    this.onPressStart,
    this.onPressEnd,
    this.tooltip,
    this.isActive = false,
    this.isDisabled = false,
    this.semanticsLabel,
    this.semanticsHint,
    this.semanticsValue,
    this.isToggle = false,
    this.semanticsOnTap,
    this.semanticsOnLongPress,
  });

  final dynamic content;
  final VoidCallback? onPressed;
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;
  final String? tooltip;
  final bool isActive;
  final bool isDisabled;
  final String? semanticsLabel;
  final String? semanticsHint;
  final String? semanticsValue;
  final bool isToggle;
  final VoidCallback? semanticsOnTap;
  final VoidCallback? semanticsOnLongPress;

  @override
  Widget build(BuildContext context) {
    final baseButton = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDisabled ? null : (onPressed ?? () {}),
        onTapDown: isDisabled
            ? null
            : (_) {
                onPressStart?.call();
              },
        onTapUp: isDisabled
            ? null
            : (_) {
                onPressEnd?.call();
              },
        onTapCancel: isDisabled
            ? null
            : () {
                onPressEnd?.call();
              },
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: isDisabled
                ? Colors.black.withValues(alpha: 0.18)
                : isActive
                    ? Colors.blueAccent.withValues(alpha: 0.65)
                    : Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(
                alpha: isDisabled
                    ? 0.08
                    : isActive
                        ? 0.4
                        : 0.18,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDisabled ? 0.1 : 0.25),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Center(child: _buildContent()),
        ),
      ),
    );

    final button = tooltip == null
        ? baseButton
        : Tooltip(message: tooltip!, child: baseButton);

    final label = this.semanticsLabel ?? tooltip ?? _deriveLabelFromContent();

    return Semantics(
      container: true,
      excludeSemantics: true,
      enabled: !isDisabled,
      button: true,
      label: label,
      hint: semanticsHint,
      value: semanticsValue,
      toggled: isToggle ? isActive : null,
      onTap: isDisabled
          ? null
          : semanticsOnTap ?? onPressed ?? _defaultSemanticTapHandler,
      onLongPress: isDisabled
          ? null
          : semanticsOnLongPress ??
              (onPressStart != null ? () => onPressStart!.call() : null),
      child: button,
    );
  }

  Widget _buildContent() {
    if (content is IconData) {
      return Icon(content, color: Colors.white, size: 24);
    } else if (content is String && content.toString().contains('assets/')) {
      return Image.asset(content, width: 24, height: 24, color: Colors.white);
    } else if (content is String) {
      return Text(
        content,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      );
    }

    return const SizedBox.shrink();
  }

  VoidCallback get _defaultSemanticTapHandler {
    if (onPressed != null) {
      return onPressed!;
    }
    return () {
      onPressStart?.call();
      onPressEnd?.call();
    };
  }

  String? _deriveLabelFromContent() {
    if (content is String) {
      return content as String;
    }
    return null;
  }
}
