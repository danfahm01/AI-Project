// Gives plugin scripts back their original names after a content-hashed web build.
//
// `flutter build web --web-content-hash` renames every file under assets/ to
// name.<hash>.ext. Flutter's own asset loading follows the new names, but some
// plugins load their JavaScript from a fixed path, and voice mode then fails
// with a 404 in the browser:
//
//   record_web       assets/packages/record_web/assets/js/record.worklet.js  (microphone)
//   mp_audio_stream  assets/packages/mp_audio_stream/js/audio_stream.js      (playback)
//
// This copies every hashed .js/.mjs file under assets/packages/ to its name
// without the hash. The copies keep their name when their content changes, so
// servers must revalidate them (no-cache) instead of caching them forever.
//
// Run it after every web build, from apps/flutter_app:
//
//   dart run tool/fixed_name_web_assets.dart [build/web]

import 'dart:io';

final _hashedScript = RegExp(r'^(.+)\.[0-9a-f]{8,}(\.m?js)$');

/// Copies each hashed script under [webDir]/assets/packages to its unhashed
/// name and returns the copies' paths relative to [webDir] ('/' separated).
List<String> addFixedNameCopies(Directory webDir) {
  final packages = Directory('${webDir.path}/assets/packages');
  if (!packages.existsSync()) return const [];
  final created = <String>[];
  final files = packages.listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final match = _hashedScript.firstMatch(file.uri.pathSegments.last);
    if (match == null) continue;
    final copy = file.copySync('${file.parent.path}/${match[1]}${match[2]}');
    created.add(copy.path.substring(webDir.path.length + 1).replaceAll(r'\', '/'));
  }
  return created;
}

void main(List<String> args) {
  final webDir = Directory(args.isEmpty ? 'build/web' : args.first);
  if (!File('${webDir.path}/index.html').existsSync()) {
    stderr.writeln('No web build in ${webDir.path}: run flutter build web first.');
    exit(1);
  }
  for (final path in addFixedNameCopies(webDir)) {
    stdout.writeln('Fixed name: $path');
  }
}
