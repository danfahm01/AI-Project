import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/core/config/app_config.dart';
import 'package:voice_assistant/core/widgets/thumbnail_image.dart';

void main() {
  group('API base URL', () {
    final page = Uri.parse('https://assistant.example.com/#/chat/42');

    String resolve(String define, {bool isWeb = false, TargetPlatform platform = TargetPlatform.windows}) =>
        AppConfig.resolveApiBaseUrl(define, isWeb: isWeb, platform: platform, pageUri: page);

    test('a full URL is used as given, without a trailing slash', () {
      expect(resolve('https://api.example.com/'), 'https://api.example.com');
      expect(resolve(' https://api.example.com '), 'https://api.example.com');
    });

    test('on the web, a path means the origin that served the page', () {
      expect(resolve('/', isWeb: true), 'https://assistant.example.com');
      expect(resolve('/assistant/', isWeb: true), 'https://assistant.example.com/assistant');
    });

    test('a path is rejected outside the web', () {
      expect(() => resolve('/'), throwsArgumentError);
    });

    test('development defaults', () {
      expect(resolve(''), 'http://localhost:8000');
      expect(resolve('', isWeb: true), 'http://localhost:8000');
      expect(resolve('', platform: TargetPlatform.android), 'http://10.0.2.2:8000');
    });

    test('derived endpoints', () {
      const config = AppConfig(apiBaseUrl: 'https://assistant.example.com');
      expect(config.apiV1Url, 'https://assistant.example.com/api/v1');
      expect(config.readinessUrl, 'https://assistant.example.com/health/ready');
    });
  });

  test('thumbnails decode at a bounded size', () {
    final provider = thumbnailImage(Uint8List(8), size: 160, devicePixelRatio: 2) as ResizeImage;
    expect((provider.width, provider.height), (640, 640));
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(provider.allowUpscaling, isFalse);
  });
}
