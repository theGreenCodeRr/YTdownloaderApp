import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'preferences_service.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// REST client for the FastAPI YT Downloader backend.
class ApiService {
  ApiService({
    http.Client? client,
    String baseUrl = AppConfig.defaultBaseUrl,
    this._clientId = 'mobile',
  })  : _client = client ?? http.Client(),
        _baseUrl = PreferencesService.normalizeBaseUrl(baseUrl);

  final http.Client _client;
  String _baseUrl;
  String _clientId;

  String get baseUrl => _baseUrl;
  String get clientId => _clientId;

  void configure({String? baseUrl, String? clientId}) {
    if (baseUrl != null) {
      _baseUrl = PreferencesService.normalizeBaseUrl(baseUrl);
    }
    if (clientId != null && clientId.trim().isNotEmpty) {
      _clientId = clientId.trim();
    }
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Client-ID': _clientId,
      };

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Uri downloadUri(String taskId) => _uri('/api/download/$taskId');

  Never _throwError(http.Response response) {
    var detail = 'Server error (${response.statusCode})';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['detail'] is String) {
        detail = decoded['detail'] as String;
      }
    } catch (_) {
      if (response.body.isNotEmpty && response.body.length < 240) {
        detail = response.body;
      }
    }
    throw ApiException(response.statusCode, detail);
  }

  Future<HealthInfo> fetchHealth() async {
    final response = await _client
        .get(_uri('/api/health'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) _throwError(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return HealthInfo.fromJson(decoded);
  }

  Future<MediaInfo> fetchMediaInfo(String url) async {
    final trimmedUrl = url.trim();
    final response = await _client
        .post(
          _uri('/api/info'),
          headers: _headers,
          body: jsonEncode({'url': trimmedUrl}),
        )
        .timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) _throwError(response);

    // Offload large playlist JSON decoding to an isolate to keep UI smooth.
    if (response.body.length > 50000) {
      return compute(parseMediaInfoPayload, {
        'body': response.body,
        'sourceUrl': trimmedUrl,
      });
    }
    return parseMediaInfoPayload({
      'body': response.body,
      'sourceUrl': trimmedUrl,
    });
  }

  Future<String> startSingleProcess({
    required String url,
    required String formatId,
    required String title,
    String thumbnail = '',
  }) async {
    final response = await _client
        .post(
          _uri('/api/process'),
          headers: _headers,
          body: jsonEncode({
            'url': url,
            'format_id': formatId,
            'title': title,
            'thumbnail': thumbnail,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 && response.statusCode != 201) {
      _throwError(response);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['task_id'] as String;
  }

  Future<String> startPlaylistProcess({
    required String url,
    required String formatId,
    required String title,
    required String password,
    List<PlaylistProcessItem>? items,
  }) async {
    final response = await _client
        .post(
          _uri('/api/process_playlist'),
          headers: _headers,
          body: jsonEncode({
            'url': url,
            'password': password,
            'format_id': formatId,
            'title': title,
            'items': items?.map((e) => e.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 && response.statusCode != 201) {
      _throwError(response);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['task_id'] as String;
  }

  Future<TaskStatusInfo> fetchTaskStatus(
    String taskId, {
    TaskStatusInfo? existing,
  }) async {
    final response = await _client
        .get(_uri('/api/status/$taskId'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) _throwError(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return TaskStatusInfo.fromStatusJson(decoded, existing: existing);
  }

  Future<List<TaskStatusInfo>> fetchRecentTasks() async {
    final response = await _client
        .get(_uri('/api/recent'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) _throwError(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final rawList = (decoded['recent'] as List<dynamic>?) ?? const [];
    return rawList
        .whereType<Map<String, dynamic>>()
        .map(TaskStatusInfo.fromRecentJson)
        .toList();
  }

  Future<void> cancelTask(String taskId) async {
    final response = await _client
        .post(_uri('/api/cancel/$taskId'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) _throwError(response);
  }

  Future<int> clearRecentHistory() async {
    final response = await _client
        .post(_uri('/api/recent/clear'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) _throwError(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return (decoded['cleared'] as num?)?.toInt() ?? 0;
  }
}
