import 'package:flutter/material.dart';

/// AI 健康助手（占位，后续接入 LLM + RAG）
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 健康助手')),
      body: const Center(child: Text('AI 助手待接入')),
    );
  }
}
