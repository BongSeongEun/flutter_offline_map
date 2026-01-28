import 'dart:io';
import 'package:flutter/services.dart';

class DeviceProfile {
  final int cpuCores;
  final int memoryClassMb;
  final int largeMemoryClassMb;
  final int totalRamMb;
  final List<String> abis;

  const DeviceProfile({
    required this.cpuCores,
    required this.memoryClassMb,
    required this.largeMemoryClassMb,
    required this.totalRamMb,
    required this.abis,
  });

  factory DeviceProfile.fromMap(Map<dynamic, dynamic> map) {
    return DeviceProfile(
      cpuCores: (map['cpuCores'] ?? 0) as int,
      memoryClassMb: (map['memoryClassMb'] ?? 0) as int,
      largeMemoryClassMb: (map['largeMemoryClassMb'] ?? 0) as int,
      totalRamMb: (map['totalRamMb'] ?? 0) as int,
      abis: (map['abis'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
}

class LlmTuningPreset {
  final String name;
  final int maxTokens;
  final int topK;
  final int promptMaxChars;

  const LlmTuningPreset({
    required this.name,
    required this.maxTokens,
    required this.topK,
    required this.promptMaxChars,
  });
}

class LlmTuningService {
  static const MethodChannel _channel = MethodChannel('mediapipe_gemma');
  static const List<LlmTuningPreset> _presets = [
    LlmTuningPreset(
      name: 'low',
      maxTokens: 256,
      topK: 20,
      promptMaxChars: 800,
    ),
    LlmTuningPreset(
      name: 'mid',
      maxTokens: 512,
      topK: 40,
      promptMaxChars: 1200,
    ),
    LlmTuningPreset(
      name: 'high',
      maxTokens: 768,
      topK: 60,
      promptMaxChars: 1600,
    ),
  ];

  Future<DeviceProfile> loadDeviceProfile() async {
    if (!Platform.isAndroid) {
      return const DeviceProfile(
        cpuCores: 4,
        memoryClassMb: 256,
        largeMemoryClassMb: 512,
        totalRamMb: 4096,
        abis: ['unknown'],
      );
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getDeviceProfile',
    );
    if (result == null) {
      throw Exception('기기 프로필을 가져오지 못했습니다.');
    }
    return DeviceProfile.fromMap(result);
  }

  LlmTuningPreset choosePreset(DeviceProfile profile) {
    final totalRamGb = profile.totalRamMb / 1024.0;
    if (totalRamGb <= 4.0 || profile.cpuCores <= 4) {
      return _presets.first;
    }
    if (totalRamGb <= 6.0 || profile.cpuCores <= 6) {
      return _presets[1];
    }
    return _presets.last;
  }

  int estimateTokens(String text) {
    if (text.isEmpty) return 1;
    return (text.length / 4).ceil();
  }

  double tokensPerSecond(int tokens, Duration latency) {
    final seconds = latency.inMilliseconds / 1000.0;
    if (seconds <= 0) return tokens.toDouble();
    return tokens / seconds;
  }

  bool shouldDowngrade({
    required LlmTuningPreset preset,
    required Duration latency,
    required int outputTokens,
  }) {
    if (preset.name == 'low') return false;
    final tps = tokensPerSecond(outputTokens, latency);
    if (latency.inMilliseconds >= 8000) return true;
    if (preset.name == 'high' && latency.inMilliseconds >= 4500 && tps < 8) {
      return true;
    }
    if (preset.name == 'mid' && latency.inMilliseconds >= 5500 && tps < 5) {
      return true;
    }
    return false;
  }

  LlmTuningPreset downgradePreset(LlmTuningPreset preset) {
    final index = _presets.indexWhere((p) => p.name == preset.name);
    if (index <= 0) return preset;
    return _presets[index - 1];
  }
}
