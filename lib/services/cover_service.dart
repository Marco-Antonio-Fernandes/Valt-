import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/library_item.dart';
import 'comic_page_source.dart';

bool _isSupportedImageMagic(Uint8List b) {
  if (b.length < 3) return false;
  if (b[0] == 0xff && b[1] == 0xd8) return true;
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47) {
    return true;
  }
  if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
    return true;
  }
  return false;
}

String _extForImageBytes(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8) return 'jpg';
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47) {
    return 'png';
  }
  if (b.length >= 12 && b[0] == 0x52) return 'webp';
  return 'img';
}

class CoverService {
  Future<Directory> _coversDir() async {
    final d = await getApplicationSupportDirectory();
    final sub = Directory(p.join(d.path, 'covers'));
    if (!sub.existsSync()) {
      sub.createSync(recursive: true);
    }
    return sub;
  }

  Future<String?> buildCover(LibraryItem item) async {
    try {
      final dir = await _coversDir();
      switch (item.format) {
        case BookFormat.pdf:
          await pdfrxFlutterInitialize();
          PdfDocument? doc;
          try {
            doc = await PdfDocument.openFile(
              item.filePath,
              useProgressiveLoading: false,
            );
            if (doc.pages.isEmpty) return null;
            var page = doc.pages[0];
            page = await page.ensureLoaded();
            // ~900 px de largura: suficiente para o cartão “Continuar a ler” em ecrãs densos.
            const maxW = 900.0;
            final fw = page.width;
            final fh = page.height;
            final fullH = fh * maxW / fw;
            final pdfImg = await page.render(
              fullWidth: maxW,
              fullHeight: fullH,
            );
            if (pdfImg == null) return null;
            final image = pdfImg.createImageNF(pixelSizeThreshold: 960);
            pdfImg.dispose();
            final jpg = im.encodeJpg(image, quality: 88);
            final out = p.join(dir.path, '${item.id}.jpg');
            await File(out).writeAsBytes(jpg);
            return out;
          } finally {
            if (doc != null) {
              await doc.dispose();
            }
          }
        case BookFormat.cbz:
        case BookFormat.cbr:
          final src = await ComicPageSource.open(item);
          try {
            final bytes = await src.pageAt(0);
            if (bytes.isEmpty || !_isSupportedImageMagic(bytes)) return null;
            final ext = _extForImageBytes(bytes);
            final name = ext == 'jpg' ? '${item.id}.jpg' : '${item.id}.$ext';
            final out = p.join(dir.path, name);
            await File(out).writeAsBytes(bytes);
            return out;
          } finally {
            await src.dispose();
          }
        case BookFormat.epub:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}
