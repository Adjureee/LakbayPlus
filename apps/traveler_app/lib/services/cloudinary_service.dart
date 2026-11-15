import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class CloudinaryUploadResult {
  final String secureUrl;
  final String publicId;
  final int bytes;
  final int? width;
  final int? height;
  final String? format;

  const CloudinaryUploadResult({
    required this.secureUrl,
    required this.publicId,
    required this.bytes,
    this.width,
    this.height,
    this.format,
  });
}

/// Cloudinary media client modeled on Lakbay's `CloudinaryStorageClient`.
/// Reads `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`,
/// and `CLOUDINARY_UPLOAD_PRESET` from [EnvConfig].
class CloudinaryService {
  final http.Client _httpClient;

  CloudinaryService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  String get cloudName => EnvConfig.cloudinaryCloudName.trim();
  String get apiKey => EnvConfig.cloudinaryApiKey.trim();
  String get uploadPreset => EnvConfig.cloudinaryUploadPreset.trim();

  bool get isConfigured => EnvConfig.hasCloudinaryConfig;

  /// Builds an optimized Cloudinary delivery URL (`f_auto,q_auto`) for a publicId.
  /// If [publicIdOrUrl] is already an HTTP(S) URL, returns it as-is.
  String buildImageUrl(
    String publicIdOrUrl, {
    int? width,
    int? height,
    String crop = 'fill',
  }) {
    final trimmed = publicIdOrUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (cloudName.isEmpty || trimmed.isEmpty) {
      return trimmed;
    }
    final transforms = <String>['f_auto', 'q_auto'];
    if (width != null) transforms.add('w_$width');
    if (height != null) transforms.add('h_$height');
    if (width != null || height != null) transforms.add('c_$crop');

    final cleanId = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    return 'https://res.cloudinary.com/$cloudName/image/upload/${transforms.join(',')}/$cleanId';
  }

  /// Uploads raw image bytes to Cloudinary using an unsigned `CLOUDINARY_UPLOAD_PRESET`.
  Future<CloudinaryUploadResult> uploadImageBytes(
    Uint8List bytes, {
    required String filename,
    String folder = 'Lakbay+/davao',
  }) async {
    if (cloudName.isEmpty) {
      throw StateError(
        'CLOUDINARY_CLOUD_NAME is not configured in .env.',
      );
    }
    if (uploadPreset.isEmpty) {
      throw StateError(
        'CLOUDINARY_UPLOAD_PRESET is required for client-side Cloudinary uploads in .env.',
      );
    }

    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/$cloudName/image/upload',
    );
    final request = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = uploadPreset
      ..fields['folder'] = folder
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
        ),
      );

    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Cloudinary upload failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final secureUrl =
        (decoded['secure_url'] ?? decoded['url'] ?? '').toString();
    if (secureUrl.isEmpty) {
      throw StateError('Cloudinary upload did not return a secure_url.');
    }

    return CloudinaryUploadResult(
      secureUrl: secureUrl,
      publicId: (decoded['public_id'] ?? '').toString(),
      bytes: (decoded['bytes'] as num?)?.toInt() ?? bytes.length,
      width: (decoded['width'] as num?)?.toInt(),
      height: (decoded['height'] as num?)?.toInt(),
      format: decoded['format']?.toString(),
    );
  }
}
