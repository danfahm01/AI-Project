import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// An image provider that decodes [bytes] at thumbnail resolution.
///
/// A 12-megapixel photo decodes to about 48 MB of pixels; a 160 px thumbnail
/// needs a small fraction of that. The image is scaled to fit a square twice the
/// displayed size, so `BoxFit.cover` stays sharp for aspect ratios up to 2:1.
/// Images smaller than that are decoded as they are (never upscaled).
ImageProvider thumbnailImage(Uint8List bytes, {required double size, required double devicePixelRatio}) {
  final pixels = (size * devicePixelRatio * 2).round();
  return ResizeImage(MemoryImage(bytes), width: pixels, height: pixels, policy: ResizeImagePolicy.fit);
}
