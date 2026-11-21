import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;

import '../../domain/entities/attachment.dart';

/// Chooses files to attach. Faked in tests.
abstract interface class AttachmentPicker {
  /// Whether [takePhoto] can open a camera on this device.
  bool get canTakePhoto;

  Future<List<PickedFile>> pickImages();

  Future<List<PickedFile>> pickPdfs();

  Future<PickedFile?> takePhoto();
}

/// `file_picker` (all platforms, including the web) for images and PDFs, and
/// `image_picker` for the camera on Android and iOS.
class DeviceAttachmentPicker implements AttachmentPicker {
  final _images = ImagePicker();

  @override
  bool get canTakePhoto =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) &&
      _images.supportsImageSource(ImageSource.camera);

  Future<List<PickedFile>> _pick(List<String> extensions) async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: extensions);
    return [for (final file in files) PickedFile(name: file.name, bytes: await file.readAsBytes())];
  }

  @override
  Future<List<PickedFile>> pickImages() => _pick(const ['png', 'jpg', 'jpeg', 'webp']);

  @override
  Future<List<PickedFile>> pickPdfs() => _pick(const ['pdf']);

  @override
  Future<PickedFile?> takePhoto() async {
    // Downscaled and re-encoded as JPEG: phone photos are often above the upload limit.
    final photo = await _images.pickImage(source: ImageSource.camera, maxWidth: 2048, imageQuality: 85);
    if (photo == null) return null;
    final name = photo.name.toLowerCase().endsWith('.jpg') ? photo.name : 'photo.jpg';
    return PickedFile(name: name, bytes: await photo.readAsBytes());
  }
}
