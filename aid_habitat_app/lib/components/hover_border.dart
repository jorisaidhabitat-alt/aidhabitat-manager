import 'package:flutter/material.dart';

class HoverBorder extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color borderColor;
  final double borderWidth;
  final double borderRadius;

  const HoverBorder({
    super.key,
    required this.child,
    this.onTap,
    this.borderColor = const Color(0xFF907CA1), // Primary color
    this.borderWidth = 2.0,
    this.borderRadius = 16.0,
  });

  @override
  State<HoverBorder> createState() => _HoverBorderState();
}

class _HoverBorderState extends State<HoverBorder> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(8), // Add some padding so border doesn't touch content tightly
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _isHovering ? widget.borderColor : Colors.transparent,
              width: widget.borderWidth,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
