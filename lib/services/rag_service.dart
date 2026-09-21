import 'package:flutter/material.dart';

/// RAG AI 健康助手服务
///
/// 基于 Supabase pgvector + OpenAI Embeddings + LLM 的糖尿病知识库问答
///
/// 数据流：
///   用户问题 → Embedding → pgvector 相似度搜索 → Top-K 上下文 → LLM 生成回答
///
/// 使用方法：
/// 1. 创建 Supabase 项目 → 启用 pgvector 扩展
/// 2. 运行 SQL 初始化脚本（见 RagService.initSql）
/// 3. 配置 OpenAI API Key（或使用 lfree.org 免费端点）
/// 4. 替换 RagService 中的 API Key

class RagService {
  static final RagService _instance = RagService._internal();
  factory RagService() => _instance;
  RagService._internal();

  /// OpenAI Embeddings 模型
  static const String embeddingModel = 'text-embedding-3-small';

  /// LLM 模型（默认使用 lfree.org 免费端点）
  static const String llmModel = 'claude-opus-5';

  /// 相似度搜索 Top-K
  static const int topK = 5;

  /// 初始化：创建知识库表
  static const String initSql = '''
-- 启用 pgvector 扩展
CREATE EXTENSION IF NOT EXISTS vector;

-- 糖尿病知识库表
CREATE TABLE diabetes_knowledge (
  id BIGSERIAL PRIMARY KEY,
  question TEXT NOT NULL,
  answer TEXT NOT NULL,
  category TEXT, -- 饮食/运动/用药/监测/并发症
  tags TEXT[],
  embedding VECTOR(1536), -- OpenAI text-embedding-3-small 维度
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建向量索引（HNSW）
CREATE INDEX ON diabetes_kledge USING hnsw (embedding vector_cosine_ops);

-- 示例数据
INSERT INTO diabetes_knowledge (question, answer, category, tags)
VALUES
  ('血糖正常范围是多少？', '空腹血糖 3.9-6.1 mmol/L，餐后2小时 < 7.8 mmol/L。动态血糖目标：空腹 4.4-7.0，餐后 < 10.0。', '监测', ARRAY['血糖','范围']),
  ('低血糖怎么办？', '血糖 < 3.9 mmol/L 立即补充 15g 快速碳水：葡萄糖片/果汁/糖果。15分钟后复测，仍低则重复。意识不清不要喂食，立即就医。', '并发症', ARRAY['低血糖','急救']),
  ('饮食注意事项', '控制碳水摄入，选择低GI食物。定时定量，避免空腹运动。饮酒前先测血糖。', '饮食', ARRAY['饮食','GI']),
  ('运动建议', '每周150分钟中等强度有氧运动。运动前测血糖 < 5.6 需加餐。携带快速碳水。', '运动', ARRAY['运动','建议']),
  ('胰岛素存储', '未开封胰岛素 2-8°C 冷藏，开封后室温（<25°C）保存28天。避免冷冻和暴晒。', '用药', ARRAY['胰岛素','存储']);
''';

  /// 相似度搜索
  Future<List<Map<String, dynamic>>> search(String query,
      {int k = topK}) async {
    // 1. 计算查询 embedding
    // final embedding = await _computeEmbedding(query);

    // 2. pgvector 相似度搜索
    // final response = await Supabase.instance.client.rpc('match_knowledge', params: {
    //   'query_embedding': embedding.toList(),
    //   'match_count': k,
    // });

    // return response as List<Map<String, dynamic>>;
    throw UnimplementedError('search 需配置 OpenAI API Key');
  }

  /// 计算文本 embedding
  Future<List<double>> _computeEmbedding(String text) async {
    // 调用 OpenAI / lfree Embeddings API
    throw UnimplementedError('_computeEmbedding 需配置 API Key');
  }

  /// RAG 问答
  Future<String> ask(String question) async {
    // 1. 搜索相关知识
    // final results = await search(question);

    // 2. 构建上下文
    // final context = results.map((r) => r['answer']).join('\n\n');

    // 3. LLM 生成回答
    // final response = await callLlm(question, context);

    // return response;
    throw UnimplementedError('ask 需配置 API Key');
  }
}

/// AI 健康助手 UI
class AiHealthAssistantScreen extends StatelessWidget {
  final double? currentGlucose;

  const AiHealthAssistantScreen({super.key, this.currentGlucose});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 健康助手'),
        actions: [
          if (currentGlucose != null && currentGlucose! > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '血糖: ${currentGlucose!.toStringAsFixed(1)}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
        ],
      ),
      body: const Center(
        child: Text('AI 助手待 OpenAI API Key 配置'),
      ),
    );
  }
}
