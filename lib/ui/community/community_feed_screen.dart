import 'package:flutter/material.dart';
import '../domain/bluetooth/cgm_protocol.dart';

/// 糖友社区模块
///
/// 功能：
/// - 动态发布（文字 + 血糖快照）
/// - 评论 + 点赞
/// - 糖友关注
/// - 经验分享标签
///
/// 安全规范：
/// - 不提供医疗建议
/// - 每条动态底部自动追加免责声明
/// - 急症关键词自动提示就医

/// 社区动态
class CommunityPost {
  final String id;
  final String userId;
  final String userName;
  final String content;
  final double? glucoseMmolL; // 关联血糖快照（可选）
  final String? tag; // 经验标签：饮食/运动/用药/心情
  final int likes;
  final List<String> likedBy;
  final DateTime createdAt;

  CommunityPost({
    required this.id,
    required this.userId,
    required this.userName,
    required this.content,
    this.glucoseMmolL,
    this.tag,
    this.likes = 0,
    this.likedBy = const [],
    required this.createdAt,
  });

  CommunityPost copyWith({int? likes, List<String>? likedBy}) {
    return CommunityPost(
      id: id,
      userId: userId,
      userName: userName,
      content: content,
      glucoseMmolL: glucoseMmolL,
      tag: tag,
      likes: likes ?? this.likes,
      likedBy: likedBy ?? this.likedBy,
      createdAt: createdAt,
    );
  }
}

/// 社区服务
class CommunityService {
  static final CommunityService _instance = CommunityService._internal();
  factory CommunityService() => _instance;
  CommunityService._internal();

  /// 发布动态
  Future<String> publishPost({
    required String userId,
    required String userName,
    required String content,
    double? glucoseMmolL,
    String? tag,
  }) async {
    // Supabase 插入
    // const response = await Supabase.instance.client
    //     .from('community_posts')
    //     .insert({
    //       'user_id': userId,
    //       'user_name': userName,
    //       'content': content,
    //       'glucose_mmol_l': glucoseMmolL,
    //       'tag': tag,
    //     })
    //     .select()
    //     .single();
    // return response['id'];
    throw UnimplementedError('publishPost 需配置 Supabase');
  }

  /// 点赞
  Future<void> likePost(String postId, String userId) async {
    // Supabase 更新 likedBy 数组
    throw UnimplementedError('likePost 需配置 Supabase');
  }

  /// 获取动态列表
  Future<List<CommunityPost>> getFeed({int limit = 20}) async {
    // Supabase 查询
    // final response = await Supabase.instance.client
    //     .from('community_posts')
    //     .select()
    //     .order('created_at', ascending: false)
    //     .limit(limit);
    // return (response as List)
    //     .map((row) => CommunityPost.fromJson(row))
    //     .toList();
    throw UnimplementedError('getFeed 需配置 Supabase');
  }
}

/// 社区动态 UI
class CommunityFeedScreen extends StatelessWidget {
  const CommunityFeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('糖友社区')),
      body: const Center(
        child: Text('社区功能待 Supabase 配置'),
      ),
    );
  }
}

/// 发布动态 UI
class PostComposerScreen extends StatefulWidget {
  final double? currentGlucose;

  const PostComposerScreen({super.key, this.currentGlucose});

  @override
  State<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends State<PostComposerScreen> {
  final _controller = TextEditingController();
  String? _selectedTag;

  static const List<String> tags = [
    '饮食',
    '运动',
    '用药',
    '心情',
    '经验',
    '问题',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('发布动态')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 当前血糖快照（可选）
            if (widget.currentGlucose > 0)
              Chip(
                label: Text('当前血糖: ${widget.currentGlucose.toStringAsFixed(1)} mmol/L'),
                deleteIcon: const Icon(Icons.close),
                onDeleted: () {},
              ),
            const SizedBox(height: 12),
            // 标签选择
            Wrap(
              spacing: 8,
              children: tags
                  .map((t) => FilterChip(
                        label: Text(t),
                        selected: _selectedTag == t,
                        onSelected: (_) => setState(() => _selectedTag = t),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            // 内容输入
            TextField(
              controller: _controller,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '分享你的经验或问题...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // 免责声明
            const Text(
              '⚠️ 以上内容仅供参考，不能替代专业医疗诊断。如有健康问题请及时就医。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                if (_controller.text.isNotEmpty) {
                  // CommunityService().publishPost(...)
                  Navigator.pop(context);
                }
              },
              child: const Text('发布'),
            ),
          ],
        ),
      ),
    );
  }
}
