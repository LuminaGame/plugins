import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The compact label + editor row the PCG panels use (shadcn only).
class PcgFieldRow extends StatelessWidget {
  final String label;
  final Widget child;
  final double labelWidth;

  const PcgFieldRow({super.key, required this.label, required this.child, this.labelWidth = 110});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: labelWidth, child: Text(label, style: const TextStyle(fontSize: 10)).muted()),
          const SizedBox(width: 6),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A number field that commits on Enter and on losing focus, so a Details
/// edit lands as one transaction (not one per keystroke).
class PcgNumberField extends StatefulWidget {
  final double value;
  final ValueChanged<double> onCommit;
  final int fractionDigits;
  final Key? fieldKey;

  const PcgNumberField({super.key, required this.value, required this.onCommit, this.fractionDigits = 1, this.fieldKey});

  @override
  State<PcgNumberField> createState() => _PcgNumberFieldState();
}

class _PcgNumberFieldState extends State<PcgNumberField> {
  late final TextEditingController _controller = TextEditingController(text: _format(widget.value));
  final FocusNode _focus = FocusNode();

  String _format(double v) => v == v.roundToDouble() && widget.fractionDigits <= 1 ? v.toStringAsFixed(0) : v.toStringAsFixed(widget.fractionDigits);

  @override
  void didUpdateWidget(covariant PcgNumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) _controller.text = _format(widget.value);
  }

  void _commit() {
    final parsed = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (parsed == null) {
      _controller.text = _format(widget.value);
      return;
    }
    if (parsed != widget.value) widget.onCommit(parsed);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (has) {
        if (!has) _commit();
      },
      child: TextField(
        key: widget.fieldKey,
        controller: _controller,
        focusNode: _focus,
        style: const TextStyle(fontSize: 10),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// Three [PcgNumberField]s for an X Y Z value.
class PcgVector3Field extends StatelessWidget {
  final List<double> value;
  final ValueChanged<List<double>> onCommit;

  const PcgVector3Field({super.key, required this.value, required this.onCommit});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: PcgNumberField(
              value: value.length > i ? value[i] : 0.0,
              onCommit: (v) {
                final next = List<double>.from(value.length >= 3 ? value : [0.0, 0.0, 0.0]);
                next[i] = v;
                onCommit(next);
              },
            ),
          ),
        ],
      ],
    );
  }
}
