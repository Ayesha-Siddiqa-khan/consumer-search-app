import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SearchableSelectField extends StatelessWidget {
  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final double? width;
  final String allItemLabel;
  final Set<String>? selectedValues;
  final ValueChanged<Set<String>>? onMultiChanged;

  const SearchableSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.allItemLabel = 'All',
    this.selectedValues,
    this.onMultiChanged,
  });

  void _openSearchDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return _SearchableDialog(
          label: label,
          currentValue: value,
          items: items,
          allItemLabel: allItemLabel,
          selectedValues: selectedValues,
          onMultiSelected: onMultiChanged == null
              ? null
              : (selected) {
                  Navigator.of(ctx).pop();
                  onMultiChanged!(selected);
                },
          onSelected: (selected) {
            Navigator.of(ctx).pop();
            onChanged(selected);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = selectedValues != null
        ? selectedValues!.isEmpty
        : value.startsWith('All ');
    final displayText = selectedValues != null && selectedValues!.isNotEmpty
        ? '${selectedValues!.length} sectors selected'
        : value.isNotEmpty
        ? value
        : allItemLabel;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () => _openSearchDialog(context),
        borderRadius: BorderRadius.circular(6),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            suffixIcon: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search, size: 16, color: Colors.grey),
                Icon(Icons.arrow_drop_down, size: 20, color: Colors.grey),
              ],
            ),
          ),
          child: Text(
            displayText,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isDefault ? FontWeight.normal : FontWeight.bold,
              color: isDefault ? Colors.grey.shade700 : AppTheme.primaryGreen,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _SearchableDialog extends StatefulWidget {
  final String label;
  final String currentValue;
  final List<String> items;
  final String allItemLabel;
  final ValueChanged<String> onSelected;
  final Set<String>? selectedValues;
  final ValueChanged<Set<String>>? onMultiSelected;

  const _SearchableDialog({
    required this.label,
    required this.currentValue,
    required this.items,
    required this.allItemLabel,
    required this.onSelected,
    this.selectedValues,
    this.onMultiSelected,
  });

  @override
  State<_SearchableDialog> createState() => _SearchableDialogState();
}

class _SearchableDialogState extends State<_SearchableDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<String> _filteredItems = [];
  late bool _multiple;
  late Set<String> _selected;
  List<String> get _choices =>
      widget.items.where((item) => item != widget.allItemLabel).toList();

  @override
  void initState() {
    super.initState();
    _filteredItems = List.from(widget.items);
    _multiple = widget.selectedValues != null;
    _selected = {
      ...?widget.selectedValues,
      if (widget.selectedValues == null &&
          widget.currentValue != widget.allItemLabel)
        widget.currentValue,
    };
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filter(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredItems = List.from(widget.items);
      } else {
        _filteredItems = widget.items.where((item) {
          final lower = item.toLowerCase();
          // Matches if contains query or if starts with query (e.g. typing 'B' finds Baghdad, Baldia, etc.)
          return lower.contains(q);
        }).toList();

        // Sort items so those starting with the query appear first
        _filteredItems.sort((a, b) {
          final aStarts = a.toLowerCase().startsWith(q);
          final bStarts = b.toLowerCase().startsWith(q);
          if (aStarts && !bStarts) return -1;
          if (!aStarts && bStarts) return 1;
          return a.compareTo(b);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalMatches = _filteredItems.length;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 580),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: AppTheme.primaryGreen,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.filter_list, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Select ${widget.label}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            if (widget.onMultiSelected != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Single sector'),
                      selected: !_multiple,
                      onSelected: (_) => setState(() => _multiple = false),
                    ),
                    ChoiceChip(
                      label: const Text('Checkboxes'),
                      selected: _multiple,
                      onSelected: (_) => setState(() => _multiple = true),
                    ),
                  ],
                ),
              ),

            // Search input field with auto-focus
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Type to filter e.g. B, Waris, Colony...',
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 20,
                    color: AppTheme.primaryGreen,
                  ),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            _filter('');
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                onChanged: _filter,
              ),
            ),

            // Result count indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$totalMatches options found',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (_multiple ||
                      (widget.currentValue.isNotEmpty &&
                          !widget.currentValue.startsWith('All ')))
                    InkWell(
                      onTap: () {
                        if (_multiple) {
                          setState(() => _selected.clear());
                          return;
                        }
                        // Reset to first item (e.g. All Sectors)
                        if (widget.items.isNotEmpty) {
                          widget.onSelected(widget.items.first);
                        }
                      },
                      child: const Text(
                        'Reset Filter',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 12),

            // Filtered Items List with keyboard & mouse navigation
            Expanded(
              child: _filteredItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_off,
                            size: 36,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No matching ${widget.label.toLowerCase()}s found',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Scrollbar(
                      thumbVisibility: true,
                      child: ListView.builder(
                        itemCount: _filteredItems.length,
                        itemBuilder: (ctx, idx) {
                          final item = _filteredItems[idx];
                          final isSelected = item == widget.currentValue;

                          if (_multiple) {
                            final all = item == widget.allItemLabel;
                            final checked = all
                                ? _choices.isNotEmpty &&
                                      _selected.containsAll(_choices)
                                : _selected.contains(item);
                            return CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                item,
                                style: const TextStyle(fontSize: 13),
                              ),
                              value: checked,
                              onChanged: (checked) => setState(() {
                                if (all) {
                                  _selected = checked == true
                                      ? _choices.toSet()
                                      : {};
                                } else if (checked == true) {
                                  _selected.add(item);
                                } else {
                                  _selected.remove(item);
                                }
                              }),
                            );
                          }

                          return ListTile(
                            dense: true,
                            title: Text(
                              item,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected
                                    ? AppTheme.primaryGreen
                                    : Colors.black87,
                              ),
                            ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: AppTheme.primaryGreen,
                                  )
                                : null,
                            tileColor: isSelected
                                ? AppTheme.primaryGreen.withAlpha(20)
                                : null,
                            onTap: () => widget.onSelected(item),
                          );
                        },
                      ),
                    ),
            ),
            if (_multiple)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selected.isEmpty
                            ? 'All sectors (no selection)'
                            : '${_selected.length} sectors selected',
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () =>
                          widget.onMultiSelected!(Set.of(_selected)),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
