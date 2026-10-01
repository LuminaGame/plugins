import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'llm/sampling.dart';

/// "Advanced / Sampling": a provider's server type and sampling settings,
/// collapsed until opened. Empty fields are not sent (the server's defaults
/// apply); fields the server type does not take are not shown.
class SamplingSection extends StatefulWidget {
  const SamplingSection({
    super.key,
    required this.value,
    required this.defaults,
    required this.defaultsSource,
    required this.backend,
    required this.onChanged,
    this.onBackendChanged,
    this.onValidChanged,
    this.keyPrefix = 'miniai_sampling',
  });

  final SamplingSettings value;

  /// What "Reset to defaults" restores.
  final SamplingSettings defaults;

  /// Where [defaults] come from (shown under the fields).
  final String defaultsSource;
  final ServerBackend backend;
  final ValueChanged<SamplingSettings> onChanged;

  /// Null: the server type is fixed (the local llama-server).
  final ValueChanged<ServerBackend>? onBackendChanged;

  /// Whether every field holds an accepted value.
  final ValueChanged<bool>? onValidChanged;

  /// Widget keys: `<prefix>_toggle`, `<prefix>_backend`, `<prefix>_reset`,
  /// `<prefix>_<field>`.
  final String keyPrefix;

  @override
  State<SamplingSection> createState() => _SamplingSectionState();
}

class _SamplingSectionState extends State<SamplingSection> {
  bool _open = false;
  final Map<String, TextEditingController> _text = {};
  final Map<String, String> _errors = {};

  /// Set while the fields follow a new [SamplingSection.value].
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    for (final f in SamplingSettings.fields) {
      final c = TextEditingController(text: _format(widget.value[f.name]));
      c.addListener(() {
        if (!_syncing) _edited(f, c.text);
      });
      _text[f.name] = c;
    }
  }

  @override
  void didUpdateWidget(SamplingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset, new defaults for another model: show the new values.
    _syncing = true;
    for (final f in SamplingSettings.fields) {
      if (_errors.containsKey(f.name)) continue;
      final c = _text[f.name]!;
      if (_parse(c.text) != widget.value[f.name]) c.text = _format(widget.value[f.name]);
    }
    _syncing = false;
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _format(num? v) => v == null ? '' : '$v';

  static num? _parse(String text) {
    final t = text.trim();
    return t.isEmpty ? null : num.tryParse(t);
  }

  void _edited(SamplingField f, String text) {
    final t = text.trim();
    final v = _parse(t);
    final wasValid = _errors.isEmpty;
    if (t.isNotEmpty && (v == null || !f.accepts(v))) {
      _errors[f.name] = '${f.integer ? 'A whole number' : 'A number'} from ${f.min} to ${f.max}.';
    } else {
      _errors.remove(f.name);
      if (v != widget.value[f.name]) widget.onChanged(widget.value.withValue(f.name, f.integer && v != null ? v.round() : v));
    }
    if (wasValid != _errors.isEmpty) widget.onValidChanged?.call(_errors.isEmpty);
    if (mounted) setState(() {});
  }

  void _reset() {
    for (final f in SamplingSettings.fields) {
      _errors.remove(f.name);
    }
    widget.onValidChanged?.call(true);
    widget.onChanged(widget.defaults);
    // Fields that held an invalid value follow the defaults too.
    _syncing = true;
    for (final f in SamplingSettings.fields) {
      final c = _text[f.name]!;
      if (_parse(c.text) != widget.defaults[f.name] || c.text.trim().isNotEmpty && _parse(c.text) == null) c.text = _format(widget.defaults[f.name]);
    }
    _syncing = false;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 10);
    final p = widget.keyPrefix;
    final destructive = Theme.of(context).colorScheme.destructive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: GhostButton(
            key: ValueKey('${p}_toggle'),
            density: ButtonDensity.compact,
            leading: Icon(_open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14),
            onPressed: () => setState(() => _open = !_open),
            child: Text(
              'Advanced / Sampling${_errors.isEmpty ? '' : ' (check the values)'}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _errors.isEmpty ? null : destructive),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          const Text(
            'Sent with every request. Empty fields are left to the server. Lower temperature or a higher repeat / presence '
            'penalty helps a model that repeats itself.',
            style: small,
          ).muted(),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Server', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: widget.onBackendChanged == null
                    ? Text(widget.backend.label, key: ValueKey('${p}_backend'), style: const TextStyle(fontSize: 11))
                    : Select<ServerBackend>(
                        key: ValueKey('${p}_backend'),
                        value: widget.backend,
                        onChanged: (b) => b == null ? null : widget.onBackendChanged!(b),
                        itemBuilder: (_, b) => Text(b.label, style: const TextStyle(fontSize: 11)),
                        popup: SelectPopup(
                          items: SelectItemList(
                            children: [
                              for (final b in ServerBackend.values)
                                SelectItemButton(key: ValueKey('${p}_backend_${b.name}'), value: b, child: Text(b.label, style: const TextStyle(fontSize: 11))),
                            ],
                          ),
                        ).call,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text('Decides which fields the request carries. Found by Test connection; change it if the guess is wrong.', style: small)
              .muted(),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final f in SamplingSettings.fieldsFor(widget.backend))
                SizedBox(
                  width: 210,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(f.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      TextField(
                        key: ValueKey('${p}_${f.name}'),
                        controller: _text[f.name],
                        placeholder: Text(
                          widget.defaults[f.name] == null ? 'Server default' : 'Default ${_format(widget.defaults[f.name])}',
                          style: small,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (_errors[f.name] case final error?)
                        Text(error, key: ValueKey('${p}_${f.name}_error'), style: TextStyle(fontSize: 10, color: destructive))
                      else
                        Text(f.help, style: small).muted(),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Defaults: ${widget.defaultsSource}.', key: ValueKey('${p}_source'), style: small).muted()),
              const SizedBox(width: 8),
              OutlineButton(
                key: ValueKey('${p}_reset'),
                density: ButtonDensity.compact,
                onPressed: _reset,
                child: const Text('Reset to defaults', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
