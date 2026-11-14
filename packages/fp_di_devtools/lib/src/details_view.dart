import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'phase.dart';

/// The details of the selected node: its reads with their publishers, its
/// readers, its failure, and the cause of an unavailable key. A publisher, a
/// reader, or a step of the cause selects its node.
class DetailsView extends StatelessWidget {
  const DetailsView({required this.controller, super.key});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final node = controller.node;
    if (node == null) {
      return const Center(
        key: Key('no-selected-node'),
        child: Text('Select a node.'),
      );
    }
    final details = controller.details;
    final heading = Theme.of(context).textTheme.titleSmall;
    return ListView(
      key: const Key('details'),
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                node.label,
                key: const Key('details-label'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: 8),
            PhaseChip(node.phase),
          ],
        ),
        const SizedBox(height: 4),
        SelectableText(node.key ?? '(contribution)', style: monospace),
        Text('node ${node.id} · ${node.commits} commits'),
        if (node.origin != null) Text('origin: ${node.origin}'),
        if (controller.showValues) ...[
          const SizedBox(height: 8),
          Text('Value', style: heading),
          Text(
            _value(details?.value ?? node.value, details?.truncated ?? false),
            key: const Key('details-value'),
            style: monospace,
          ),
        ],
        if (node.missing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Missing', style: heading),
          for (final key in node.missing) Text(key, style: monospace),
        ],
        if (node.failure != null || details?.failureCause != null) ...[
          const SizedBox(height: 8),
          Text('Failure', style: heading),
          if (node.failure case final failure?)
            Text(
              '${failure.type}: ${failure.message}'
              '${failure.truncated ? ' (cut)' : ''}',
              key: const Key('failure-summary'),
            ),
          if (details?.failureCause case final cause?)
            Text('cause: $cause', key: const Key('failure-cause')),
          if (details?.stackTrace case final stack?)
            SelectableText(
              stack,
              key: const Key('failure-stack'),
              style: monospace,
            ),
        ],
        const SizedBox(height: 8),
        Text('Reads', style: heading),
        if (details == null)
          const Text('Loading.')
        else if (details.reads.isEmpty)
          const Text('none', key: Key('no-reads'))
        else
          for (var i = 0; i < details.reads.length; i++)
            _ReadRow(
              key: ValueKey('read-$i'),
              read: details.reads[i],
              controller: controller,
            ),
        const SizedBox(height: 8),
        Text('Readers', style: heading),
        if (details == null)
          const Text('Loading.')
        else if (details.readers.isEmpty)
          const Text('none', key: Key('no-readers'))
        else
          Wrap(
            spacing: 6,
            children: [
              for (final id in details.readers)
                ActionChip(
                  key: Key('reader-$id'),
                  label: Text(controller.nodeWithId(id)?.label ?? 'node $id'),
                  onPressed: () => controller.selectNode(id),
                ),
            ],
          ),
        if (details?.cause case final steps?) ...[
          const SizedBox(height: 8),
          Text('Cause of the unavailable key', style: heading),
          for (var i = 0; i < steps.length; i++)
            _CauseRow(
              key: ValueKey('cause-$i'),
              step: steps[i],
              controller: controller,
            ),
        ],
      ],
    );
  }

  static String _value(String? value, bool truncated) => value == null
      ? '(no value)'
      : truncated
      ? '$value (cut)'
      : value;
}

class _ReadRow extends StatelessWidget {
  const _ReadRow({
    required this.read,
    required this.controller,
    this.indent = 0,
    super.key,
  });

  final ReadInfo read;
  final InspectorController controller;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final publisher = read.publisher;
    final target = publisher == null
        ? null
        : controller.nodeWithId(publisher)?.label ?? 'node $publisher';
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              Text(read.kind, style: const TextStyle(color: Colors.grey)),
              SelectableText(read.key, style: monospace),
              if (!read.resolves)
                Text(
                  'unresolved',
                  style: TextStyle(color: Colors.red.shade600),
                ),
              if (publisher != null)
                TextButton(
                  key: Key('publisher-$publisher'),
                  onPressed: () => controller.selectNode(publisher),
                  child: Text('→ $target'),
                ),
            ],
          ),
          for (var i = 0; i < read.members.length; i++)
            _ReadRow(
              key: ValueKey('member-$i'),
              read: read.members[i],
              controller: controller,
              indent: 16,
            ),
        ],
      ),
    );
  }
}

class _CauseRow extends StatelessWidget {
  const _CauseRow({required this.step, required this.controller, super.key});

  final CauseStep step;
  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final label =
        controller.nodeWithId(step.node)?.label ?? 'node ${step.node}';
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        TextButton(
          key: Key('cause-node-${step.node}'),
          onPressed: () => controller.selectNode(step.node),
          child: Text(label),
        ),
        PhaseChip(step.phase),
        if (step.waitsFor.isNotEmpty)
          Text('waits for ${step.waitsFor.join(', ')}', style: monospace),
      ],
    );
  }
}
