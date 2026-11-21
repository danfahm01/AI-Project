import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/thumbnail_image.dart';
import '../../../../domain/entities/attachment.dart';
import '../../../../providers/dependencies.dart';
import '../../application/attachment_providers.dart';

/// Images (thumbnails; tap to view) and PDFs (tap to open) sent with a message.
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({super.key, required this.attachments, this.alignEnd = true});

  final List<Attachment> attachments;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final attachment in attachments)
            attachment.isImage
                ? _ImageThumbnail(key: ValueKey(attachment.id), attachment: attachment)
                : _PdfChip(key: ValueKey(attachment.id), attachment: attachment),
        ],
      ),
    );
  }
}

const double _thumbnailSize = 160;

class _ImageThumbnail extends ConsumerWidget {
  const _ImageThumbnail({super.key, required this.attachment});

  final Attachment attachment;

  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(
                  child: _AttachmentImage(attachment: attachment, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Image ${attachment.filename}. Open',
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          child: SizedBox.square(
            dimension: _thumbnailSize,
            child: _AttachmentImage(attachment: attachment, fit: BoxFit.cover, thumbnailSize: _thumbnailSize),
          ),
        ),
      ),
    );
  }
}

class _AttachmentImage extends ConsumerWidget {
  const _AttachmentImage({required this.attachment, required this.fit, this.thumbnailSize});

  final Attachment attachment;
  final BoxFit fit;

  /// Decode at this logical size (thumbnails); null = full resolution (zoomable viewer).
  final double? thumbnailSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ref
        .watch(attachmentBytesProvider(attachment.id))
        .when(
          loading: () =>
              const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          error: (error, _) => Tooltip(
            message: "Couldn't load ${attachment.filename}",
            child: Center(child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant)),
          ),
          data: (bytes) => Image(
            image: switch (thumbnailSize) {
              final size? => thumbnailImage(
                bytes,
                size: size,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
              null => MemoryImage(bytes),
            },
            fit: fit,
            gaplessPlayback: true,
            semanticLabel: attachment.filename,
            errorBuilder: (_, _, _) => Center(child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant)),
          ),
        );
  }
}

class _PdfChip extends ConsumerWidget {
  const _PdfChip({super.key, required this.attachment});

  final Attachment attachment;

  Future<void> _open(BuildContext context, WidgetRef ref) => runGuarded(context, () async {
    // A short-lived signed link: the browser or the system PDF viewer opens it
    // without the app's token.
    final link = await ref.read(attachmentRepositoryProvider).link(attachment.id);
    final opened = await launchUrl(link, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) showInfoSnackBar(context, 'No app is available to open PDFs.');
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context, ref),
        child: Tooltip(
          message: 'Open ${attachment.filename}',
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.picture_as_pdf_outlined, color: scheme.error),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                      Text(
                        'PDF · ${formatFileSize(attachment.sizeBytes)}',
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.open_in_new_rounded, size: 16, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
