import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/analysis/context_builder.dart';
import 'package:analyzer/dart/analysis/context_locator.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/source/source_range.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver.dart'
    show AnalysisDriver, AnalysisDriverGeneric;
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer_plugin/plugin/plugin.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:recase/recase.dart';
import 'package:string_literal_finder/src/string_literal_finder.dart';
import 'package:string_literal_finder/src/utils.dart';
import 'package:yaml/yaml.dart';

final _logger = Logger('string_literal_finder.plugin');

class StringLiteralFinderPlugin extends ServerPlugin {
  StringLiteralFinderPlugin(ResourceProvider provider) : super(provider);

  @override
  List<String> get fileGlobsToAnalyze => <String>['**/*.dart'];

  @override
  String get name => 'String Literal Finder';

  @override
  String get version => '1.0.0';

  var _filesFromSetPriorityFilesRequest = <String>[];

  final Map<AnalysisDriverGeneric, AnalysisOptions> _options = {};

  @override
  AnalysisDriverGeneric createAnalysisDriver(plugin.ContextRoot contextRoot) {
    final rootPath = contextRoot.root;
    final locator =
        ContextLocator(resourceProvider: resourceProvider).locateRoots(
      includedPaths: <String>[rootPath],
      excludedPaths: <String>[
        ...contextRoot.exclude,
      ],
      optionsFile: contextRoot.optionsFile,
    );

    if (locator.isEmpty) {
      final error = StateError('Unexpected empty context');
      channel.sendNotification(plugin.PluginErrorParams(
        true,
        error.message,
        error.stackTrace.toString(),
      ).toNotification());

      throw error;
    }

    final builder = ContextBuilder(
      resourceProvider: resourceProvider,
    );

    final analysisContext = builder.createContext(contextRoot: locator.first);
    // ignore: avoid_as
    final context = analysisContext as DriverBasedAnalysisContext;
    final dartDriver = context.driver;
    try {
      final analysisOptions =
          (_options[dartDriver] ??= _getAnalysisOptions(dartDriver));

      if (analysisOptions.debug) {
        StringLiteralFinderUtils.setupDebugLogging();
      }

      runZonedGuarded(
        () {
          dartDriver.results.listen((analysisResult) {
            if (analysisResult is ResolvedUnitResult) {
              _processResult(
                dartDriver,
                analysisOptions,
                analysisResult,
              );
            } else if (analysisResult is ErrorsResult) {
              _logger
                  .severe('analysis produce errors. ${analysisResult.errors}');
            }
          });
        },
        (Object e, StackTrace stackTrace) {
          channel.sendNotification(
            plugin.PluginErrorParams(
              false,
              'string_literal_finder. Unexpected error: ${e.toString()}',
              stackTrace.toString(),
            ).toNotification(),
          );
        },
      );
    } catch (e, stackTrace) {
      channel.sendNotification(
        plugin.PluginErrorParams(
          false,
          'string_literal_finder. Unexpected error: ${e.toString()}',
          stackTrace.toString(),
        ).toNotification(),
      );
    }

    return dartDriver;
  }

  @override
  Future<plugin.EditGetFixesResult> handleEditGetFixes(
      plugin.EditGetFixesParams parameters) async {
    try {
      final driver = driverForPath(parameters.file) as AnalysisDriver;
      final analysisOptions =
          (_options[driver] ??= _getAnalysisOptions(driver));
      final analysisResult = await driver.getResult(parameters.file);

      if (analysisResult is! ResolvedUnitResult) {
        return plugin.EditGetFixesResult([]);
      }

      _logger.fine('handleEditGetFixes($parameters)');
      final fixes = _check(
        driver,
        analysisOptions,
        analysisResult.path,
        analysisResult.unit,
        analysisResult,
      )
          .where((fix) =>
              fix.error.location.file == parameters.file &&
              fix.error.location.offset <= parameters.offset &&
              parameters.offset <=
                  fix.error.location.offset + fix.error.location.length &&
              fix.fixes.isNotEmpty)
          .toList();
      _logger.fine('result: $fixes');

      return plugin.EditGetFixesResult(fixes);
    } on Exception catch (e, stackTrace) {
      channel.sendNotification(
        plugin.PluginErrorParams(false, e.toString(), stackTrace.toString())
            .toNotification(),
      );

      return plugin.EditGetFixesResult([]);
    }
  }

  void _processResult(
    AnalysisDriver dartDriver,
    AnalysisOptions analysisOptions,
    ResolvedUnitResult analysisResult,
  ) {
    final path = analysisResult.path;

    final unit = analysisResult.unit;
    final isAnalyzed =
        dartDriver.analysisContext?.contextRoot.isAnalyzed(path) ?? false;
    final isExcluded = !isAnalyzed || analysisOptions.isExcluded(path);
    if (isExcluded) {
      _logger.finer('is not analyzed: $path '
          '(analyzed: $isAnalyzed / isExcluded: $isExcluded)');

      channel.sendNotification(
        plugin.AnalysisErrorsParams(
          path,
          <plugin.AnalysisError>[],
        ).toNotification(),
      );
      return;
    }

    try {
      final errors =
          _check(dartDriver, analysisOptions, path, unit, analysisResult);

      channel.sendNotification(
        plugin.AnalysisErrorsParams(
          path,
          errors.map((e) => e.error).toList(),
        ).toNotification(),
      );
    } catch (e, stackTrace) {
      _logger.severe('Error while analysing file', e, stackTrace);
      channel.sendNotification(
        plugin.PluginErrorParams(
          false,
          e.toString(),
          stackTrace.toString(),
        ).toNotification(),
      );
    }
  }

  File? _findArbFile(String rootDir) {
    final l10nYaml = resourceProvider.getFile(p.join(rootDir, 'l10n.yaml'));
    if (!l10nYaml.exists) {
      _logger.warning('Unable to find l10n.yaml');
      return null;
    }
    final dynamic yaml = loadYaml(l10nYaml.readAsStringSync());
    final arbDir = yaml['arb-dir'] as String? ?? 'lib/l10n';
    final arbName = yaml['template-arb-file'] as String? ?? 'app_en.arb';
    _logger.fine('got yaml: $yaml -- arbDir: $arbDir / arbName: $arbName');
    final arbFile = resourceProvider.getFile(p.join(rootDir, arbDir, arbName));
    _logger.fine('got arbFile: $arbFile');
    if (!arbFile.exists) {
      _logger.severe('configured arb file does not exist. $arbFile');
      return null;
    }
    return arbFile;
  }

  List<plugin.AnalysisErrorFixes> _check(
    AnalysisDriver driver,
    AnalysisOptions analysisOptions,
    String filePath,
    CompilationUnit unit,
    ResolvedUnitResult analysisResult,
  ) {
    final errors = <plugin.AnalysisErrorFixes>[];

    final root = driver.analysisContext?.contextRoot.root.path;
    var relative = '';
    if (root != null) {
      relative = p.relative(filePath, from: root);
      final options = _options[driver];
      if (options != null && options.isExcluded(relative)) {
        return [];
      }
    }
    final arbFile = _findArbFile(root ?? filePath);

    final visitor = StringLiteralVisitor<dynamic>(
      filePath: filePath,
      unit: unit,
      foundStringLiteral: (foundStringLiteral) {
        final location = plugin.Location(
          foundStringLiteral.filePath,
          foundStringLiteral.charOffset,
          foundStringLiteral.charLength,
          foundStringLiteral.loc.lineNumber,
          foundStringLiteral.loc.columnNumber,
          endLine: foundStringLiteral.locEnd.lineNumber,
          endColumn: foundStringLiteral.locEnd.columnNumber,
        );

        final content = analysisResult.content;
        final semicolonOffset = content.lastIndexOf(
            ';',
            analysisResult.lineInfo
                .getOffsetOfLineAfter(foundStringLiteral.charEnd));
        final fix = plugin.PrioritizedSourceChange(
          1,
          plugin.SourceChange(
            'Add // NON-NLS',
            edits: [
              plugin.SourceFileEdit(
                filePath,
                // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
                // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
                analysisResult.exists ? 0 : -1,
                // analysisResult.libraryElement.source.modificationStamp,
                edits: [
                  plugin.SourceEdit(semicolonOffset + 1, 0, ' // NON-NLS'),
                ],
              ),
            ],
          ),
        );

        String stringValue() {
          if (content.length < foundStringLiteral.charEnd) {
            return '';
          }
          return content
              .substring(
                foundStringLiteral.charOffset,
                foundStringLiteral.charEnd,
              )
              .trim();
        }

        final stringCode = foundStringLiteral.stringValue ?? stringValue();

        errors.add(
          plugin.AnalysisErrorFixes(
            plugin.AnalysisError(
              plugin.AnalysisErrorSeverity('WARNING'),
              plugin.AnalysisErrorType.LINT,
              location,
              'Found string literal: $stringCode',
              'found_string_literal',
              correction:
                  'Externalize string or add nonNls() decorator method, '
                  'or add // NON-NLS to end of line. ($filePath) ($relative)',
              hasFix: true,
            ),
            fixes: [
              ...?_extractStringFix(
                analysisOptions,
                arbFile,
                filePath,
                foundStringLiteral,
                analysisResult,
              ),
              fix,
            ],
          ),
        );
      },
    );
    unit.visitChildren(visitor);
    return errors;
  }

  List<plugin.PrioritizedSourceChange>? _extractStringFix(
    AnalysisOptions options,
    File? arbFile,
    String filePath,
    FoundStringLiteral foundStringLiteral,
    ResolvedUnitResult analysisResult,
  ) {
    final stringContents = foundStringLiteral.stringLiteral.stringValue;
    if (arbFile == null || stringContents == null) {
      _logger.severe(
          'Unable to find arbFile or stringContents: $arbFile /// $stringContents');
      if (options.debug) {
        return [
          plugin.PrioritizedSourceChange(
            2,
            plugin.SourceChange(
              'Unable to find arbFile or stringContents, arbFile: $arbFile // stringContents: $stringContents',
              edits: [],
            ),
          ),
        ];
      }
      return null;
    }
    final key = stringContents.camelCase;
    const keyGroup = 'key_group';
    const keyKind = plugin.LinkedEditSuggestionKind.VARIABLE;
    final keySuggestions = [key, 'secondTest$key'];
    const arbEditOffset = 2;
    const arbIndent = '  ';
    final arbFirstLine = '$arbIndent"$key": "$stringContents",\n';
    final arbSecondLine = '$arbIndent"@$key": {},\n';
    final changeBuilder = ChangeBuilder(session: analysisResult.session);
    // changeBuilder.addGenericFileEdit(arbFile.path, (builder) {
    //   builder.addInsertion(2, (builder) {
    //     builder.write('  "');
    //     builder.addSimpleLinkedEdit(keyGroup, key,
    //         kind: plugin.LinkedEditSuggestionKind.VARIABLE);
    //     builder.write('": "$stringContents"),');
    //     builder.writeln();
    //     builder.write('  "@');
    //     builder.addSimpleLinkedEdit(keyGroup, key,
    //         kind: plugin.LinkedEditSuggestionKind.VARIABLE);
    //     builder.write('": {}');
    //     builder.writeln();
    //   });
    // });
    changeBuilder.addYamlFileEdit(arbFile.path, (builder) {
      builder.addInsertion(2, (builder) {
        builder.write('  "');
        // builder.addSimpleLinkedEdit(keyGroup, key);
        builder.addSimpleLinkedEdit(keyGroup, key,
            kind: keyKind, suggestions: keySuggestions);
        builder.write('": "$stringContents",');
        builder.writeln();
        builder.write('  "@');
        // builder.addSimpleLinkedEdit(keyGroup, key);
        builder.addSimpleLinkedEdit(keyGroup, key,
            kind: keyKind, suggestions: keySuggestions);
        builder.write('": {},');
        builder.writeln();
      });
    });
    changeBuilder.addGenericFileEdit(filePath, (builder) {
      builder.addReplacement(
        SourceRange(
          foundStringLiteral.charOffset,
          foundStringLiteral.charLength,
        ),
        (builder) {
          builder.write('loc.');
          builder.selectAll(() {
            // builder.addSimpleLinkedEdit(
            //   keyGroup,
            //   key,
            // );
            builder.addSimpleLinkedEdit(
              keyGroup,
              key,
              kind: keyKind,
              suggestions: keySuggestions,
            );
          });
        },
      );
    });
    return [
      plugin.PrioritizedSourceChange(
        10,
        changeBuilder.sourceChange..message = 'B: Extract String ($key)',
      ),
      plugin.PrioritizedSourceChange(
        1,
        plugin.SourceChange(
          'Extract string with name $key',
          id: 'extract_string',
          // selection: plugin.Position(
          //   filePath,
          //   foundStringLiteral.charOffset + ('loc.'.length),
          // ),
          selection: plugin.Position(
            arbFile.path,
            arbEditOffset,
          ),
          edits: [
            plugin.SourceFileEdit(
              arbFile.path,
              // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
              // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
              0,
              edits: [
                plugin.SourceEdit(
                  arbEditOffset,
                  0,
                  [arbFirstLine, arbSecondLine].join(),
                ),
              ],
            ),
            plugin.SourceFileEdit(
              filePath,
              // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
              // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
              analysisResult.exists ? 0 : -1,
              // analysisResult.libraryElement.source.modificationStamp,
              edits: [
                plugin.SourceEdit(
                  foundStringLiteral.charOffset,
                  foundStringLiteral.charLength,
                  'loc.$key',
                ),
              ],
            ),
          ],
          linkedEditGroups: [
            plugin.LinkedEditGroup(
              [
                plugin.Position(
                  arbFile.path,
                  arbEditOffset + arbIndent.length + 1,
                ),
                plugin.Position(
                  arbFile.path,
                  arbEditOffset + arbFirstLine.length + arbIndent.length + 2,
                ),
                plugin.Position(
                    filePath, foundStringLiteral.charOffset + ('loc.'.length)),
              ],
              key.length,
              [
                plugin.LinkedEditSuggestion(
                    key, plugin.LinkedEditSuggestionKind.VARIABLE)
              ],
            ),
          ],
        ),
      ),
      /*
      plugin.PrioritizedSourceChange(
        1,
        plugin.SourceChange(
          'SECOND Extract string with name $key',
          // id: 'extract_string',
          // selection: plugin.Position(
          //   arbFile.path,
          //   3,
          // ),
          edits: [
            plugin.SourceFileEdit(
              filePath,
              // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
              // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
              analysisResult.exists ? 0 : -1,
              // analysisResult.libraryElement.source.modificationStamp,
              edits: [
                plugin.SourceEdit(
                  foundStringLiteral.charOffset,
                  foundStringLiteral.charLength,
                  'loc.$key',
                ),
              ],
            ),
          ],
        ),
      ),
      plugin.PrioritizedSourceChange(
        1,
        plugin.SourceChange(
          'THIRD Extract string with name $key',
          // id: 'extract_string',
          // selection: plugin.Position(
          //   arbFile.path,
          //   3,
          // ),
          edits: [
            plugin.SourceFileEdit(
              filePath,
              // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
              // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
              analysisResult.exists ? 0 : -1,
              // analysisResult.libraryElement.source.modificationStamp,
              edits: [
                plugin.SourceEdit(
                  foundStringLiteral.charOffset,
                  foundStringLiteral.charLength,
                  'loc.$key',
                ),
              ],
            ),
            plugin.SourceFileEdit(
              filePath,
              // https://groups.google.com/a/dartlang.org/g/analyzer-discuss/c/lfRzX0yw3ZU
              // https://github.com/dart-code-checker/dart-code-metrics/blob/0813a54f2969dbaf5e00c6ae2c4ab1132a64580a/lib/src/analyzer_plugin/analyzer_plugin_utils.dart#L44-L47s
              analysisResult.exists ? 0 : -1,
              // analysisResult.libraryElement.source.modificationStamp,
              edits: [
                plugin.SourceEdit(
                  foundStringLiteral.charOffset,
                  foundStringLiteral.charLength,
                  'loc.$key',
                ),
              ],
            ),
          ],
        ),
      ),*/
    ];
  }

  AnalysisOptions _getAnalysisOptions(AnalysisDriver analysisDriver) {
    final optionsPath = analysisDriver.analysisContext?.contextRoot.optionsFile;
    final exists = optionsPath?.exists ?? false;
    if (!exists || optionsPath == null) {
      _logger.warning('Unable to resolve optionsFile.');
      return AnalysisOptions(excludeGlobs: []);
    }
    return AnalysisOptions.loadFromYaml(optionsPath.readAsStringSync());
  }

  // @override
  // void sendNotificationsForSubscriptions(
  //     Map<String, List<AnalysisService>> subscriptions) {
  //   TODO: implement sendNotificationsForSubscriptions
  // }

  @override
  void contentChanged(String path) {
    super.driverForPath(path)?.addFile(path);
  }

  @override
  Future<plugin.AnalysisSetContextRootsResult> handleAnalysisSetContextRoots(
    plugin.AnalysisSetContextRootsParams parameters,
  ) async {
    final result = await super.handleAnalysisSetContextRoots(parameters);
    // The super-call adds files to the driver, so we need to prioritize them so they get analyzed.
    _updatePriorityFiles();

    return result;
  }

  @override
  Future<plugin.AnalysisSetPriorityFilesResult> handleAnalysisSetPriorityFiles(
    plugin.AnalysisSetPriorityFilesParams parameters,
  ) async {
    _filesFromSetPriorityFilesRequest = parameters.files;
    _updatePriorityFiles();

    return plugin.AnalysisSetPriorityFilesResult();
  }

  // https://github.com/dart-code-checker/dart-code-metrics/blob/e8e14d44b940a5b29d33a782432f853ee42ac7a0/lib/src/analyzer_plugin/analyzer_plugin.dart#L274
  /// AnalysisDriver doesn't fully resolve files that are added via `addFile`; they need to be either explicitly requested
  /// via `getResult`/etc, or added to `priorityFiles`.
  ///
  /// This method updates `priorityFiles` on the driver to include:
  ///
  /// - Any files prioritized by the analysis server via [handleAnalysisSetPriorityFiles]
  /// - All other files the driver has been told to analyze via addFile (in [ServerPlugin.handleAnalysisSetContextRoots])
  ///
  /// As a result, [_processResult] will get called with resolved units, and thus all of our diagnostics
  /// will get run on all files in the repo instead of only the currently open/edited ones!
  void _updatePriorityFiles() {
    final filesToFullyResolve = {
      // Ensure these go first, since they're actually considered priority; ...
      ..._filesFromSetPriorityFilesRequest,

      // ... all other files need to be analyzed, but don't trump priority
      for (final driver2 in driverMap.values)
        ...(driver2 as AnalysisDriver).addedFiles,
    };

    // From ServerPlugin.handleAnalysisSetPriorityFiles
    final filesByDriver = <AnalysisDriverGeneric, List<String>>{};
    for (final file in filesToFullyResolve) {
      final contextRoot = contextRootContaining(file);
      if (contextRoot != null) {
        // TODO(dkrutskikh): Which driver should we use if there is no context root?
        final driver = driverMap[contextRoot];
        if (driver != null) {
          filesByDriver.putIfAbsent(driver, () => <String>[]).add(file);
        }
      }
    }
    filesByDriver.forEach((driver, files) {
      driver.priorityFiles = files;
    });
  }
}

class AnalysisOptions {
  AnalysisOptions({
    required this.excludeGlobs,
    this.debug = false,
  });

  static AnalysisOptions loadFromYaml(String yamlSource) {
    final yaml =
        json.decode(json.encode(loadYaml(yamlSource))) as Map<String, dynamic>;
    final options = yaml['string_literal_finder'] as Map<String, dynamic>?;
    final excludeGlobs =
        options?['exclude_globs'] as List<dynamic>? ?? <dynamic>[];
    final debug = options?['debug'] as bool? ?? false;
    return AnalysisOptions(
      excludeGlobs: excludeGlobs.cast<String>().map((e) => Glob(e)).toList(),
      debug: debug,
    );
  }

  final List<Glob> excludeGlobs;
  final bool debug;

  bool isExcluded(String path) {
    return excludeGlobs.any((glob) => glob.matches(path));
  }
}
