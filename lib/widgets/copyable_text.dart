import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the existing text layout and adds a reliable copy action to table cells.
class CopyableText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  const CopyableText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Click to copy',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          try {
            await Clipboard.setData(ClipboardData(text: data));
            if (!context.mounted) return;
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger?.hideCurrentSnackBar();
            messenger?.showSnackBar(
              const SnackBar(
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(SnackBar(content: Text('Copy failed: $e')));
            }
          }
        },
        child: Text(data, style: style, maxLines: maxLines, overflow: overflow),
      ),
    ),
  );
}
