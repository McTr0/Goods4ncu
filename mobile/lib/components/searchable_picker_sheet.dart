import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One option row for [showSearchablePickerSheet].
class PickerOption<T> {
  const PickerOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.keywords = const [],
  });

  final T value;
  final String label;
  final String? subtitle;

  /// Extra lowercase tokens matched by the search query.
  final List<String> keywords;
}

/// Bottom sheet with a search field over [options]; supports single- and
/// multi-select. Used for post categories and tags so both stay extensible
/// without new UI per item.
Future<List<T>?> showSearchablePickerSheet<T>({
  required BuildContext context,
  required String title,
  required List<PickerOption<T>> options,
  List<T> initiallySelected = const [],
  bool multiSelect = false,
}) {
  return showModalBottomSheet<List<T>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _SearchablePickerSheet<T>(
      title: title,
      options: options,
      initiallySelected: initiallySelected,
      multiSelect: multiSelect,
    ),
  );
}

class _SearchablePickerSheet<T> extends StatefulWidget {
  const _SearchablePickerSheet({
    required this.title,
    required this.options,
    required this.initiallySelected,
    required this.multiSelect,
  });

  final String title;
  final List<PickerOption<T>> options;
  final List<T> initiallySelected;
  final bool multiSelect;

  @override
  State<_SearchablePickerSheet<T>> createState() =>
      _SearchablePickerSheetState<T>();
}

class _SearchablePickerSheetState<T> extends State<_SearchablePickerSheet<T>> {
  String _query = '';
  late final Set<T> _selected = {...widget.initiallySelected};

  List<PickerOption<T>> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.options;
    return widget.options
        .where(
          (option) =>
              option.label.toLowerCase().contains(query) ||
              option.value.toString().toLowerCase().contains(query) ||
              option.keywords.any((keyword) => keyword.contains(query)),
        )
        .toList(growable: false);
  }

  void _finish() =>
      Navigator.pop<List<T>>(context, _selected.toList(growable: false));

  @override
  Widget build(BuildContext context) {
    final l = Directionality.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                textDirection: l,
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (widget.multiSelect)
                    TextButton(
                      key: const Key('picker-confirm'),
                      onPressed: () =>
                          Navigator.pop<List<T>>(context, _selected.toList()),
                      child: Text(
                        '确定${_selected.isEmpty ? '' : ' (${_selected.length})'}',
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('picker-search'),
                autofocus: false,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: '搜索…',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(child: Text('没有匹配的选项'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final option = _filtered[index];
                        final isSelected = _selected.contains(option.value);
                        return ListTile(
                          key: ValueKey('picker-${option.value}'),
                          title: Text(option.label),
                          subtitle: option.subtitle == null
                              ? null
                              : Text(option.subtitle!),
                          trailing: isSelected
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: AppTheme.primary,
                                )
                              : null,
                          onTap: () {
                            if (!widget.multiSelect) {
                              _selected
                                ..clear()
                                ..add(option.value);
                              _finish();
                              return;
                            }
                            setState(() {
                              isSelected
                                  ? _selected.remove(option.value)
                                  : _selected.add(option.value);
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
