import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 按「METHOD 路径前缀」匹配返回预置响应的 dio 适配器，供单测离线复现服务端行为。
class FakeAdapter implements HttpClientAdapter {
  /// key 形如 'GET /emby/Users/u1/Views'，按注册顺序前缀匹配。
  final Map<String, Object> routes;
  final List<RequestOptions> requests = [];

  FakeAdapter(this.routes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.uri.path}';
    for (final entry in routes.entries) {
      if (key.startsWith(entry.key)) {
        final body = entry.value;
        final text = body is String ? body : jsonEncode(body);
        return ResponseBody.fromString(
          text,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
    }
    return ResponseBody.fromString('{"error":"no fake route for $key"}', 404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}
