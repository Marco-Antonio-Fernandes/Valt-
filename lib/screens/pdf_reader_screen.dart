import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/library_item.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
    super.key,
    required this.item,
    required this.onPagePersist,
    this.nextIssue,
    this.onOpenNext,
  });

  final LibraryItem item;
  final void Function(int lastPageIndex, {int? totalPages}) onPagePersist;
  final LibraryItem? nextIssue;
  final VoidCallback? onOpenNext;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  int? _current;
  int? _docPageCount;

  @override
  void initState() {
    super.initState();
    _current = widget.item.lastPageIndex + 1;
    _docPageCount = widget.item.totalPages;
  }

  @override
  Widget build(BuildContext context) {
    final initial = (widget.item.lastPageIndex + 1).clamp(1, 1 << 20);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && _current != null) {
          widget.onPagePersist(
            _current! - 1,
            totalPages: _docPageCount,
          );
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.item.displayName),
              if (_current != null)
                Text(
                  'Página $_current',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                ),
            ],
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            PdfViewer.file(
              widget.item.filePath,
              initialPageNumber: initial,
              params: PdfViewerParams(
                backgroundColor: Colors.black,
                onDocumentChanged: (doc) {
                  if (doc != null) {
                    final t = doc.pages.length;
                    setState(() => _docPageCount = t);
                    if (_current != null) {
                      widget.onPagePersist(
                        _current! - 1,
                        totalPages: t,
                      );
                    }
                  }
                },
                onPageChanged: (n) {
                  if (n != null) {
                    setState(() => _current = n);
                    widget.onPagePersist(
                      n - 1,
                      totalPages: _docPageCount,
                    );
                  }
                },
              ),
            ),
            if (widget.nextIssue != null &&
                widget.onOpenNext != null &&
                _current != null &&
                _docPageCount != null &&
                _current! >= _docPageCount!)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: SafeArea(
                  child: FilledButton.icon(
                    onPressed: widget.onOpenNext,
                    icon: const Icon(Icons.navigate_next_rounded),
                    label: Text(
                      'Próximo · ${widget.nextIssue!.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
