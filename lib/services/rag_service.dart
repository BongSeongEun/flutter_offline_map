import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:mobile_rag_engine/mobile_rag_engine.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

class RagService {
  static final RagService _instance = RagService._internal();
  factory RagService() => _instance;
  RagService._internal();

  bool _isInitialized = false;
  Future<void>? _initFuture;
  String? _dbPath;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_initFuture != null) return _initFuture;

    _initFuture = _doInit();
    return _initFuture;
  }

  Future<void> _doInit() async {
    try {
      print("🚀 RAG 엔진 초기화 시작...");

      // 1. 내장된 Rust 라이브러리 로드 (패키지 기본 로더 사용)
      await RustLib.init();

      // 2. 토크나이저 파일을 앱 로컬 경로로 복사한 뒤 초기화
      final tokenizerPath = await _copyAssetToLocal(
        assetPath: 'assets/models/tokenizer.json',
        fileName: 'tokenizer.json',
      );
      await initTokenizer(tokenizerPath: tokenizerPath);

      // 3. 임베딩 모델 로드 (쿼리 임베딩용)
      final modelBytes = await rootBundle.load('assets/models/model_quantized.onnx');
      await EmbeddingService.init(modelBytes.buffer.asUint8List());
      final embTest = await EmbeddingService.embed('제주 여행지 테스트');
      print("🧪 임베딩 차원: ${embTest.length}");

      // 4. 앱 전용 디렉토리에 RAG DB 준비
      final dir = await getApplicationDocumentsDirectory();
      _dbPath = '${dir.path}/jeju_rag.db';

      // 5. Source RAG DB 초기화 및 상태 확인
      await initSourceDb(dbPath: _dbPath!);
      var stats = await getSourceStats(dbPath: _dbPath!);
      var sourceCount = _toInt(stats.sourceCount);
      var chunkCount = _toInt(stats.chunkCount);
      print("📊 RAG DB 상태: sources=${stats.sourceCount}, chunks=${stats.chunkCount}");

      // 6. 데이터가 비어있으면 DB를 초기화하고 JSON을 임베딩해서 직접 구축
      if (chunkCount == 0 || sourceCount == 0) {
        print("🗑 기존 RAG DB 초기화 후 재구성 시작...");
        if (await File(_dbPath!).exists()) {
          await File(_dbPath!).delete();
        }
        await initSourceDb(dbPath: _dbPath!);

        print("📥 JSON 데이터로 RAG DB 구축 시작...");
        await _buildDbFromJson();
        stats = await getSourceStats(dbPath: _dbPath!);
        sourceCount = _toInt(stats.sourceCount);
        chunkCount = _toInt(stats.chunkCount);
        print("📊 RAG DB 재확인: sources=${stats.sourceCount}, chunks=${stats.chunkCount}");

        print("🔧 Chunk HNSW 인덱스 재구성 시작...");
        await rebuildChunkHnswIndex(dbPath: _dbPath!);
        print("✅ Chunk HNSW 인덱스 재구성 완료");
      }

      _isInitialized = true;
      print("✅ RAG 엔진 준비 완료!");
    } catch (e) {
      print("❌ RAG 초기화 실패: $e");
      rethrow;
    } finally {
      if (!_isInitialized) {
        _initFuture = null;
      }
    }
  }

  // JSON → DB 인덱싱은 더 이상 사용하지 않음 (문서 임베딩은 에셋 DB에 포함)

  Future<String> _copyAssetToLocal({
    required String assetPath,
    required String fileName,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/$fileName';
    final file = File(filePath);

    if (!await file.exists()) {
      final byteData = await rootBundle.load(assetPath);
      await file.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );
    }

    return filePath;
  }

  Future<void> _buildDbFromJson() async {
    final jsonString = await rootBundle.loadString('assets/data/jeju_data.json');
    final List<dynamic> jsonData = jsonDecode(jsonString);

    print("📦 제주 데이터 ${jsonData.length}개 임베딩 시작");

    final ragService = SourceRagService(dbPath: _dbPath!);
    await ragService.init();

    int processed = 0;
    int fallbackChunks = 0;

    for (var item in jsonData) {
      final title = item['title'] ?? '이름 없음';
      final category = "${item['mainCategory']} > ${item['subCategory']} > ${item['detailCategory']}";
      final address = item['address'] ?? '';
      final overview = item['overview'] ?? '';
      final usageTime = item['usageTime'] ?? '';
      final parking = item['parkingInformation'] ?? '';
      final contact = item['contactNumber'] ?? '';

      final contentBuffer = StringBuffer();
      contentBuffer.writeln("관광지명: $title");
      contentBuffer.writeln("카테고리: $category");
      if (address.isNotEmpty) contentBuffer.writeln("주소: $address");
      if (contact.isNotEmpty) contentBuffer.writeln("연락처: $contact");
      if (usageTime.isNotEmpty) contentBuffer.writeln("이용시간: $usageTime");
      if (parking.isNotEmpty) contentBuffer.writeln("주차정보: $parking");
      if (overview.isNotEmpty) contentBuffer.writeln("설명: $overview");

      final content = contentBuffer.toString();
      final addResult = await ragService.addSourceWithChunking(
        content,
        metadata: jsonEncode({'title': title}),
      );

      // Fallback: chunker가 비어있으면 단일 청크로 강제 저장
      if (addResult.chunkCount == 0 && !addResult.isDuplicate) {
        fallbackChunks++;
        final embedding = await EmbeddingService.embed(content);
        final chunk = ChunkData(
          content: content,
          chunkIndex: 0,
          startPos: 0,
          endPos: content.length,
          chunkType: 'full',
          embedding: Float32List.fromList(embedding),
        );
        await addChunks(
          dbPath: _dbPath!,
          sourceId: PlatformInt64Util.from(addResult.sourceId),
          chunks: [chunk],
        );
      }

      processed++;
      if (processed % 50 == 0) {
        print("📦 임베딩 진행: $processed/${jsonData.length} (fallback=$fallbackChunks)");
      }
    }

    print("📦 임베딩 진행: ${jsonData.length}/${jsonData.length} (fallback=$fallbackChunks)");
    print("🎉 JSON 임베딩 완료");
  }

  int _toInt(Object value) {
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  Future<String?> search(String query) async {
    if (!_isInitialized) await init();
    try {
      final queryEmbedding = await EmbeddingService.embed(query);

      // 상위 2개만 가져와도 충분할 것 같습니다 (데이터가 상세해서)
      final results = await searchChunks(
        dbPath: _dbPath!,
        queryEmbedding: queryEmbedding,
        topK: 1,
      );

      if (results.isEmpty) return null;
      final sourceTitleCache = <int, String>{};
      final formatted = <String>[];

      for (final r in results) {
        final sourceId = r.sourceId.toInt();
        final title = sourceTitleCache.putIfAbsent(
          sourceId,
          () => '알 수 없음',
        );

        if (title == '알 수 없음') {
          final sourceContent = await getSource(
            dbPath: _dbPath!,
            sourceId: PlatformInt64Util.from(sourceId),
          );
          final extracted = _extractTitleFromSourceContent(sourceContent);
          if (extracted != null) {
            sourceTitleCache[sourceId] = extracted;
          }
        }

        final titleLine = "관광지명: ${sourceTitleCache[sourceId]}";
        final content = r.content.trimLeft();
        if (content.startsWith('관광지명:')) {
          formatted.add(content);
        } else {
          formatted.add("$titleLine\n${r.content}");
        }
      }

      return formatted.join("\n\n---\n\n");
    } catch (e) {
      print("검색 실패: $e");
      return null;
    }
  }

  String? _extractTitleFromSourceContent(String? content) {
    if (content == null) return null;
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('관광지명:')) {
        final name = trimmed.replaceFirst('관광지명:', '').trim();
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }
}
