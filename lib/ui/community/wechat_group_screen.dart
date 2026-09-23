import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 糖友微信群页（替代自建社区）。
///
/// 为什么不用自建社区：冷启动没人发帖就是鬼城；糖友本来就在微信群里，
/// 直接跳过去零维护、零审核、零服务器。App 只做"一键进群"。
///
/// 进群方式（二选一，由发布者在下面填）：
/// 1. 群二维码图片（assets/images/wechat_group.png）：用户长按识别进群；
/// 2. 加群主微信号：点一下复制微信号，去微信搜着加。
class WechatGroupScreen extends StatelessWidget {
  /// 群主微信号（发布者改这里；留空则不显示加群主入口）
  static const ownerWechatId = '';

  /// 群二维码资源路径（把群二维码图片放到这个路径即可显示；没有就只显示方式2）
  static const groupQrAsset = 'assets/images/wechat_group.png';

  const WechatGroupScreen({super.key});

  Future<void> _copyOwnerId(BuildContext context) async {
    if (ownerWechatId.isEmpty) return;
    await Clipboard.setData(const ClipboardData(text: ownerWechatId));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('群主微信号已复制，去微信搜索添加')),
    );
  }

  Future<void> _openWechat(BuildContext context) async {
    // 尝试直接拉起微信（装了就能跳，没装就提示）
    try {
      final ok = await launchUrl(Uri.parse('weixin://'),
          mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未检测到微信，请先安装微信')),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未检测到微信，请先安装微信')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('糖友微信群')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('👥 和糖友们一起控糖',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('群里有真实糖友、用泵老手，控糖问题直接问，\n'
                      '比 App 里等回复快得多。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 方式一：群二维码（有图才显示）
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('方式一：扫码进群',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('长按识别下方二维码进群（7 天过期会换新码，进不去用方式二）。',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 12),
                  Center(
                    child: Image.asset(
                      groupQrAsset,
                      width: 220,
                      height: 220,
                      errorBuilder: (_, __, ___) => Container(
                        width: 220,
                        height: 160,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '群二维码还没放上来\n联系群主索取（方式二）',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 方式二：加群主
          if (ownerWechatId.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_add, color: Colors.green),
                title: const Text('方式二：加群主拉你进群'),
                subtitle: Text('群主微信：$ownerWechatId（点一下复制）'),
                trailing: const Icon(Icons.copy),
                onTap: () => _copyOwnerId(context),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _openWechat(context),
            icon: const Icon(Icons.open_in_new),
            label: const Text('打开微信'),
          ),
          const SizedBox(height: 8),
          const Text('提示：进群后改备注"昵称+糖尿病类型"，方便大家交流。',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}
