// The repository-root `specs/spec.md` navigation index is excluded from topic
// validation.
import 'dart:io';

const _requiredFiles = <String>['requirements.md', 'spec.md', 'log.md'];
const _requirementSections = <String>[
  'Problem Statement',
  'Scope',
  'Out of Scope',
  'User Stories',
  'Use Cases',
  'Verification',
];
const _specSections = <String>['Overview', 'Verification'];

final _prefixPattern = RegExp(r'^[A-Z0-9]{2,4}-[A-Z0-9]{2,4}$');
const _idSource =
    r'(?:R-(?:US|UC)|V-(?:TEL|T|L|Q|A)|G|Q)-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3}';
// An optional `<a id="..."></a>` ID anchor before the ID of an entry.
const _anchorSource = r'(?:<a id="[^"]*"></a>)?';
final _definitionPattern = RegExp(
  '^(?:#{2,6}\\s+$_anchorSource|-\\s+$_anchorSource\\*\\*|$_anchorSource\\*\\*)'
  r'(R-(?:US|UC)-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3}'
  r'|V-(?:TEL|T|L|Q|A)-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3})',
  multiLine: true,
);
final _verificationPattern = RegExp(
  r'V-(?:TEL|T|L|Q|A)-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3}',
);
final _gapHeadingPattern = RegExp(
  r'^##\s+' + _anchorSource + r'(G-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3})\b',
  multiLine: true,
);
const _qIdSource = r'Q-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3}';
final _qEntryPattern = RegExp(
  r'^[-*]\s+' + _anchorSource + r'\*\*(' + _qIdSource + r')\*\*\s+—\s+\S',
);
final _tbdPattern = RegExp(r'\bTBD\b(?:\((' + _qIdSource + r')\))?');
final _blocksIdPattern = RegExp(
  r'\b(?:R-(?:US|UC)|V-(?:TEL|T|L|Q|A)|G)-[A-Z0-9]{2,4}-[A-Z0-9]{2,4}-\d{3}\b',
);
final _markdownLinkPattern = RegExp(r'\[([^\]]*)\]\(([^)]+)\)');
final _idReferencePattern = RegExp(r'(?<![A-Za-z0-9-])(' + _idSource + r')\b');
final _idAnchorPattern = RegExp(r'<a id="([^"]*)"></a>');
// A link fragment that is an ID heading slug, such as `#g-x-y-001--title`.
final _idSlugFragmentPattern = RegExp(
  r'^((?:r-(?:us|uc)|v-(?:tel|t|l|q|a)|g|q)-[a-z0-9]{2,4}-[a-z0-9]{2,4}-\d{3})-',
);
// The start of an ID entry: a heading, a bold bullet, a bold line, or a table
// row. Groups 1 to 4 are the anchor id of each form. Group 5 is the ID.
final _idEntryPattern = RegExp(
  r'^(?:#{2,6}\s+(?:<a id="([^"]*)"></a>)?[`*]*'
  r'|[-*]\s+(?:<a id="([^"]*)"></a>)?\*\*'
  r'|(?:<a id="([^"]*)"></a>)?\*\*'
  r'|\|\s*(?:<a id="([^"]*)"></a>)?[`*]*)'
  '($_idSource)'
  r'([`*]*\s*\|)?',
);
final _dynamicMermaidPattern = RegExp(
  r'```mermaid\s+(?:sequenceDiagram|stateDiagram(?:-v2)?|flowchart|graph\s|journey\b|gantt\b)',
  caseSensitive: false,
);

void main(List<String> arguments) {
  final repositoryRoot = _findRepositoryRoot();
  final finalMode = arguments.contains('--final');
  final requested = arguments
      .where((value) => !value.startsWith('--'))
      .toList();
  final selectedTopics = _discoverTopics(
    repositoryRoot,
    requested.isEmpty ? <String>['specs'] : requested,
  );

  if (selectedTopics.isEmpty) {
    stderr.writeln('ERROR: no spec topics found for ${requested.join(', ')}');
    exitCode = 2;
    return;
  }

  final allTopics = _discoverTopics(repositoryRoot, <String>['specs']);
  final errors = <String>[];
  final warnings = <String>[];
  final prefixOwners = <String, String>{};
  final idOwners = <String, String>{};
  final topicPrefixes = <String, Set<String>>{};
  final questionOwners = <String, String>{};
  final topicQuestions = <String, Set<String>>{};
  final gapOwners = <String, String>{};
  var gapCount = 0;

  for (final topic in allTopics) {
    final requirements = File('${topic.path}/requirements.md');
    if (!requirements.existsSync()) continue;
    final metadata = _frontmatter(
      requirements,
      errors,
      expectedType: 'requirement',
    );
    final prefix = metadata['id_prefix'];
    final relativeTopic = _relative(repositoryRoot, topic.path);
    if (prefix == null || !_prefixPattern.hasMatch(prefix)) {
      errors.add(
        '$relativeTopic/requirements.md: invalid or missing id_prefix',
      );
      continue;
    }
    final legacyPrefixes = _legacyPrefixes(metadata, relativeTopic, errors);
    final declaredPrefixes = <String>{prefix, ...legacyPrefixes};
    for (final declaredPrefix in declaredPrefixes) {
      final previousPrefixOwner = prefixOwners[declaredPrefix];
      if (previousPrefixOwner != null && previousPrefixOwner != relativeTopic) {
        errors.add(
          'id_prefix $declaredPrefix is shared by '
          '$previousPrefixOwner and $relativeTopic',
        );
      } else {
        prefixOwners[declaredPrefix] = relativeTopic;
      }
    }

    topicPrefixes[relativeTopic] = declaredPrefixes;

    final gapFile = File('${topic.path}/gap.md');
    if (gapFile.existsSync()) {
      for (final match in _gapHeadingPattern.allMatches(
        gapFile.readAsStringSync(),
      )) {
        gapOwners[match.group(1)!] = relativeTopic;
      }
    }

    final text = requirements.readAsStringSync();
    for (final match in _definitionPattern.allMatches(text)) {
      final id = match.group(1)!;
      if (!declaredPrefixes.any((value) => id.contains('-$value-'))) {
        errors.add(
          '$relativeTopic/requirements.md: $id does not use a declared '
          'id_prefix',
        );
      }
      final previousIdOwner = idOwners[id];
      if (previousIdOwner != null && previousIdOwner != relativeTopic) {
        errors.add(
          '$id is defined by both $previousIdOwner and $relativeTopic',
        );
      } else {
        idOwners[id] = relativeTopic;
      }
    }
  }

  for (final topic in allTopics) {
    final relativeTopic = _relative(repositoryRoot, topic.path);
    final declaredPrefixes = topicPrefixes[relativeTopic];
    for (final name in const <String>['requirements.md', 'spec.md']) {
      final file = File('${topic.path}/$name');
      if (!file.existsSync()) continue;
      final label = '$relativeTopic/$name';
      for (final question in _openQuestionsOf(file.readAsStringSync())) {
        final id = question.id;
        if (id == null) continue;
        if (declaredPrefixes != null &&
            !declaredPrefixes.any((value) => id.startsWith('Q-$value-'))) {
          errors.add('$label: $id does not use a declared id_prefix');
        }
        final previousOwner = questionOwners[id];
        if (previousOwner != null) {
          errors.add('$id is defined by both $previousOwner and $label');
        } else {
          questionOwners[id] = label;
        }
        topicQuestions.putIfAbsent(relativeTopic, () => <String>{}).add(id);
      }
    }
  }

  final currentIds = <String>{
    ...idOwners.keys,
    ...gapOwners.keys,
    ...questionOwners.keys,
  };

  for (final topic in selectedTopics) {
    final relativeTopic = _relative(repositoryRoot, topic.path);
    for (final name in _requiredFiles) {
      if (!File('${topic.path}/$name').existsSync()) {
        errors.add('$relativeTopic: missing required $name');
      }
    }
    if (_requiredFiles.any(
      (name) => !File('${topic.path}/$name').existsSync(),
    )) {
      continue;
    }

    final requirements = File('${topic.path}/requirements.md');
    final spec = File('${topic.path}/spec.md');
    final log = File('${topic.path}/log.md');
    final requirementMetadata = _frontmatter(
      requirements,
      errors,
      expectedType: 'requirement',
    );
    _frontmatter(spec, errors, expectedType: 'spec');
    _frontmatter(log, errors, expectedType: 'log');

    final requirementText = requirements.readAsStringSync();
    final specText = spec.readAsStringSync();
    for (final section in _requirementSections) {
      if (!_hasH2(requirementText, section)) {
        warnings.add('$relativeTopic/requirements.md: missing ## $section');
      }
    }
    for (final section in _specSections) {
      if (!_hasH2(specText, section)) {
        warnings.add('$relativeTopic/spec.md: missing ## $section');
      }
    }
    if (!_dynamicMermaidPattern.hasMatch(specText)) {
      warnings.add('$relativeTopic/spec.md: missing a dynamic Mermaid diagram');
    }

    final prefix = requirementMetadata['id_prefix'];
    final declaredPrefixes = <String>{
      if (prefix != null && _prefixPattern.hasMatch(prefix)) prefix,
      ...?_parseLegacyPrefixes(requirementMetadata['legacy_id_prefixes']),
    };
    final verificationIds = _definitionPattern
        .allMatches(requirementText)
        .map((match) => match.group(1)!)
        .where(_verificationPattern.hasMatch)
        .toSet();
    for (final id in verificationIds) {
      if (!specText.contains(id)) {
        warnings.add('$relativeTopic/spec.md: verification $id is not mapped');
      }
    }

    final gap = File('${topic.path}/gap.md');
    final blockableIds = <String>{
      ..._definitionPattern
          .allMatches(requirementText)
          .map((match) => match.group(1)!),
      if (gap.existsSync())
        ..._gapHeadingPattern
            .allMatches(gap.readAsStringSync())
            .map((match) => match.group(1)!),
    };
    _validateOpenQuestions(
      '$relativeTopic/requirements.md',
      requirementText,
      blockableIds,
      errors,
      warnings,
    );
    _validateOpenQuestions(
      '$relativeTopic/spec.md',
      specText,
      blockableIds,
      errors,
      warnings,
    );
    final definedQuestions = topicQuestions[relativeTopic] ?? <String>{};
    _validateTbd(
      '$relativeTopic/requirements.md',
      requirementText,
      definedQuestions,
      errors,
    );
    _validateTbd('$relativeTopic/spec.md', specText, definedQuestions, errors);

    for (final file in <File>[requirements, spec, log]) {
      _validateLinks(repositoryRoot, file, errors);
    }
    _validateIdAnchors(
      '$relativeTopic/requirements.md',
      requirementText,
      const <String>{'R', 'V', 'Q'},
      errors,
    );
    _validateIdAnchors(
      '$relativeTopic/spec.md',
      specText,
      const <String>{'V', 'Q'},
      errors,
      tableKinds: const <String>{'V'},
    );
    final currentTruth = <String, String>{
      '$relativeTopic/requirements.md': requirementText,
      '$relativeTopic/spec.md': specText,
      if (gap.existsSync()) '$relativeTopic/gap.md': gap.readAsStringSync(),
    };
    for (final entry in currentTruth.entries) {
      _validateCrossTopicReferences(
        entry.key,
        entry.value,
        declaredPrefixes,
        currentIds,
        errors,
      );
    }

    if (gap.existsSync()) {
      _validateIdAnchors(
        '$relativeTopic/gap.md',
        gap.readAsStringSync(),
        const <String>{'G'},
        errors,
      );
      gapCount += _validateGap(
        repositoryRoot,
        gap,
        prefix,
        errors,
        allowedPrefixes: declaredPrefixes,
      );
    }
  }

  for (final warning in warnings) {
    stderr.writeln('WARNING: $warning');
  }
  for (final error in errors) {
    stderr.writeln('ERROR: $error');
  }

  if (errors.isNotEmpty || (finalMode && warnings.isNotEmpty)) {
    stderr.writeln(
      'FAILED topics=${selectedTopics.length} errors=${errors.length} '
      'warnings=${warnings.length}${finalMode ? ' mode=final' : ''}',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'OK topics=${selectedTopics.length} prefixes=${prefixOwners.length} '
    'ids=${idOwners.length} gaps=$gapCount '
    'questions=${questionOwners.length} warnings=${warnings.length}',
  );
}

Directory _findRepositoryRoot() {
  var directory = File.fromUri(Platform.script).parent;
  while (directory.parent.path != directory.path) {
    if (Directory('${directory.path}/specs').existsSync() &&
        Directory('${directory.path}/agents').existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Could not find repository root from ${Platform.script}');
}

List<Directory> _discoverTopics(Directory root, List<String> requested) {
  final topics = <String, Directory>{};
  for (final value in requested) {
    final candidate = value.startsWith('/') ? value : '${root.path}/$value';
    final type = FileSystemEntity.typeSync(candidate);
    if (type == FileSystemEntityType.file) {
      final file = File(candidate);
      if (_isTopicArtifact(file.path, root)) {
        topics[file.parent.path] = file.parent;
      }
      continue;
    }
    if (type != FileSystemEntityType.directory) continue;
    final directory = Directory(candidate);
    if (_containsTopicArtifact(directory, root)) {
      topics[directory.path] = directory;
    }
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && _isTopicArtifact(entity.path, root)) {
        topics[entity.parent.path] = entity.parent;
      }
    }
  }
  final result = topics.values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return result;
}

bool _containsTopicArtifact(Directory directory, Directory root) =>
    _requiredFiles.any(
      (name) =>
          File('${directory.path}/$name').existsSync() &&
          !_isRepositoryIndexSpec('${directory.path}/$name', root),
    ) ||
    File('${directory.path}/gap.md').existsSync();

bool _isTopicArtifact(String path, Directory root) {
  final name = path.split(Platform.pathSeparator).last;
  if (_isRepositoryIndexSpec(path, root)) return false;
  return _requiredFiles.contains(name) || name == 'gap.md';
}

// `specs/spec.md` is a repository navigation/index document. Topic validation
// accepts domain topics and optional subdomains. The index is not a
// partial topic.
bool _isRepositoryIndexSpec(String path, Directory root) {
  final index = File('${root.path}/specs/spec.md').absolute.path;
  final file = File(path);
  if (file.absolute.path != index || !file.existsSync()) return false;
  final text = file.readAsStringSync();
  if (!text.startsWith('---\n')) return false;
  final end = text.indexOf('\n---\n', 4);
  return end >= 0 &&
      RegExp(
        r'^type:\s*["\x27]?index["\x27]?\s*$',
        multiLine: true,
      ).hasMatch(text.substring(4, end));
}

Map<String, String> _frontmatter(
  File file,
  List<String> errors, {
  required String expectedType,
}) {
  final text = file.readAsStringSync();
  final path = file.path;
  final metadata = <String, String>{};
  if (!text.startsWith('---\n')) {
    errors.add('$path: frontmatter must start at byte 0');
    return metadata;
  }
  final end = text.indexOf('\n---\n', 4);
  if (end < 0) {
    errors.add('$path: frontmatter is not closed');
    return metadata;
  }
  for (final line in text.substring(4, end).split('\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    var value = line.substring(separator + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    metadata[line.substring(0, separator).trim()] = value;
  }
  if (metadata['type'] != expectedType) {
    errors.add('$path: expected type: $expectedType');
  }
  final h1 = RegExp(
    r'^#\s+(.+)$',
    multiLine: true,
  ).firstMatch(text)?.group(1)?.trim();
  if (metadata['title'] == null || metadata['title'] != h1) {
    errors.add('$path: frontmatter title must match H1');
  }
  return metadata;
}

List<String> _legacyPrefixes(
  Map<String, String> metadata,
  String relativeTopic,
  List<String> errors,
) {
  final raw = metadata['legacy_id_prefixes'];
  if (raw == null) return <String>[];
  final parsed = _parseLegacyPrefixes(raw);
  if (parsed == null) {
    errors.add(
      '$relativeTopic/requirements.md: legacy_id_prefixes must be a list '
      'of unique valid prefixes',
    );
    return <String>[];
  }
  final seen = <String>{
    if (metadata['id_prefix'] != null) metadata['id_prefix']!,
  };
  for (final prefix in parsed) {
    if (!_prefixPattern.hasMatch(prefix)) {
      errors.add(
        '$relativeTopic/requirements.md: invalid legacy id_prefix $prefix',
      );
    }
    if (!seen.add(prefix)) {
      errors.add(
        '$relativeTopic/requirements.md: duplicate legacy id_prefix $prefix',
      );
    }
  }
  return parsed;
}

List<String>? _parseLegacyPrefixes(String? raw) {
  if (raw == null) return <String>[];
  final value = raw.trim();
  if (value.length < 2 || !value.startsWith('[') || !value.endsWith(']')) {
    return null;
  }
  final body = value.substring(1, value.length - 1).trim();
  if (body.isEmpty) return <String>[];
  final entries = body.split(',').map((entry) => entry.trim()).toList();
  final prefixes = <String>[];
  for (final entry in entries) {
    if (entry.isEmpty) return null;
    if (entry.length >= 2 &&
        ((entry.startsWith('"') && entry.endsWith('"')) ||
            (entry.startsWith("'") && entry.endsWith("'")))) {
      prefixes.add(entry.substring(1, entry.length - 1));
    } else if (entry.contains('"') || entry.contains("'")) {
      return null;
    } else {
      prefixes.add(entry);
    }
  }
  return prefixes;
}

bool _hasH2(String text, String heading) => RegExp(
  '^## ${RegExp.escape(heading)}\\s*\$',
  multiLine: true,
).hasMatch(text);

/// One top-level entry of a `## Open Questions` section.
class _OpenQuestion {
  _OpenQuestion(this.line, String first) : lines = <String>[first];

  /// 1-based line number of the entry.
  final int line;
  final List<String> lines;

  /// The Q-ID when the entry has the shape `- **Q-ID** — question`.
  String? id;

  /// True when the entry starts with `**Q-` but has a malformed shape.
  bool malformed = false;

  /// Returns the text of each sub-bullet, keyed by its label before `:`.
  Map<String, String> get fields {
    final result = <String, String>{};
    String? label;
    for (final line in lines.skip(1)) {
      final sub = RegExp(r'^\s+[-*]\s+([^:]+):\s*(.*)$').firstMatch(line);
      if (sub != null) {
        label = sub.group(1)!.trim();
        result[label] = sub.group(2)!.trim();
      } else if (label != null && line.trim().isNotEmpty) {
        result[label] = '${result[label]} ${line.trim()}';
      }
    }
    return result;
  }
}

/// Returns the lines of [text] with fenced code blocks blanked, so that line
/// numbers stay stable.
List<String> _linesWithoutFences(String text) {
  var inFence = false;
  return text.split('\n').map((line) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      return '';
    }
    return inFence ? '' : line;
  }).toList();
}

/// Parses the top-level entries of `## Open Questions`. A section that holds
/// only `None.` has no entries.
List<_OpenQuestion> _openQuestionsOf(String text) {
  final lines = _linesWithoutFences(text);
  final start = lines.indexWhere(
    (line) => RegExp(r'^## Open Questions\s*$').hasMatch(line),
  );
  if (start < 0) return const <_OpenQuestion>[];
  final entries = <_OpenQuestion>[];
  _OpenQuestion? current;
  for (var index = start + 1; index < lines.length; index += 1) {
    final line = lines[index];
    if (RegExp(r'^#{1,2}\s').hasMatch(line)) break;
    if (RegExp(r'^(?:[-*]|\d+\.)\s+\S').hasMatch(line)) {
      current = _OpenQuestion(index + 1, line);
      entries.add(current);
      final match = _qEntryPattern.firstMatch(line);
      if (match != null) {
        current.id = match.group(1);
      } else if (line.contains('**Q-')) {
        current.malformed = true;
      }
    } else if (current != null) {
      current.lines.add(line);
    }
  }
  return entries
      .where(
        (entry) =>
            entry.id != null ||
            entry.malformed ||
            !RegExp(r'^[-*]\s+None\.\s*$').hasMatch(entry.lines.first),
      )
      .toList();
}

void _validateOpenQuestions(
  String label,
  String text,
  Set<String> blockableIds,
  List<String> errors,
  List<String> warnings,
) {
  for (final question in _openQuestionsOf(text)) {
    final where = '$label:${question.line}';
    if (question.malformed) {
      errors.add(
        '$where: open question must use "- **Q-ID** — question" '
        'with a valid Q-ID',
      );
      continue;
    }
    final id = question.id;
    if (id == null) {
      warnings.add('$where: legacy open question without Q-ID');
      continue;
    }
    final fields = question.fields;
    if ((fields['Resolve when'] ?? '').isEmpty) {
      errors.add('$where: $id is missing Resolve when:');
    }
    for (final blocked in _blocksIdPattern.allMatches(fields['Blocks'] ?? '')) {
      if (!blockableIds.contains(blocked.group(0))) {
        errors.add('$where: $id blocks unknown ${blocked.group(0)}');
      }
    }
  }
}

void _validateTbd(
  String label,
  String text,
  Set<String> definedQuestions,
  List<String> errors,
) {
  final lines = _linesWithoutFences(text);
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index].replaceAll(RegExp(r'(`+).+?\1'), '');
    for (final match in _tbdPattern.allMatches(line)) {
      final id = match.group(1);
      if (id == null) {
        errors.add('$label:${index + 1}: bare TBD needs a Q-ID: TBD(Q-...)');
      } else if (!definedQuestions.contains(id)) {
        errors.add('$label:${index + 1}: TBD($id) has no Open Questions entry');
      }
    }
  }
}

void _validateLinks(Directory root, File file, List<String> errors) {
  final text = file.readAsStringSync();
  for (final match in _markdownLinkPattern.allMatches(text)) {
    final linkText = match.group(1)!.replaceAll(RegExp(r'[`*]'), '').trim();
    var target = match.group(2)!.trim();
    if (target.startsWith('<') && target.endsWith('>')) {
      target = target.substring(1, target.length - 1);
    }
    final doubleQuoteTitle = target.indexOf(' "');
    final singleQuoteTitle = target.indexOf(" '");
    final titleSeparators = <int>[
      if (doubleQuoteTitle >= 0) doubleQuoteTitle,
      if (singleQuoteTitle >= 0) singleQuoteTitle,
    ];
    if (titleSeparators.isNotEmpty) {
      titleSeparators.sort();
      target = target.substring(0, titleSeparators.first);
    }
    if (_validateIdLink(root, file, linkText, target, errors)) continue;
    if (target.isEmpty ||
        target.startsWith('#') ||
        target.contains('://') ||
        target.startsWith('mailto:')) {
      continue;
    }
    final pathPart = Uri.decodeComponent(target.split('#').first);
    if (pathPart.isEmpty) continue;
    final resolved = pathPart.startsWith('/')
        ? pathPart
        : '${file.parent.path}/$pathPart';
    if (FileSystemEntity.typeSync(resolved) == FileSystemEntityType.notFound) {
      errors.add('${_relative(root, file.path)}: broken relative link $target');
    }
  }
}

final _fullIdPattern = RegExp('^$_idSource\$');

/// Checks a link that names an ID or targets an ID anchor. Returns true when
/// the link needs no further check.
bool _validateIdLink(
  Directory root,
  File file,
  String linkText,
  String target,
  List<String> errors,
) {
  if (target.contains('://') || target.startsWith('mailto:')) return false;
  final relative = _relative(root, file.path);
  final hash = target.indexOf('#');
  final fragment = hash < 0 ? '' : _decode(target.substring(hash + 1));
  final slug = _idSlugFragmentPattern.firstMatch(fragment);
  if (slug != null) {
    errors.add(
      '$relative: link the ID anchor #${slug.group(1)}, '
      'not the heading slug in $target',
    );
    return true;
  }
  final path = hash < 0 ? target : _decode(target.substring(0, hash));
  if (_fullIdPattern.hasMatch(linkText) &&
      (path.isEmpty || path.endsWith('.md')) &&
      fragment != linkText.toLowerCase()) {
    errors.add(
      '$relative: link $linkText to #${linkText.toLowerCase()}, not $target',
    );
    return true;
  }
  if (_fullIdPattern.hasMatch(fragment.toUpperCase()) &&
      (path.isEmpty || path.endsWith('.md'))) {
    final resolved = path.isEmpty
        ? file
        : File(path.startsWith('/') ? path : '${file.parent.path}/$path');
    // A missing target file is reported as a broken relative link instead.
    if (resolved.existsSync() && !_idAnchorsOf(resolved).contains(fragment)) {
      errors.add('$relative: broken anchor $target');
      return true;
    }
  }
  return false;
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}

final _idAnchorCache = <String, Set<String>>{};

/// Returns the `<a id="...">` anchors of [file], outside fenced code blocks.
Set<String> _idAnchorsOf(File file) =>
    _idAnchorCache.putIfAbsent(file.path, () {
      final anchors = <String>{};
      for (final line in _linesWithoutFences(file.readAsStringSync())) {
        for (final match in _idAnchorPattern.allMatches(line)) {
          anchors.add(match.group(1)!.toLowerCase());
        }
      }
      return anchors;
    });

/// Checks the `<a id="..."></a>` anchors of the ID entries in [text]. Only the
/// ID kinds in [kinds] are entries of this file. A table row is an entry only
/// when [tableKinds] holds its kind.
void _validateIdAnchors(
  String label,
  String text,
  Set<String> kinds,
  List<String> errors, {
  Set<String> tableKinds = const <String>{},
}) {
  final lines = _linesWithoutFences(text);
  final entries = <String>{};
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    final where = '$label:${index + 1}';
    final match = _idEntryPattern.firstMatch(line);
    var entryAnchor = -1;
    if (match != null) {
      final id = match.group(5)!;
      final kind = id.substring(0, 1);
      final isTable = line.startsWith('|');
      final isEntry = isTable
          ? tableKinds.contains(kind) && match.group(6) != null
          : kinds.contains(kind);
      if (isEntry) {
        final anchor =
            match.group(1) ??
            match.group(2) ??
            match.group(3) ??
            match.group(4);
        final expected = id.toLowerCase();
        if (anchor != null) entryAnchor = line.indexOf('<a id=');
        if (entries.add(id)) {
          if (anchor == null) {
            errors.add('$where: $id needs <a id="$expected"></a>');
          } else if (anchor != expected) {
            errors.add('$where: anchor "$anchor" does not match $id');
          }
        } else if (anchor != null) {
          errors.add('$where: duplicate anchor for $id');
        }
      }
    }
    for (final anchor in _idAnchorPattern.allMatches(line)) {
      if (anchor.start == entryAnchor) continue;
      final value = anchor.group(1)!;
      if (_fullIdPattern.hasMatch(value.toUpperCase())) {
        errors.add('$where: ID anchor "$value" is not on an ID entry');
      }
    }
  }
}

/// Reports a plain reference to a current ID of another topic. Such a
/// reference must be a link to the ID anchor.
void _validateCrossTopicReferences(
  String label,
  String text,
  Set<String>? prefixes,
  Set<String> currentIds,
  List<String> errors,
) {
  if (prefixes == null) return;
  final lines = _linesWithoutFences(text);
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index]
        .replaceAll(_markdownLinkPattern, '')
        .replaceAll(_idAnchorPattern, '');
    for (final match in _idReferencePattern.allMatches(line)) {
      final id = match.group(1)!;
      if (prefixes.any((value) => id.contains('-$value-')) ||
          !currentIds.contains(id)) {
        continue;
      }
      errors.add(
        '$label:${index + 1}: $id belongs to another topic; '
        'link it to its ID anchor',
      );
    }
  }
}

int _validateGap(
  Directory root,
  File gap,
  String? prefix,
  List<String> errors, {
  Set<String>? allowedPrefixes,
}) {
  _frontmatter(gap, errors, expectedType: 'gap');
  _validateLinks(root, gap, errors);
  final text = gap.readAsStringSync();
  final matches = _gapHeadingPattern.allMatches(text).toList();
  final relative = _relative(root, gap.path);
  if (matches.isEmpty) {
    errors.add('$relative: gap.md must contain at least one G-* entry');
    return 0;
  }
  const fields = <String>[
    'Spec',
    'Implementation',
    'Impact',
    'Resolution condition',
    'Evidence',
  ];
  for (var index = 0; index < matches.length; index += 1) {
    final id = matches[index].group(1)!;
    final prefixes =
        allowedPrefixes ??
        (prefix == null ? const <String>{} : <String>{prefix});
    if (prefix != null && !prefixes.any((value) => id.contains('-$value-'))) {
      errors.add('$relative: $id does not use id_prefix $prefix');
    }
    final end = index + 1 < matches.length
        ? matches[index + 1].start
        : text.length;
    final body = text.substring(matches[index].end, end);
    for (final field in fields) {
      if (!RegExp(
        '^- ${RegExp.escape(field)}:',
        multiLine: true,
      ).hasMatch(body)) {
        errors.add('$relative: $id is missing $field');
      }
    }
    if (!RegExp(r'\]\((?:[^)]*/)?spec\.md#[^)]+\)').hasMatch(body)) {
      errors.add('$relative: $id must link an exact canonical spec anchor');
    }
  }
  return matches.length;
}

String _relative(Directory root, String path) {
  final prefix = '${root.path}${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
