import 'package:flutter/material.dart';
import '../services/mediapipe_service.dart';
import '../services/rag_service.dart';
import '../services/llm_tuning_service.dart';
import '../services/place_index_service.dart';
import '../models/message.dart';
import '../models/place.dart';

class ChatScreen extends StatefulWidget {
  final ValueChanged<List<Place>> onPlacesUpdated;
  final VoidCallback onShowMap;

  const ChatScreen({
    super.key,
    required this.onPlacesUpdated,
    required this.onShowMap,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Message> _messages = [];

  // 서비스 인스턴스 생성
  final MediaPipeService _mediaPipeService = MediaPipeService();
  final RagService _ragService = RagService();
  final LlmTuningService _tuningService = LlmTuningService();
  final PlaceIndexService _placeIndexService = PlaceIndexService();

  bool _isLoading = false; // 답변 생성 중인지
  bool _isModelReady = false; // 모델 로딩 완료됐는지
  String _statusMessage = "AI 모델과 제주 데이터를 로딩 중입니다...";
  int _promptMaxChars = 1200;
  LlmTuningPreset? _currentPreset;
  List<Place> _lastRecommendedPlaces = [];

  @override
  void initState() {
    super.initState();
    _initAllServices();
  }

  // 1. 초기화: Gemma 모델과 RAG 엔진(데이터)을 동시에 준비
  Future<void> _initAllServices() async {
    try {
      final profile = await _tuningService.loadDeviceProfile();
      final preset = _tuningService.choosePreset(profile);
      _promptMaxChars = preset.promptMaxChars;
      _currentPreset = preset;

      // 병렬 처리로 로딩 시간 단축
      await Future.wait([
        _mediaPipeService.initializeModel(
          maxTokens: preset.maxTokens,
          topK: preset.topK,
        ),
        _ragService.init(),
      ]);

      setState(() {
        _isModelReady = true;
        _statusMessage = "준비 완료 (${preset.name})";
        // 환영 메시지 추가
        _addMessage("제주도 여행에 대해 무엇이든 물어보세요!", false);
      });
    } catch (e) {
      setState(() {
        _statusMessage = "초기화 오류: $e";
      });
    }
  }

  // 메시지 리스트에 추가하고 스크롤 내리기
  void _addMessage(String text, bool isUser) {
    setState(() {
      _messages.add(Message(
        text: text,
        isUser: isUser,
        timestamp: DateTime.now(),
      ));
    });

    // UI 그려진 뒤 스크롤 이동
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // 2. 메시지 전송 및 답변 생성 (핵심 로직)
  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !_isModelReady || _isLoading) return;

    _controller.clear();
    _addMessage(text, true); // 내 말풍선 추가
    setState(() => _isLoading = true);

    try {
      // A. RAG 검색: 질문과 관련된 제주 정보 찾기
      // 예: "가마오름 주차 돼?" -> "가마오름... 주차정보: 불가능..." 텍스트를 찾아옴
      String? retrievedInfo = await _ragService.search(text);

      if (retrievedInfo == null || retrievedInfo.trim().isEmpty) {
        _addMessage("죄송해요. 현재 보유한 제주 관광지 정보에는 해당 내용이 없습니다.", false);
        return;
      }

      final trimmedInfo = _truncateRagContext(retrievedInfo);
      print("🔍 RAG 검색 결과(요약):\n$trimmedInfo"); // 로그로 확인

      // B. 정보가 있을 때의 프롬프트 (할루시네이션/반복 방지 강화)
      var prompt = """
    <start_of_turn>user
    Answer the question based on the following information:
      You are an expert tour guide for Jeju Island.
      Please introduce one of the Jeju tourist destinations based on the info provided.
    [Jeju Tourist Information]
    $trimmedInfo
    <end_of_turn>
    <start_of_turn>model
    """;
      prompt = _truncatePrompt(prompt);

      // C. Gemma에게 최종 답변 요청
      final start = DateTime.now();
      final response = await _mediaPipeService.generateText(prompt);
      final duration = DateTime.now().difference(start);

      _addMessage(response, false); // AI 말풍선 추가
      final places = await _placeIndexService.findMatchesInText(
        '$response\n$trimmedInfo',
        maxResults: 3,
      );
      if (mounted) {
        setState(() => _lastRecommendedPlaces = places);
      }
      widget.onPlacesUpdated(places);
      await _maybeDowngradePreset(duration, response);
    } catch (e) {
      _addMessage("오류가 발생했습니다: $e", false);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _truncateRagContext(String text, {int maxChars = 1200}) {
    if (text.length <= maxChars) return text;
    return text.substring(0, maxChars);
  }

  String _truncatePrompt(String text, {int? maxChars}) {
    final limit = maxChars ?? _promptMaxChars;
    if (text.length <= limit) return text;
    return text.substring(0, limit);
  }

  Future<void> _maybeDowngradePreset(Duration duration, String response) async {
    final currentPreset = _currentPreset;
    if (currentPreset == null || !_isModelReady) return;

    final tokens = _tuningService.estimateTokens(response);
    final shouldDowngrade = _tuningService.shouldDowngrade(
      preset: currentPreset,
      latency: duration,
      outputTokens: tokens,
    );
    if (!shouldDowngrade) return;

    final nextPreset = _tuningService.downgradePreset(currentPreset);
    if (nextPreset.name == currentPreset.name) return;

    setState(() {
      _isModelReady = false;
      _statusMessage = "성능 조정 중 (${currentPreset.name} → ${nextPreset.name})";
    });

    final ok = await _mediaPipeService.initializeModel(
      maxTokens: nextPreset.maxTokens,
      topK: nextPreset.topK,
    );
    setState(() {
      _currentPreset = nextPreset;
      _promptMaxChars = nextPreset.promptMaxChars;
      _isModelReady = ok;
      _statusMessage = ok ? "준비 완료 (${nextPreset.name})" : "모델 재초기화 실패";
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _mediaPipeService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("제주 AI 가이드"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.map),
            tooltip: '지도 보기',
            onPressed: widget.onShowMap,
          ),
        ],
      ),
      body: Column(
        children: [
          // 상태 표시줄 (로딩 중일 때 표시)
          if (!_isModelReady)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.orange[100],
              width: double.infinity,
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.orange[900]),
              ),
            ),

          // 채팅창
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return Align(
                  alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: msg.isUser ? Colors.orange[100] : Colors.grey[200],
                      // 말풍선 꼬리 효과
                      borderRadius: msg.isUser
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            )
                          : const BorderRadius.only(
                              topRight: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                    ),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    child: Text(
                      msg.text,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                );
              },
            ),
          ),

          // 로딩 인디케이터
          if (_isLoading) const LinearProgressIndicator(color: Colors.orange),

          if (_lastRecommendedPlaces.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.map),
                  label: Text('추천 장소 지도 보기 (${_lastRecommendedPlaces.length})'),
                  onPressed: widget.onShowMap,
                ),
              ),
            ),

          // 입력창
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: _isModelReady && !_isLoading,
                      decoration: InputDecoration(
                        hintText: "질문을 입력하세요",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Colors.orange,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
