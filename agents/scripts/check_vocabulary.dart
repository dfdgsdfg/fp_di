// Checks the words of every public identifier against the ontology vocabulary.
//
// Usage: dart run agents/scripts/check_vocabulary.dart [options]
//
//   (no option)    Check the public API words against `ontology/*.yml`.
//   --list         Print the public API inventory, one entry per line:
//                  `package  kind  Owner.member  [words]  path`.
//   --json         With `--list`, print the inventory as JSON.
//   --words        Print the distinct words: `word  count  first 3 uses`.
//   --prose        Also scan Markdown prose for avoided words, without decision
//                  logs and research notes.
//   --all-uses     Print every use of a word, not the first five.
//   -h, --help     Print this help.
//
// Exit codes: 0 when the check passes, 1 when it reports an unknown word, an
// avoided word, a vocabulary conflict, or a stale binding, and 2 when the
// script cannot run (for example `flutter pub get` is missing).
//
// The public API is the export namespace of the public libraries of `fp_di`
// and `fp_di_flutter`, resolved with `package:analyzer`. Run
// `flutter pub get` first: the workspace contains a Flutter package.
//
// Each node under `nodes:` of an `ontology/*.yml` file MAY declare:
//   identifiers: lowercase words that public identifiers use for the node.
//   avoid:       lowercase words that must not appear; synonyms of `term`.
// A word is known when a node lists it in `identifiers`. A word is avoided when
// a node lists it in `avoid`. A word in both lists is a vocabulary conflict.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:yaml/yaml.dart';

/// The public libraries whose export namespaces form the public API.
const _publicLibraries = <String>[
  'packages/fp_di/lib/fp_di.dart',
  'packages/fp_di/lib/tooling.dart',
  'packages/fp_di_flutter/lib/fp_di_flutter.dart',
];

/// English function words that carry no vocabulary meaning. The word check
/// ignores them in identifiers. Keep this list short and in one place.
const _stopWords = <String>{
  'a',
  'an',
  'the',
  'of',
  'to',
  'is',
  'on',
  'at',
  'by',
  'as',
  'in',
  'or',
  'and',
  'with',
  'without',
  'from',
  'for',
  'all',
  'any',
  'has',
  'not',
  'if',
  'when',
  'into',
  'else',
};

/// Members that every object has. The extraction skips them. The extraction
/// also skips every member that overrides a member of a type outside this
/// repository; see [_externalMemberNames].
const _objectMembers = <String>{
  'toString',
  'hashCode',
  'noSuchMethod',
  'runtimeType',
};

final _plainName = RegExp(r'^[A-Za-z$][A-Za-z0-9_$]*$');

Future<void> main(List<String> arguments) async {
  final options = arguments.toSet();
  if (options.contains('-h') || options.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  final unknownOptions = options.where(
    (option) => !const {
      '--list',
      '--json',
      '--words',
      '--prose',
      '--all-uses',
    }.contains(option),
  );
  if (unknownOptions.isNotEmpty) {
    stderr.writeln('ERROR: unknown option ${unknownOptions.join(', ')}');
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  final root = _findRepositoryRoot();
  if (!File('${root.path}/.dart_tool/package_config.json').existsSync()) {
    stderr.writeln(
      'Missing .dart_tool/package_config.json. '
      'Run `flutter pub get` first.',
    );
    exitCode = 2;
    return;
  }

  final collection = AnalysisContextCollection(includedPaths: [root.path]);
  final entries = await _extractApi(root, collection);

  if (options.contains('--list')) {
    if (options.contains('--json')) {
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert([for (final entry in entries) entry.toJson()]),
      );
    } else {
      for (final entry in entries) {
        stdout.writeln(entry.listLine);
      }
    }
    return;
  }

  final uses = _wordUses(entries);
  if (options.contains('--words')) {
    for (final word in uses.keys.toList()..sort()) {
      final list = uses[word]!;
      stdout.writeln('$word  ${list.length}  ${list.take(3).join(', ')}');
    }
    return;
  }

  final vocabulary = _loadVocabulary(root);
  final limit = options.contains('--all-uses') ? null : 5;

  final conflicts = <String>[
    for (final word in vocabulary.avoided.keys.toList()..sort())
      if (vocabulary.known.containsKey(word)) word,
  ];
  final unknown = <String>[];
  final avoided = <String>[];
  for (final word in uses.keys.toList()..sort()) {
    if (vocabulary.known.containsKey(word) &&
        vocabulary.avoided.containsKey(word)) {
      continue;
    }
    if (vocabulary.avoided.containsKey(word)) {
      avoided.add(word);
    } else if (!vocabulary.known.containsKey(word)) {
      unknown.add(word);
    }
  }
  final unused = <String>[
    for (final word in vocabulary.known.keys.toList()..sort())
      if (!uses.containsKey(word)) word,
  ];
  final stale = await _staleBindings(root, collection, vocabulary);
  final prose = options.contains('--prose')
      ? _proseFindings(root, vocabulary)
      : <String>[];

  _section('unknown word', [
    for (final word in unknown) '$word: ${_uses(uses[word]!, limit)}',
  ]);
  String ids(List<OntologyNode>? nodes) =>
      (nodes ?? const []).map((n) => n.id).join(', ');
  String preferred(List<OntologyNode>? nodes) =>
      (nodes ?? const []).map((n) => '"${n.term}" (${n.id})').join(', ');
  _section('avoided word', [
    for (final word in avoided)
      '$word -> prefer ${preferred(vocabulary.avoided[word])}: '
          '${_uses(uses[word]!, limit)}',
  ]);
  _section('vocabulary conflict', [
    for (final word in conflicts)
      '$word: known for ${ids(vocabulary.known[word])}'
          ' and avoided by ${ids(vocabulary.avoided[word])}',
  ]);
  _section('unused vocabulary (informational)', unused);
  _section('stale binding', stale);
  if (options.contains('--prose')) {
    _section('avoided word in prose', prose);
  }

  final failed =
      unknown.isNotEmpty ||
      avoided.isNotEmpty ||
      conflicts.isNotEmpty ||
      stale.isNotEmpty ||
      prose.isNotEmpty;
  final proseSuffix = options.contains('--prose')
      ? ' prose=${prose.length}'
      : '';
  if (failed) {
    stdout.writeln(
      'FAIL unknown=${unknown.length} avoided=${avoided.length} '
      'conflicts=${conflicts.length} stale=${stale.length}$proseSuffix',
    );
    exitCode = 1;
  } else {
    stdout.writeln(
      'OK entries=${entries.length} words=${uses.length}$proseSuffix',
    );
  }
}

const _usage = '''
Usage: dart run agents/scripts/check_vocabulary.dart [options]

  --list       print the public API inventory
  --json       with --list, print JSON
  --words      print the distinct words with counts and first uses
  --prose      also scan Markdown prose for avoided words
  --all-uses   print every use of a word
  -h, --help   print this help''';

void _section(String title, List<String> lines) {
  if (lines.isEmpty) return;
  stdout.writeln('$title (${lines.length})');
  for (final line in lines) {
    stdout.writeln('  $line');
  }
  stdout.writeln();
}

String _uses(List<String> uses, int? limit) {
  if (limit == null || uses.length <= limit) return uses.join(', ');
  return '${uses.take(limit).join(', ')} (+${uses.length - limit} more)';
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

String _relative(Directory root, String path) =>
    path.startsWith('${root.path}/')
    ? path.substring(root.path.length + 1)
    : path;

// --- Word splitting -------------------------------------------------------

/// Splits an identifier into lowercase words. Acronyms stay together, trailing
/// digits go away, and stop words go away.
List<String> splitWords(String name) {
  final words = <String>[];
  for (final chunk in name.split(RegExp(r'[^A-Za-z0-9]+'))) {
    if (chunk.isEmpty) continue;
    final spaced = chunk
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAllMapped(
          RegExp(r'([A-Z]+)([A-Z][a-z])'),
          (m) => '${m[1]} ${m[2]}',
        );
    for (final piece in spaced.split(' ')) {
      final word = piece.toLowerCase().replaceAll(RegExp(r'\d+$'), '');
      if (word.isEmpty || _stopWords.contains(word)) continue;
      words.add(word);
    }
  }
  return words;
}

/// Maps each word to the sorted, distinct qualified names that use it.
Map<String, List<String>> _wordUses(List<ApiEntry> entries) {
  final sets = <String, Set<String>>{};
  for (final entry in entries) {
    for (final word in entry.words) {
      (sets[word] ??= <String>{}).add(entry.qualified);
    }
  }
  return {
    for (final word in sets.keys.toList()..sort())
      word: sets[word]!.toList()..sort(),
  };
}

// --- Public API extraction ------------------------------------------------

class ApiEntry {
  ApiEntry({
    required this.package,
    required this.kind,
    required this.owner,
    required this.member,
    required this.path,
    this.function,
    this.isStatic = false,
  }) : words = splitWords(member);

  /// The workspace package that declares the element.
  final String package;
  final String kind;

  /// The class-like element that declares the member, or empty at top level.
  final String owner;
  final String member;

  /// The function that owns a named parameter, such as `Scope.initialize`.
  final String? function;
  final bool isStatic;
  final String path;
  final List<String> words;

  String get qualified {
    if (function != null) return '$function($member)';
    return owner.isEmpty ? member : '$owner.$member';
  }

  /// The top-level name that groups the entry in sorted output.
  String get group => owner.isNotEmpty ? owner : (function ?? member);

  String get listLine =>
      '$package  $kind  $qualified  [${words.join(',')}]  $path';

  Map<String, Object?> toJson() => {
    'package': package,
    'kind': kind,
    'owner': owner,
    'member': member,
    'function': function,
    'static': isStatic,
    'words': words,
    'path': path,
  };
}

Future<List<ApiEntry>> _extractApi(
  Directory root,
  AnalysisContextCollection collection,
) async {
  final extractor = _Extractor(root);
  for (final relativePath in _publicLibraries) {
    final path = '${root.path}/$relativePath';
    final library = await _resolveLibrary(collection, path);
    if (library == null) {
      stderr.writeln('ERROR: cannot resolve $relativePath');
      exit(2);
    }
    extractor.visitLibrary(library);
  }
  return extractor.entries..sort(_compareEntries);
}

Future<LibraryElement?> _resolveLibrary(
  AnalysisContextCollection collection,
  String path,
) async {
  final session = collection.contextFor(path).currentSession;
  final result = await session.getResolvedLibrary(path);
  return result is ResolvedLibraryResult ? result.element : null;
}

int _compareEntries(ApiEntry a, ApiEntry b) {
  final byPackage = a.package.compareTo(b.package);
  if (byPackage != 0) return byPackage;
  final byGroup = a.group.compareTo(b.group);
  if (byGroup != 0) return byGroup;
  final byRank = (a.owner.isEmpty && a.function == null ? 0 : 1).compareTo(
    b.owner.isEmpty && b.function == null ? 0 : 1,
  );
  if (byRank != 0) return byRank;
  final byName = a.qualified.compareTo(b.qualified);
  return byName != 0 ? byName : a.kind.compareTo(b.kind);
}

class _Extractor {
  _Extractor(this.root);

  final Directory root;
  final entries = <ApiEntry>[];
  final _seen = <String>{};

  bool _inRepository(Element element) {
    final path = _declaringPath(element);
    return path != null && path.startsWith('${root.path}/packages/');
  }

  String? _declaringPath(Element element) =>
      element.firstFragment.libraryFragment?.source.fullName;

  void visitLibrary(LibraryElement library) {
    final names = library.exportNamespace.definedNames2;
    for (final key in names.keys.toList()..sort()) {
      final element = names[key]!;
      final name = element.name;
      if (name == null || name.startsWith('_') || !_inRepository(element)) {
        continue;
      }
      switch (element) {
        case ClassElement():
          _visitInstance(element, 'class');
        case MixinElement():
          _visitInstance(element, 'mixin');
        case EnumElement():
          _visitInstance(element, 'enum');
        case ExtensionTypeElement():
          _visitInstance(element, 'extension type');
        case ExtensionElement():
          _visitInstance(element, 'extension');
        case TypeAliasElement():
          _add(element, 'typedef', '', name);
        case TopLevelFunctionElement():
          _add(element, 'function', '', name);
          _addParameters(element, '', name);
        case GetterElement():
          _add(
            element,
            element.isOriginVariable ? 'variable' : 'getter',
            '',
            name,
          );
        case SetterElement():
          final getter = names[name];
          if (getter is GetterElement && getter.isOriginVariable) continue;
          _add(element, 'setter', '', name);
        default:
          break;
      }
    }
  }

  void _visitInstance(InstanceElement element, String kind) {
    final owner = element.name!;
    _add(element, kind, '', owner);
    final external = element is InterfaceElement
        ? _externalMemberNames(element)
        : const <String>{};
    bool skip(String name, bool isStatic) =>
        !_plainName.hasMatch(name) ||
        name.startsWith('_') ||
        (!isStatic && external.contains(name));

    if (element is InterfaceElement) {
      for (final constructor in element.constructors) {
        final name = constructor.name;
        if (name == null || name.startsWith('_')) continue;
        final label = '$owner.$name';
        if (name != 'new') _add(constructor, 'constructor', owner, name);
        _addParameters(constructor, owner, label);
      }
    }
    for (final field in element.fields) {
      final name = field.name;
      if (!(field.isOriginDeclaration ||
              field.isOriginDeclaringFormalParameter) ||
          name == null ||
          skip(name, field.isStatic)) {
        continue;
      }
      _add(
        field,
        field.isEnumConstant ? 'enum value' : 'field',
        owner,
        name,
        isStatic: field.isStatic,
      );
    }
    for (final method in element.methods) {
      final name = method.name;
      if (name == null || skip(name, method.isStatic)) continue;
      _add(method, 'method', owner, name, isStatic: method.isStatic);
      _addParameters(method, owner, '$owner.$name');
    }
    for (final getter in element.getters) {
      final name = getter.name;
      if (!getter.isOriginDeclaration ||
          name == null ||
          skip(name, getter.isStatic)) {
        continue;
      }
      _add(getter, 'getter', owner, name, isStatic: getter.isStatic);
    }
    for (final setter in element.setters) {
      final name = setter.name?.replaceAll(RegExp(r'=$'), '');
      if (!setter.isOriginDeclaration ||
          name == null ||
          skip(name, setter.isStatic)) {
        continue;
      }
      _add(setter, 'setter', owner, name, isStatic: setter.isStatic);
    }
  }

  /// The names of the members that [element] inherits from a type outside this
  /// repository, such as `State.initState` or `Object.toString`. A member of
  /// [element] with such a name overrides it and does not count as API.
  Set<String> _externalMemberNames(InterfaceElement element) {
    final names = <String>{..._objectMembers};
    for (final type in element.allSupertypes) {
      final supertype = type.element;
      if (_inRepository(supertype)) continue;
      for (final member in <Element>[
        ...supertype.methods,
        ...supertype.getters,
        ...supertype.setters,
        ...supertype.fields,
      ]) {
        final name = member.name?.replaceAll(RegExp(r'=$'), '');
        if (name != null) names.add(name);
      }
    }
    return names;
  }

  void _addParameters(
    ExecutableElement executable,
    String owner,
    String function,
  ) {
    for (final parameter in executable.formalParameters) {
      final name = parameter.name;
      if (!parameter.isNamed || name == null || name.startsWith('_')) continue;
      _add(
        executable,
        'named parameter',
        owner,
        name,
        function: function,
        isStatic: executable.isStatic,
      );
    }
  }

  void _add(
    Element element,
    String kind,
    String owner,
    String member, {
    String? function,
    bool isStatic = false,
  }) {
    final path = _declaringPath(element);
    if (path == null) return;
    final relative = _relative(root, path);
    final package = relative.split('/')[1];
    final entry = ApiEntry(
      package: package,
      kind: kind,
      owner: owner,
      member: member,
      function: function,
      isStatic: isStatic,
      path: relative,
    );
    if (_seen.add('${entry.package}|${entry.kind}|${entry.qualified}')) {
      entries.add(entry);
    }
  }
}

// --- Vocabulary -----------------------------------------------------------

class OntologyNode {
  OntologyNode(this.id, this.term, this.file);
  final String id;
  final String term;
  final String file;
}

class Vocabulary {
  /// Word to the nodes that list it in `identifiers`.
  final known = <String, List<OntologyNode>>{};

  /// Word to the nodes that list it in `avoid`.
  final avoided = <String, List<OntologyNode>>{};

  /// The parsed `nodes:` maps with the file that declares each one.
  final nodes = <(OntologyNode, Map<Object?, Object?>)>[];
  final relationEvidence = <(String, String)>[];
}

Vocabulary _loadVocabulary(Directory root) {
  final vocabulary = Vocabulary();
  final files =
      Directory('${root.path}/ontology')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.yml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final relative = _relative(root, file.path);
    final document = loadYaml(file.readAsStringSync());
    if (document is! YamlMap) continue;
    final nodes = document['nodes'];
    if (nodes is YamlMap) {
      for (final id in nodes.keys) {
        final value = nodes[id];
        if (value is! YamlMap) continue;
        final term = value['term'];
        final node = OntologyNode(
          '$id',
          term is String ? term : '$id',
          relative,
        );
        vocabulary.nodes.add((node, value));
        for (final word in _wordList(value['identifiers'])) {
          (vocabulary.known[word] ??= []).add(node);
        }
        for (final word in _wordList(value['avoid'])) {
          (vocabulary.avoided[word] ??= []).add(node);
        }
      }
    }
    final relations = document['relations'];
    if (relations is YamlList) {
      for (final relation in relations) {
        if (relation is! YamlMap) continue;
        for (final path in _stringList(relation['evidence'])) {
          vocabulary.relationEvidence.add((relative, path));
        }
      }
    }
  }
  return vocabulary;
}

List<String> _stringList(Object? value) => value is YamlList
    ? [
        for (final item in value)
          if (item is String) item,
      ]
    : const [];

List<String> _wordList(Object? value) => [
  for (final word in _stringList(value)) word.trim().toLowerCase(),
];

Future<List<String>> _staleBindings(
  Directory root,
  AnalysisContextCollection collection,
  Vocabulary vocabulary,
) async {
  final findings = <String>[];
  final declared = <String, Set<String>?>{};

  bool exists(String path) {
    if (path.contains('://')) return true;
    final clean = path.split('#').first;
    return FileSystemEntity.typeSync('${root.path}/$clean') !=
        FileSystemEntityType.notFound;
  }

  for (final (node, map) in vocabulary.nodes) {
    final bindings = map['bindings'];
    if (bindings is YamlList) {
      for (final binding in bindings) {
        if (binding is! YamlMap) continue;
        final path = binding['path'];
        if (path is! String) continue;
        if (!exists(path)) {
          findings.add('${node.file}: ${node.id}: binding path missing: $path');
          continue;
        }
        final symbol = binding['symbol'];
        if (binding['type'] != 'file' || symbol is! String) continue;
        final names = declared[path] ??= await _declaredNames(
          root,
          collection,
          path,
        );
        if (names == null || !names.contains(symbol)) {
          findings.add(
            '${node.file}: ${node.id}: symbol $symbol is not declared in $path',
          );
        }
      }
    }
    for (final path in _stringList(map['evidence'])) {
      if (!exists(path)) {
        findings.add('${node.file}: ${node.id}: evidence path missing: $path');
      }
    }
  }
  for (final (file, path) in vocabulary.relationEvidence) {
    if (!exists(path)) {
      findings.add('$file: relation evidence path missing: $path');
    }
  }
  return findings;
}

/// The public top-level names that the Dart file at [relativePath] declares,
/// or `null` when the file is not a Dart file.
Future<Set<String>?> _declaredNames(
  Directory root,
  AnalysisContextCollection collection,
  String relativePath,
) async {
  if (!relativePath.endsWith('.dart')) return null;
  final path = '${root.path}/$relativePath';
  final library = await _resolveLibrary(collection, path);
  if (library != null) {
    return {
      for (final child in library.children)
        if (child.name case final name? when !name.startsWith('_')) name,
    };
  }
  // A part file: fall back to a scan of the declaration keywords.
  final pattern = RegExp(
    r'^\s*(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*'
    r'(?:class|enum|mixin|typedef|extension\s+type(?:\s+const)?|extension)\s+'
    r'([A-Za-z][A-Za-z0-9_$]*)',
    multiLine: true,
  );
  return {
    for (final match in pattern.allMatches(File(path).readAsStringSync()))
      match.group(1)!,
  };
}

// --- Prose ----------------------------------------------------------------

List<String> _proseFindings(Directory root, Vocabulary vocabulary) {
  if (vocabulary.avoided.isEmpty) return const [];
  final alternatives = [
    for (final word in vocabulary.avoided.keys.toList()..sort())
      RegExp.escape(word).replaceAll(r'\ ', r'\s+').replaceAll(' ', r'\s+'),
  ];
  final pattern = RegExp(
    '(?<![A-Za-z0-9_])(${alternatives.join('|')})(?![A-Za-z0-9_])',
    caseSensitive: false,
  );
  final findings = <String>[];
  for (final file in _proseFiles(root)) {
    final relative = _relative(root, file.path);
    var fence = '';
    final lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final marker = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
      if (fence.isEmpty) {
        if (marker != null) {
          fence = marker;
          continue;
        }
      } else {
        if (marker != null &&
            marker.startsWith(fence[0]) &&
            marker.length >= fence.length) {
          fence = '';
        }
        continue;
      }
      final text = line
          .replaceAll(RegExp(r'(`+).+?\1'), ' ')
          .replaceAll(RegExp(r'\]\([^)]*\)'), ']');
      for (final match in pattern.allMatches(text)) {
        final word = match
            .group(1)!
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
        final nodes = vocabulary.avoided[word];
        final term = nodes == null
            ? '?'
            : nodes.map((node) => node.term).toSet().join(' / ');
        findings.add('$relative:${index + 1}: $word (prefer $term)');
      }
    }
  }
  return findings;
}

Iterable<File> _proseFiles(Directory root) sync* {
  final readme = File('${root.path}/README.md');
  if (readme.existsSync()) yield readme;
  final packages = Directory('${root.path}/packages');
  if (packages.existsSync()) {
    for (final package
        in packages.listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path))) {
      final packageReadme = File('${package.path}/README.md');
      if (packageReadme.existsSync()) yield packageReadme;
      final doc = Directory('${package.path}/doc');
      if (doc.existsSync()) {
        for (final file
            in doc.listSync().whereType<File>().toList()
              ..sort((a, b) => a.path.compareTo(b.path))) {
          if (file.path.endsWith('.md')) yield file;
        }
      }
    }
  }
  final specs = Directory('${root.path}/specs');
  if (specs.existsSync()) {
    final files =
        specs
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.md') &&
                  // A decision log is append-only history, so it keeps the
                  // words of its time.
                  !file.path.endsWith('/log.md') &&
                  !_relative(root, file.path).split('/').contains('researches'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    yield* files;
  }
}
