import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/fixed_name_web_assets.dart';

void main() {
  late Directory web;

  setUp(() {
    web = Directory.systemTemp.createTempSync('web_build_');
  });

  tearDown(() {
    web.deleteSync(recursive: true);
  });

  File write(String path, String content) {
    final file = File('${web.path}/$path')..createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  test('plugin scripts get their unhashed name next to the hashed file', () {
    write('assets/packages/record_web/assets/js/record.worklet.21b830de.js', '// worklet');
    write('assets/packages/mp_audio_stream/js/audio_stream.62777f05.js', '// player');
    write('assets/packages/some_plugin/module.0123abcd.mjs', '// module');

    final created = addFixedNameCopies(web);

    expect(created, [
      'assets/packages/mp_audio_stream/js/audio_stream.js',
      'assets/packages/record_web/assets/js/record.worklet.js',
      'assets/packages/some_plugin/module.mjs',
    ]);
    expect(File('${web.path}/assets/packages/record_web/assets/js/record.worklet.js').readAsStringSync(), '// worklet');
    // The hashed originals stay: the build's own references point to them.
    expect(File('${web.path}/assets/packages/record_web/assets/js/record.worklet.21b830de.js').existsSync(), isTrue);
  });

  test('other files are left alone', () {
    write('assets/packages/cupertino_icons/assets/CupertinoIcons.9d8d1c5e.ttf', 'font');
    write('assets/packages/plain/script.js', '// no hash');
    write('assets/fonts/MaterialIcons-Regular.f8a0c9c7.otf', 'font');

    expect(addFixedNameCopies(web), isEmpty);
    expect(File('${web.path}/assets/packages/cupertino_icons/assets/CupertinoIcons.ttf').existsSync(), isFalse);
  });

  test('a build without plugin assets has nothing to copy', () {
    write('index.html', '<!doctype html>');

    expect(addFixedNameCopies(web), isEmpty);
  });

  test('running it twice gives the same result', () {
    write('assets/packages/record_web/assets/js/record.worklet.21b830de.js', '// worklet');

    addFixedNameCopies(web);

    expect(addFixedNameCopies(web), ['assets/packages/record_web/assets/js/record.worklet.js']);
  });
}
