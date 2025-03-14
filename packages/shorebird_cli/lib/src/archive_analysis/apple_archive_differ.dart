// cspell:words xcframeworks xcasset unsign codesign assetutil pubspec xcassets
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/macho.dart';

/// {@template apple_archive_differ}
/// Finds differences between two IPAs, zipped Xcframeworks, or zipped macOS
/// .apps. Note that, due to a quirk in how macOS .app zips are handled by
/// package:archive, they must *not* include the top-level .app directory (i.e.,
/// they should unzip to a Contents directory).
///
/// Asset changes will be in the `Assets.car` file (which is a combination of
/// the `.xcasset` catalogs in the Xcode project) and the `flutter_assets`
/// directory.
///
/// Native changes will appear in the Runner.app/Runner executable and non
///   Flutter.framework or App.framework files.
///
/// Dart changes will appear in the App.framework/App executable.
/// {@endtemplate}
class AppleArchiveDiffer extends ArchiveDiffer {
  /// {@macro apple_archive_differ}
  const AppleArchiveDiffer();

  String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  static final _binaryFilePatterns = {
    RegExp(r'App.framework/App$'),
    RegExp(r'Flutter.framework/Flutter$'),
  };

  /// The regex pattern for identifying app files within an xcarchive.
  static final RegExp xcFrameworkAppRegex = RegExp(
    r'^Products/Applications/[\w\-. ]+.app/[\w\- ]+$',
  );

  /// The regex pattern for identifying executable files within a macOS .app.
  static final RegExp macosAppRegex = RegExp(r'^Contents/MacOS/.+$');

  /// Files that have been added, removed, or that have changed between the
  /// archives at the two provided paths. This method will also unsign mach-o
  /// binaries in the archives before computing the diff.
  @override
  Future<FileSetDiff> changedFiles(
    String oldArchivePath,
    String newArchivePath,
  ) async {
    var oldPathHashes = await fileHashes(File(oldArchivePath));
    var newPathHashes = await fileHashes(File(newArchivePath));

    oldPathHashes = await _updateHashes(
      archivePath: oldArchivePath,
      pathHashes: oldPathHashes,
    );
    newPathHashes = await _updateHashes(
      archivePath: newArchivePath,
      pathHashes: newPathHashes,
    );

    return FileSetDiff.fromPathHashes(
      oldPathHashes: oldPathHashes,
      newPathHashes: newPathHashes,
    );
  }

  /// Replaces crc32s from zip file headers where needed. This currently
  /// includes:
  ///   - Signed files (those with a .app extension)
  ///   - Compiled asset catalogs (those with a .car extension)
  Future<PathHashes> _updateHashes({
    required String archivePath,
    required PathHashes pathHashes,
  }) async {
    return Isolate.run(() async {
      for (final file in _filesToUnsign(archivePath)) {
        pathHashes[file.name] = await _unsignedFileHash(file);
      }

      for (final file in _carFiles(archivePath)) {
        pathHashes[file.name] = await _carFileHash(file);
      }

      return pathHashes;
    });
  }

  List<ArchiveFile> _filesToUnsign(String archivePath) {
    return ZipDecoder()
        .decodeStream(InputFileStream(archivePath))
        .files
        .where((file) => file.isFile)
        .where(
          (file) =>
              _binaryFilePatterns.any(
                (pattern) => pattern.hasMatch(file.name),
              ) ||
              xcFrameworkAppRegex.hasMatch(file.name),
        )
        .toList();
  }

  List<ArchiveFile> _carFiles(String archivePath) {
    return ZipDecoder()
        .decodeStream(InputFileStream(archivePath))
        .files
        .where((file) => file.isFile && p.basename(file.name) == 'Assets.car')
        .toList();
  }

  Future<String> _unsignedFileHash(ArchiveFile file) async {
    final tempDir = Directory.systemTemp.createTempSync();
    final outPath = p.join(tempDir.path, file.name);
    final outputStream = OutputFileStream(outPath);
    file.writeContent(outputStream);
    await outputStream.close();

    if (Platform.isMacOS) {
      // coverage:ignore-start
      Process.runSync('codesign', ['--remove-signature', outPath]);
      // coverage:ignore-end
    }

    final outFile = File(outPath);
    final Uint8List bytes;
    if (MachO.isMachOFile(outFile)) {
      bytes = MachO.bytesWithZeroedUUID(outFile);
    } else {
      bytes = outFile.readAsBytesSync();
    }

    return _hash(bytes);
  }

  /// Uses assetutil to write a json description of a .car file to disk and
  /// diffs the contents of that file, less a timestamp line that changes based
  /// on when the .car file was created.
  Future<String> _carFileHash(ArchiveFile file) async {
    final tempDir = Directory.systemTemp.createTempSync();
    final outPath = p.join(tempDir.path, file.name);
    final outputStream = OutputFileStream(outPath);
    file.writeContent(outputStream);
    await outputStream.close();

    final assetInfoPath = '$outPath.json';

    if (Platform.isMacOS) {
      Process.runSync('assetutil', ['--info', outPath, '-o', assetInfoPath]);
    }

    // Remove the timestamp line from the json file
    final jsonFile = File(assetInfoPath);
    final lines = jsonFile.readAsLinesSync();
    final timestampRegex = RegExp(r'^\W+"Timestamp" : \d+$');
    final linesToKeep = lines.whereNot(timestampRegex.hasMatch);
    return _hash(linesToKeep.join('\n').codeUnits);
  }

  @override
  bool isAssetFilePath(String filePath) {
    /// The flutter_assets directory contains the assets listed in the assets
    ///   section of the pubspec.yaml file.
    /// Assets.car is the compiled asset catalog(s) (.xcassets files).
    return p.basename(filePath) == 'Assets.car' ||
        p.split(filePath).contains('flutter_assets');
  }

  @override
  bool isDartFilePath(String filePath) =>
      filePath.endsWith('App.framework/App');

  @override
  bool isNativeFilePath(String filePath) =>
      xcFrameworkAppRegex.hasMatch(filePath) ||
      macosAppRegex.hasMatch(filePath);
}
