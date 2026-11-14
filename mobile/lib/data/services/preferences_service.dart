import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class AppConfig {
  static const String defaultBaseUrl = 'https://yt.quantumsofts.com';
  static const String localLanBaseUrl = 'http://192.168.1.5:8000';
}

/// Persists client ID, server URL, premium password, theme, and local transfer state.
class PreferencesService {
  PreferencesService({this._prefs});

  static const _kClientId = 'ytd_client_id';
  static const _kBaseUrl = 'ytd_base_url';
  static const _kPremiumPassword = 'ytd_premium_password';
  static const _kAutoDownload = 'ytd_auto_download';
  static const _kThemeMode = 'ytd_theme_mode';
  static const _kLocalTransfers = 'ytd_local_transfers';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _store() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  static String normalizeBaseUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return AppConfig.defaultBaseUrl;
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static String generateUuidV4([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<String> getOrCreateClientId() async {
    final prefs = await _store();
    final existing = prefs.getString(_kClientId);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }
    final generated = generateUuidV4();
    await prefs.setString(_kClientId, generated);
    return generated;
  }

  Future<String> getBaseUrl() async {
    final prefs = await _store();
    return normalizeBaseUrl(prefs.getString(_kBaseUrl) ?? AppConfig.defaultBaseUrl);
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await _store();
    await prefs.setString(_kBaseUrl, normalizeBaseUrl(url));
  }

  Future<String> getPremiumPassword() async {
    final prefs = await _store();
    return prefs.getString(_kPremiumPassword) ?? '';
  }

  Future<void> setPremiumPassword(String password) async {
    final prefs = await _store();
    await prefs.setString(_kPremiumPassword, password);
  }

  Future<bool> getAutoDownload() async {
    final prefs = await _store();
    return prefs.getBool(_kAutoDownload) ?? true;
  }

  Future<void> setAutoDownload(bool enabled) async {
    final prefs = await _store();
    await prefs.setBool(_kAutoDownload, enabled);
  }

  Future<ThemeMode> getThemeMode() async {
    final prefs = await _store();
    final raw = prefs.getString(_kThemeMode) ?? 'system';
    return ThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await _store();
    await prefs.setString(_kThemeMode, mode.name);
  }

  Future<List<LocalTransferItem>> getLocalTransfers() async {
    final prefs = await _store();
    final raw = prefs.getString(_kLocalTransfers);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(LocalTransferItem.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLocalTransfers(List<LocalTransferItem> items) async {
    final prefs = await _store();
    final encoded = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_kLocalTransfers, encoded);
  }
}
