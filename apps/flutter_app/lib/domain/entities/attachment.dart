import 'dart:typed_data';

enum AttachmentKind { image, pdf }

/// A file uploaded to the server (pending until sent with a message).
class Attachment {
  const Attachment({
    required this.id,
    required this.kind,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
    this.messageId,
  });

  final String id;
  final AttachmentKind kind;
  final String filename;
  final String contentType;
  final int sizeBytes;

  /// Set once the attachment was sent with a message.
  final String? messageId;

  bool get isImage => kind == AttachmentKind.image;
}

/// A file chosen on the device, before upload.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  /// What the server accepts, judged by the first bytes (the server checks again).
  AttachmentKind? get kind => attachmentKindOf(bytes);
}

/// PNG, JPEG, WEBP or PDF by magic number; `null` for anything else.
AttachmentKind? attachmentKindOf(Uint8List bytes) {
  bool startsWith(List<int> prefix) =>
      bytes.length >= prefix.length && [for (var i = 0; i < prefix.length; i++) bytes[i] == prefix[i]].every((b) => b);
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return AttachmentKind.image;
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return AttachmentKind.image;
  if (bytes.length >= 12 &&
      startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return AttachmentKind.image;
  }
  if (startsWith(const [0x25, 0x50, 0x44, 0x46, 0x2D])) return AttachmentKind.pdf;
  return null;
}

/// Limits mirrored from the server defaults so problems show before uploading
/// (`ATTACHMENT_MAX_BYTES`, `ATTACHMENTS_PER_MESSAGE`); the server enforces them.
abstract final class AttachmentLimits {
  static const maxBytes = 10 * 1024 * 1024;
  static const perMessage = 5;
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
