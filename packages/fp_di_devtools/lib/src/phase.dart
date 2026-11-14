import 'package:flutter/material.dart';

/// The color group of a node phase or a scope phase.
Color phaseColor(String phase) => switch (phase) {
  'active' || 'initialized' => Colors.green.shade600,
  'activationFailed' || 'disposeFailed' => Colors.red.shade600,
  'disposed' => Colors.grey.shade600,
  'waiting' || 'inactive' || 'declared' => Colors.amber.shade800,
  _ => Colors.blue.shade600,
};

/// A small label that shows a phase in the color of its group.
class PhaseChip extends StatelessWidget {
  const PhaseChip(this.phase, {super.key});

  final String phase;

  @override
  Widget build(BuildContext context) {
    final color = phaseColor(phase);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(phase, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}

const TextStyle monospace = TextStyle(fontFamily: 'monospace', fontSize: 12);
