
import 'package:flutter/material.dart';

class HoverScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool showShadow;

  const HoverScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 1.02,
    this.showShadow = true,
  });

  @override
  State<HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<HoverScale> {
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
          transform: Matrix4.identity()..scale(_isHovering ? widget.scale : 1.0),
          decoration: widget.showShadow && _isHovering
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(24), // Match common radius
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
