import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/dependencies.dart';

/// An attachment's bytes for thumbnails and previews. Downloaded with the
/// user's token (works on every platform, including the web) and kept for a
/// few minutes after the last viewer, so scrolling does not refetch.
final attachmentBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, attachmentId) async {
  final bytes = await ref.read(attachmentRepositoryProvider).content(attachmentId);
  final link = ref.keepAlive();
  Timer? release;
  ref.onCancel(() => release = Timer(const Duration(minutes: 5), link.close));
  ref.onResume(() => release?.cancel());
  ref.onDispose(() => release?.cancel());
  return bytes;
});
