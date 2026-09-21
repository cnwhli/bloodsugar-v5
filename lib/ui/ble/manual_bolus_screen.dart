import 'package:flutter/material.dart';
import '../domain/bluetooth/pump_protocol.dart';
import '../domain/bluetooth/pump_pairing.dart';

/// 手动给药指令页面
///
/// 半闭环模式：App 计算 → 用户手动确认 → 手动注射
/// 安全边界：
///   - App 不自动给药：sendBolus() 抛出 UnsupportedError
///   - 低血糖 (<3.9) 自动暂停建议
///   - 单次最大 12U
///   - 纠正最大 6U
///
/// 使用方法：
/// 1. 先配对泵（PumpPairScreen）
/// 2. 在此页面输入剂量 → 确认 → 发送到泵
/// 3. 泵上手动确认注射

/// 手动给药指令页面
class ManualBolusScreen extends StatefulWidget {
  final double? currentGlucose; // 当前血糖（用于安全检查）
  final PumpBrand? pumpBrand; // 已配对的泵品牌

  const ManualBolusScreen({
    super.key,
    this.currentGlucose,
    this.pumpBrand,
  });

  @override
  State<ManualBolusScreen> createState() => _ManualBolusScreenState();
}

class _ManualBolusScreenState extends State<ManualBolusScreen> {
  final _controller = TextEditingController();
  double _bolusUnits = 0;
  double _correctionUnits = 0;
  double _totalUnits = 0;
  String _safetyNote = '';
  bool _isSafe = true;
  bool _isLowGlucose = false;
  bool _isHighGlucose = false;
  bool _isCalculated = false;

  // 安全边界
  static const double _maxSingleDose = 12.0; // 单次最大 12U
  static const double _maxCorrection = 6.0; // 纠正最大 6U
  static const double _lowThreshold = 3.9; // 低血糖阈值
  static const double _highThreshold = 10.0; // 高血糖阈值

  @override
  void initState() {
    super.initState();
    _checkGlucoseSafety();
  }

  @override
  void didUpdateWidget(ManualBolusScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentGlucose != widget.currentGlucose) {
      _checkGlucoseSafety();
    }
  }

  /// 检查血糖安全状态
  void _checkGlucoseSafety() {
    final gl = widget.currentGlucose ?? 0;
    setState(() {
      _isLowGlucose = gl > 0 && gl < _lowThreshold;
      _isHighGlucose = gl > _highThreshold;
    });
  }

  /// 计算剂量（App 只算不给）
  void _calculateDose() {
    final gl = widget.currentGlucose ?? 0;
    final input = double.tryParse(_controller.text);

    if (input == null || input <= 0) {
      setState(() {
        _safetyNote = '请输入有效剂量';
        _isSafe = false;
        _totalUnits = 0;
      });
      return;
    }

    double bolus = input;
    double correction = 0;

    // 纠正剂量计算（ISF 公式）
    // correction = (current_glucose - target) / ISF
    // 简化版：使用固定 ISF = 30
    if (gl > _highThreshold) {
      correction = (gl - 5.6) / 30;
      if (correction > _maxCorrection) correction = _maxCorrection;
    }

    final total = bolus + correction;

    // 安全检查
    String note = '';
    bool safe = true;

    if (total > _maxSingleDose) {
      note = '⚠️ 超过单次最大剂量 $_maxSingleDose U，建议分次注射';
      safe = false;
    } else if (total > _maxSingleDose * 0.8) {
      note = '⚠️ 接近单次最大剂量 $_maxSingleDose U，请谨慎';
    }

    if (_isLowGlucose) {
      note += '\n⚠️ 低血糖状态，建议先补充碳水再注射';
      safe = false;
    }

    setState(() {
      _bolusUnits = bolus;
      _correctionUnits = correction;
      _totalUnits = total;
      _safetyNote = note;
      _isSafe = safe;
      _isCalculated = true;
    });
  }

  /// 发送给药指令（App 只算不给，发送指令到泵）
  Future<void> _sendBolus() async {
    // 半闭环模式：App 不自动给药
    // sendBolus() 抛出 UnsupportedError
    throw UnsupportedError('半闭环模式：用户必须在泵上手动确认');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('手动给药')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 当前血糖状态
            if (widget.currentGlucose != null && widget.currentGlucose! > 0)
              Card(
                color: _isLowGlucose
                    ? Colors.blue.shade50
                    : (_isHighGlucose ? Colors.red.shade50 : Colors.green.shade50),
                child: ListTile(
                  leading: Icon(
                    _isLowGlucose
                        ? Icons.trending_down
                        : (_isHighGlucose ? Icons.trending_up : Icons.trending_flat),
                    color: _isLowGlucose
                        ? Colors.blue
                        : (_isHighGlucose ? Colors.red : Colors.green),
                  ),
                  title: Text(
                    '当前血糖: ${widget.currentGlucose!.toStringAsFixed(1)} mmol/L',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _isLowGlucose
                          ? Colors.blue
                          : (_isHighGlucose ? Colors.red : Colors.green),
                    ),
                  ),
                  subtitle: Text(_isLowGlucose
                      ? '低于 $_lowThreshold mmol/L，注意低血糖风险'
                      : (_isHighGlucose
                          ? '高于 $_highThreshold mmol/L，需要纠正'
                          : '血糖正常')),
                ),
              ),
            const SizedBox(height: 16),

            // 剂量输入
            TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '输注剂量（单位 U）',
                hintText: '例如 2.5',
                suffixText: 'U',
                border: const OutlineInputBorder(),
                errorText: _isCalculated && !_isSafe ? '剂量不安全' : null,
              ),
              onChanged: (_) => _isCalculated = false,
            ),
            const SizedBox(height: 12),

            // 计算按钮
            ElevatedButton(
              onPressed: _calculateDose,
              child: const Text('计算剂量'),
            ),
            const SizedBox(height: 16),

            // 计算结果
            if (_isCalculated) ...[
              Card(
                color: _isSafe ? Colors.green.shade50 : Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '剂量详情',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('基础剂量:'),
                          Text('${_bolusUnits.toStringAsFixed(1)} U'),
                        ],
                      ),
                      if (_correctionUnits > 0)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('纠正剂量:'),
                            Text('${_correctionUnits.toStringAsFixed(1)} U'),
                          ],
                        ),
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '总剂量:',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          Text(
                            '${_totalUnits.toStringAsFixed(1)} U',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                                color: Colors.blue),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 安全提示
              if (_safetyNote.isNotEmpty)
                Card(
                  color: _isSafe ? Colors.green.shade100 : Colors.orange.shade100,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _safetyNote,
                      style: TextStyle(
                        color: _isSafe ? Colors.green.shade800 : Colors.orange.shade800,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // 发送指令按钮（半闭环：App 不自动给药）
              ElevatedButton.icon(
                onPressed: _isSafe ? () async {
                  try {
                    await _sendBolus();
                  } on UnsupportedError {
                    // 半闭环模式：提示用户在泵上手动确认
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('半闭环模式：请在泵上手动确认给药'),
                        backgroundColor: Colors.blue,
                      ),
                    );
                  }
                } : null,
                icon: const Icon(Icons.send),
                label: const Text('发送指令到泵'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isSafe ? Colors.blue : Colors.grey,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
              const SizedBox(height: 8),

              // 免责声明
              const Text(
                '⚠️ 半闭环模式：App 只算不给，用户必须在泵上手动确认。\n'
                '低血糖 (<$_lowThreshold) 自动暂停建议。\n'
                '单次最大 $_maxSingleDose U，纠正最大 $_maxCorrection U。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }
}