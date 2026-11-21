import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/layout/breakpoints.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/thumbnail_image.dart';
import '../../../../domain/entities/attachment.dart';
import '../../../../providers/dependencies.dart';

/// A file in the composer: uploading, uploaded ([attachment] set) or failed.
class _Upload {
  _Upload(this.file, this.kind);

  final PickedFile file;
  final AttachmentKind kind;
  final key = UniqueKey();
  double progress = 0;
  Attachment? attachment;
  String? error;

  bool get uploading => attachment == null && error == null;
}

/// Message input with attachments. Enter sends, Shift+Enter inserts a newline,
/// and Enter while an IME composition is active confirms the composition.
///
/// Files are uploaded as soon as they are chosen; the message is sent with their
/// ids. Only the kinds the selected model reads can be attached.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    required this.onOpenVoice,
    this.isGenerating = false,
    this.onStop,
    this.acceptImages = false,
    this.acceptPdfs = false,
    this.modelName,
    this.autofocus = true,
  });

  /// Throws [ApiException] if the message could not be accepted; the text and
  /// attachments are then restored.
  final Future<void> Function(String text, List<Attachment> attachments) onSend;
  final VoidCallback onOpenVoice;

  /// While a reply streams, the send button becomes a stop button.
  final bool isGenerating;
  final VoidCallback? onStop;

  /// What the selected model reads (from its capabilities).
  final bool acceptImages;
  final bool acceptPdfs;
  final String? modelName;
  final bool autofocus;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode(debugLabel: 'composer');
  final _uploads = <_Upload>[];
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _accepts(AttachmentKind kind) => kind == AttachmentKind.image ? widget.acceptImages : widget.acceptPdfs;

  /// Why sending is blocked by the attachments, if it is.
  String? get _attachmentProblem {
    if (_uploads.any((u) => u.uploading)) return 'Wait for the uploads to finish';
    if (_uploads.any((u) => u.error != null)) return 'Remove the files that could not be uploaded';
    if (_uploads.any((u) => !_accepts(u.kind))) {
      return "${widget.modelName ?? 'The selected model'} can't read some of these files. Remove them or choose another model.";
    }
    return null;
  }

  bool get _canSend =>
      !_busy &&
      !widget.isGenerating &&
      _attachmentProblem == null &&
      (_controller.text.trim().isNotEmpty || _uploads.isNotEmpty);

  Future<void> _submit() async {
    if (!_canSend) return;
    final text = _controller.text;
    final uploads = List<_Upload>.of(_uploads);
    _controller.clear();
    setState(() {
      _busy = true;
      _uploads.clear();
    });
    try {
      await widget.onSend(text, [for (final upload in uploads) upload.attachment!]);
    } on ApiException catch (error) {
      if (!mounted) return;
      _controller.text = text;
      setState(() => _uploads.insertAll(0, uploads));
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _focusNode.requestFocus();
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed || _controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    _submit();
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- attachments

  Future<void> _choose(Future<List<PickedFile>> Function() pick) async {
    final List<PickedFile> files;
    try {
      files = await pick();
    } catch (error) {
      if (mounted) showInfoSnackBar(context, 'Could not open the file picker: $error');
      return;
    }
    _add(files);
  }

  void _add(List<PickedFile> files) {
    final problems = <String>[];
    for (final file in files) {
      final kind = file.kind;
      if (kind == null) {
        problems.add('${file.name} is not a PNG, JPEG or WEBP image or a PDF.');
      } else if (!_accepts(kind)) {
        problems.add(
          "${widget.modelName ?? 'The selected model'} can't read ${kind == AttachmentKind.pdf ? 'PDFs' : 'images'}.",
        );
      } else if (file.bytes.length > AttachmentLimits.maxBytes) {
        problems.add('${file.name} is larger than ${formatFileSize(AttachmentLimits.maxBytes)}.');
      } else if (_uploads.length >= AttachmentLimits.perMessage) {
        problems.add('At most ${AttachmentLimits.perMessage} files can be sent with one message.');
        break;
      } else {
        final upload = _Upload(file, kind);
        setState(() => _uploads.add(upload));
        unawaited(_upload(upload));
      }
    }
    if (problems.isNotEmpty && mounted) showInfoSnackBar(context, problems.toSet().join(' '));
  }

  Future<void> _upload(_Upload upload) async {
    try {
      final attachment = await ref
          .read(attachmentRepositoryProvider)
          .upload(
            upload.file,
            onProgress: (progress) {
              if (mounted) setState(() => upload.progress = progress);
            },
          );
      if (!mounted) return;
      if (!_uploads.contains(upload)) {
        // Removed while uploading.
        unawaited(ref.read(attachmentRepositoryProvider).delete(attachment.id).catchError((Object _) {}));
        return;
      }
      setState(() => upload.attachment = attachment);
    } on ApiException catch (error) {
      if (mounted) setState(() => upload.error = error.userMessage);
    }
  }

  void _remove(_Upload upload) {
    setState(() => _uploads.remove(upload));
    final attachment = upload.attachment;
    if (attachment != null) {
      unawaited(ref.read(attachmentRepositoryProvider).delete(attachment.id).catchError((Object _) {}));
    }
  }

  Widget _attachButton() {
    final picker = ref.watch(attachmentPickerProvider);
    if (!widget.acceptImages && !widget.acceptPdfs) {
      return IconButton(
        tooltip: "${widget.modelName ?? 'The selected model'} doesn't accept images or PDFs",
        icon: const Icon(Icons.add_rounded),
        onPressed: null,
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Attach images or PDFs',
      icon: const Icon(Icons.add_rounded),
      enabled: !_busy && _uploads.length < AttachmentLimits.perMessage,
      onSelected: (choice) => switch (choice) {
        'images' => _choose(picker.pickImages),
        'pdfs' => _choose(picker.pickPdfs),
        _ => _choose(() async => [?await picker.takePhoto()]),
      },
      itemBuilder: (context) => [
        if (widget.acceptImages)
          const PopupMenuItem(
            value: 'images',
            child: ListTile(leading: Icon(Icons.image_outlined), title: Text('Images')),
          ),
        if (widget.acceptPdfs)
          const PopupMenuItem(
            value: 'pdfs',
            child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('PDF documents')),
          ),
        if (widget.acceptImages && picker.canTakePhoto)
          const PopupMenuItem(
            value: 'camera',
            child: ListTile(leading: Icon(Icons.photo_camera_outlined), title: Text('Take a photo')),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = _attachmentProblem;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.contentMaxWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_uploads.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                      child: SizedBox(
                        height: 72,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final upload in _uploads)
                              _UploadChip(
                                key: upload.key,
                                upload: upload,
                                unsupported: !_accepts(upload.kind),
                                onRemove: () => _remove(upload),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Focus(
                    onKeyEvent: _onKeyEvent,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: widget.autofocus,
                      minLines: 1,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Message the assistant',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _attachButton(),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Voice mode',
                        icon: const Icon(Icons.graphic_eq_rounded),
                        onPressed: widget.onOpenVoice,
                      ),
                      const SizedBox(width: 4),
                      if (widget.isGenerating)
                        IconButton.filled(
                          tooltip: 'Stop generating',
                          icon: const Icon(Icons.stop_rounded),
                          onPressed: widget.onStop,
                        )
                      else
                        IconButton.filled(
                          tooltip: problem ?? 'Send (Enter)',
                          icon: _busy
                              ? SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                                )
                              : const Icon(Icons.arrow_upward_rounded),
                          onPressed: _canSend ? _submit : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadChip extends StatelessWidget {
  const _UploadChip({super.key, required this.upload, required this.unsupported, required this.onRemove});

  final _Upload upload;
  final bool unsupported;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = upload.error != null || unsupported;
    final isImage = upload.kind == AttachmentKind.image;
    final tooltip = upload.error ?? (unsupported ? "The selected model can't read this file" : upload.file.name);

    final preview = isImage
        ? Image(
            image: thumbnailImage(
              upload.file.bytes,
              size: 64,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : Container(
            width: 168,
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            color: scheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(Icons.picture_as_pdf_outlined, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        upload.file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        formatFileSize(upload.file.bytes.length),
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 4),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          label: '${isImage ? 'Image' : 'PDF'} ${upload.file.name}${upload.uploading ? ', uploading' : ''}',
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: failed ? scheme.error : scheme.outlineVariant, width: failed ? 2 : 1),
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(11), child: preview),
              ),
              if (upload.uploading)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        value: upload.progress > 0 && upload.progress < 1 ? upload.progress : null,
                      ),
                    ),
                  ),
                ),
              if (upload.error != null) Positioned.fill(child: Icon(Icons.error_outline_rounded, color: scheme.error)),
              Positioned(
                top: -6,
                right: -6,
                child: Tooltip(
                  message: 'Remove',
                  child: Material(
                    color: scheme.inverseSurface,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onRemove,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close_rounded, size: 14, color: scheme.onInverseSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
