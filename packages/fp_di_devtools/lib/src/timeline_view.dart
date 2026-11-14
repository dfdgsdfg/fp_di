import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'phase.dart';

/// The transitions, the errors, and the slow mutations since the extension
/// connected, newest last.
class TimelineView extends StatelessWidget {
  const TimelineView({required this.controller, super.key});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.timeline;
    if (entries.isEmpty) {
      return const Center(
        key: Key('empty-timeline'),
        child: Text('No event since the extension connected.'),
      );
    }
    return ListView.builder(
      key: const Key('timeline'),
      itemCount: entries.length,
      itemBuilder: (context, index) =>
          _EntryTile(entry: entries[index], controller: controller),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

/// How many changed nodes one timeline entry lists.
const int _listedChanges = 20;

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.controller});

  final TimelineEntry entry;
  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final event = entry.event;
    final (icon, color, title, lines) = switch (event) {
      TransitionEvent() => (
        Icons.swap_horiz,
        Colors.blue.shade600,
        'transition · root ${event.root} · revision ${event.revision} · '
            '${event.changed.length + event.omitted} nodes changed',
        _changeLines(event),
      ),
      ErrorEvent() => (
        Icons.error_outline,
        Colors.red.shade600,
        'error · root ${event.root} · ${event.type}',
        [
          '${event.message}${event.truncated ? ' (cut)' : ''}',
          ?event.stackTrace,
        ],
      ),
      SlowMutationEvent() => (
        Icons.hourglass_bottom,
        Colors.amber.shade800,
        'slow mutation · root ${event.root} · ${event.operation} · '
            '${event.elapsedMs} ms',
        [
          if (event.running.isNotEmpty) 'running: ${event.running.join(', ')}',
          if (event.ignoringCancellation.isNotEmpty)
            'ignoring cancellation: '
                '${event.ignoringCancellation.join(', ')}',
          if (event.disposing.isNotEmpty)
            'disposing: ${event.disposing.join(', ')}',
          'queued: ${event.queued}',
        ],
      ),
    };
    return ListTile(
      key: Key('timeline-${entry.sequence}'),
      dense: true,
      leading: Icon(icon, color: color),
      title: Text('${_clock(entry.time)}  $title'),
      subtitle: lines.isEmpty ? null : Text(lines.join('\n'), style: monospace),
    );
  }

  List<String> _changeLines(TransitionEvent event) {
    final lines = <String>[];
    for (final change in event.changed.take(_listedChanges)) {
      final after = change.after;
      final before = change.before;
      final label = (after ?? before)?.label ?? 'node ${change.node}';
      final from = before?.phase ?? 'new';
      final to = after?.phase ?? 'removed';
      lines.add('$label: $from → $to');
    }
    final rest = event.changed.length - _listedChanges + event.omitted;
    if (rest > 0) lines.add('and $rest more');
    return lines;
  }
}
