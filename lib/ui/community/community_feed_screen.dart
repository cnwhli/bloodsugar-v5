import 'package:flutter/material.dart';
import '../../data/datasource/local_db.dart';

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

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_name': userName,
        'content': content,
        'glucose_mmol_l': glucoseMmolL,
        'tag': tag,
        'likes': likes,
        'created_at': createdAt.toIso8601String(),
      };

  static CommunityPost fromMap(Map<String, dynamic> m) => CommunityPost(
        id: m['id'].toString(),
        userId: m['id'].toString(),
        userName: m['user_name']?.toString() ?? '糖友',
        content: m['content']?.toString() ?? '',
        glucoseMmolL: (m['glucose_mmol_l'] as num?)?.toDouble(),
        tag: m['tag']?.toString(),
        likes: (m['likes'] as num?)?.toInt() ?? 0,
        likedBy: const [],
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );

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

/// 社区服务：本地 sqflite 存储（单机版）。
/// 联网版（Supabase 多人社区）为二期：publishPost/getFeed 保持同样签名，
/// 到时把 db 换成 Supabase 调用即可，UI 不用改。
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
    await AppDatabase.init();
    final id = await AppDatabase.instance.insertPost(
      userName: userName,
      content: content,
      glucoseMmolL: glucoseMmolL,
      tag: tag,
    );
    return id.toString();
  }

  /// 点赞（本地 +1）
  Future<void> likePost(String postId, String userId) async {
    await AppDatabase.init();
    await AppDatabase.instance.likePost(int.parse(postId));
  }

  /// 获取动态列表
  Future<List<CommunityPost>> getFeed({int limit = 20}) async {
    await AppDatabase.init();
    final rows = await AppDatabase.instance.recentPosts(limit: limit);
    return rows.map(CommunityPost.fromMap).toList();
  }
}

/// 社区动态 UI
class CommunityFeedScreen extends StatefulWidget {
  const CommunityFeedScreen({super.key});

  @override
  State<CommunityFeedScreen> createState() => _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends State<CommunityFeedScreen> {
  List<CommunityPost> _posts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final posts = await CommunityService().getFeed();
      if (!mounted) return;
      setState(() {
        _posts = posts;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _like(CommunityPost p) async {
    await CommunityService().likePost(p.id, 'me');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('糖友社区')),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PostComposerScreen()),
        ).then((_) => _load()),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _posts.isEmpty
              ? const Center(
                  child: Text('还没有动态，点右下角发布第一条吧',
                      style: TextStyle(color: Colors.grey)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _posts.length,
                    itemBuilder: (context, i) {
                      final p = _posts[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          title: Text(
                              '${p.userName}${p.tag != null ? ' · ${p.tag}' : ''}'),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(p.content),
                              if (p.glucoseMmolL != null)
                                Chip(
                                  label: Text(
                                      '血糖 ${p.glucoseMmolL!.toStringAsFixed(1)} mmol/L'),
                                ),
                              Text(
                                p.createdAt.toString().substring(0, 16),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              InkWell(
                                onTap: () => _like(p),
                                child: const Icon(Icons.favorite_border),
                              ),
                              Text('${p.likes}'),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
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
  double? _glucose;

  static const List<String> tags = [
    '饮食',
    '运动',
    '用药',
    '心情',
    '经验',
    '问题',
  ];

  @override
  void initState() {
    super.initState();
    _glucose = widget.currentGlucose;
    if (_glucose == null) {
      AppDatabase.init().then((_) async {
        try {
          final rows =
              await AppDatabase.instance.recentReadings(limit: 1);
          if (!mounted) return;
          if (rows.isNotEmpty) {
            setState(() => _glucose =
                (rows.first['value_mmol_l'] as num?)?.toDouble());
          }
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    if (_controller.text.trim().isEmpty) return;
    await CommunityService().publishPost(
      userId: 'me',
      userName: '糖友',
      content: _controller.text.trim(),
      glucoseMmolL: _glucose,
      tag: _selectedTag,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('发布动态')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 当前血糖快照（可选）
            if (_glucose != null && _glucose! > 0)
              Chip(
                label: Text(
                    '当前血糖: ${_glucose!.toStringAsFixed(1)} mmol/L'),
                deleteIcon: const Icon(Icons.close, size: 18),
                onDeleted: () => setState(() => _glucose = null),
              ),
            const SizedBox(height: 12),
            // 标签选择
            Wrap(
              spacing: 8,
              children: tags
                  .map((t) => FilterChip(
                        label: Text(t),
                        selected: _selectedTag == t,
                        onSelected: (_) =>
                            setState(() => _selectedTag = t),
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
              onPressed: _publish,
              child: const Text('发布'),
            ),
          ],
        ),
      ),
    );
  }
}
