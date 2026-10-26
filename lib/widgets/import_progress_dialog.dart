import 'package:flutter/material.dart';

typedef ImportTask =
    Future<int> Function(
      void Function(String message, double progress) updateProgress,
    );

/// Owns one import for the lifetime of this dialog. Rebuilds only render progress.
class ImportProgressDialog extends StatefulWidget {
  final String title;
  final ImportTask task;
  const ImportProgressDialog({
    super.key,
    required this.title,
    required this.task,
  });

  @override
  State<ImportProgressDialog> createState() => _ImportProgressDialogState();
}

class _ImportProgressDialogState extends State<ImportProgressDialog> {
  String _status = 'Initializing...';
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    try {
      final count = await widget.task((message, progress) {
        if (!mounted) return;
        setState(() {
          _status = message;
          _progress = progress.clamp(0.0, 1.0);
        });
      });
      if (mounted) Navigator.of(context).pop(count);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _error != null,
    child: AlertDialog(
      title: Text(_error == null ? widget.title : 'Import failed'),
      content: SizedBox(
        width: 400,
        child: _error != null
            ? SelectableText(_error!)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                  ),
                  const SizedBox(height: 16),
                  Text(_status),
                  const SizedBox(height: 6),
                  Text('${(_progress * 100).toInt()}% completed'),
                ],
              ),
      ),
      actions: _error == null
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
    ),
  );
}
