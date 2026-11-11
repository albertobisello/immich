import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Longest side of the decoded source, to bound memory use on 50+ MP photos (~70 MB of pixels)
const _maxDecodeSide = 4800;

/// Longest side of the crop sent to the TV
const _maxOutputSide = 3840;

/// Renders the part of [source] (an encoded image) inside [crop], given in normalized
/// coordinates (0..1) of the image as displayed, and returns it as a JPEG.
///
/// Used to mirror the phone's zoom on a DLNA TV, which can only show whole images.
Future<Uint8List> renderCastCrop(Uint8List source, ui.Rect crop) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(source);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      final scale = math.min(1.0, _maxDecodeSide / math.max(width, height));
      // only the width: the decoder keeps the aspect ratio (and the EXIF orientation)
      return ui.TargetImageSize(width: (width * scale).round());
    },
  );
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;

  try {
    final src = ui.Rect.fromLTRB(
      (crop.left * image.width).clamp(0, image.width.toDouble()),
      (crop.top * image.height).clamp(0, image.height.toDouble()),
      (crop.right * image.width).clamp(0, image.width.toDouble()),
      (crop.bottom * image.height).clamp(0, image.height.toDouble()),
    );
    if (src.width < 1 || src.height < 1) {
      throw ArgumentError.value(crop, 'crop', 'empty crop');
    }

    final outScale = math.min(1.0, _maxOutputSide / math.max(src.width, src.height));
    final outWidth = math.max(1, (src.width * outScale).round());
    final outHeight = math.max(1, (src.height * outScale).round());

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      src,
      ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(outWidth, outHeight);
    picture.dispose();

    final rgba = await cropped.toByteData(format: ui.ImageByteFormat.rawRgba);
    cropped.dispose();
    if (rgba == null) {
      throw StateError('Failed to read the cropped pixels');
    }

    // dart:ui can only encode PNG, which is slow and huge for photos: encode a JPEG off the UI isolate
    final pixels = rgba.buffer.asUint8List();
    return await compute(_encodeJpeg, (pixels: pixels, width: outWidth, height: outHeight));
  } finally {
    image.dispose();
  }
}

Uint8List _encodeJpeg(({Uint8List pixels, int width, int height}) frame) {
  final image = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.pixels.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image, quality: 90);
}
