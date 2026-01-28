import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class MediaPipeService {
  static const MethodChannel _channel = MethodChannel('mediapipe_gemma');
  Future<bool> initializeModel({
    String? modelPath,
    String? assetFileName,
    int? maxTokens,
    int? topK,
  }) async {
    debugPrint('=== MediaPipe 초기화 시작 ===');
    try {
      String finalModelPath;

      // // 1) 에셋에서 복사해서 쓰는 경우
      // if (assetFileName != null) {
      //   debugPrint('Assets에서 모델 파일 복사 요청: $assetFileName');
      //   finalModelPath = await _copyAssetToLocal(assetFileName);
      //   debugPrint('모델 파일 복사 완료: $finalModelPath');
      // }
      // // 2) 외부에서 경로를 직접 넘겨준 경우
      // else if (modelPath != null) {
      //   finalModelPath = modelPath;
      //   debugPrint('전달된 모델 경로 사용: $finalModelPath');
      // }
      // // 3) 아무것도 안 넘겨주면 기본 경로 사용 (adb push 등으로 미리 올려둔 모델)
      // else {
      //   finalModelPath = '/data/local/tmp/llm/gemma-3-1b-it.task';
      //   debugPrint('기본 모델 경로 사용: $finalModelPath');
      // }
      finalModelPath = '/data/local/tmp/llm/gemma-3-1b-it.task';
      // 파일 존재 및 크기 확인 (안드로이드/IOS에서만)
      if (Platform.isAndroid || Platform.isIOS) {
        final file = File(finalModelPath);
        if (!await file.exists()) {
          debugPrint('모델 파일을 찾을 수 없습니다: $finalModelPath');
          return false;
        }
        final sizeMb = (await file.length()) / 1024 / 1024;
        debugPrint('모델 파일 확인 완료 (크기: ${sizeMb.toStringAsFixed(2)} MB)');
      }

      // 네이티브로 초기화 요청
      debugPrint('MethodChannel 호출: initializeModel (경로: $finalModelPath)');
      final args = <String, dynamic>{'modelPath': finalModelPath};
      if (maxTokens != null) {
        args['maxTokens'] = maxTokens;
      }
      if (topK != null) {
        args['topK'] = topK;
      }

      final result = await _channel.invokeMethod<bool>(
        'initializeModel',
        args,
      );

      debugPrint('MethodChannel 응답: $result (type: ${result.runtimeType})');

      if (result == null || result == false) {
        debugPrint('MediaPipe 초기화 실패: result=$result');
        return false;
      }

      debugPrint('✅ MediaPipe 모델 초기화 성공');
      return true;
    } on PlatformException catch (e) {
      debugPrint('MediaPipe 초기화 PlatformException');
      debugPrint('   - code: ${e.code}');
      debugPrint('   - message: ${e.message}');
      debugPrint('   - details: ${e.details}');
      return false;
    } catch (e, stack) {
      debugPrint('MediaPipe 초기화 중 예외 발생: $e');
      debugPrint('   - type: ${e.runtimeType}');
      debugPrint('   - stack: $stack');
      return false;
    } finally {
      debugPrint('=== MediaPipe 초기화 종료 ===');
    }
  }

  /// 텍스트 생성 (채팅 응답)
  Future<String> generateText(String prompt) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'generateText',
        {
          'prompt': prompt,
          // 대화 기록이 필요하면 여기서 추가 구현 가능
          'conversationHistory': '',
        },
      );
      return result ?? '응답을 생성할 수 없습니다.';
    } on PlatformException catch (e) {
      debugPrint('텍스트 생성 오류: ${e.message}');
      return '오류가 발생했습니다: ${e.message}';
    }
  }

  /// 모델 해제
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (e) {
      debugPrint('모델 해제 오류: $e');
    }
  }
}
