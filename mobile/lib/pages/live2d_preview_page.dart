import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../components/live2d/live2d_character_widget.dart';
import '../components/live2d/live2d_controller.dart';
import '../components/live2d/live2d_lipsync_driver.dart';

/// Interactive showcase & playground page for the Live2D "Talking Tom" digital character.
class Live2DPreviewPage extends StatefulWidget {
  const Live2DPreviewPage({super.key});

  @override
  State<Live2DPreviewPage> createState() => _Live2DPreviewPageState();
}

class _Live2DPreviewPageState extends State<Live2DPreviewPage> {
  late final Live2DController _controller;
  late final Live2DLipSyncDriver _lipSyncDriver;

  @override
  void initState() {
    super.initState();
    _controller = Live2DController();
    _lipSyncDriver = Live2DLipSyncDriver(controller: _controller);
  }

  @override
  void dispose() {
    _lipSyncDriver.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFFFFBF5),
      appBar: AppBar(
        title: const Text('小昌 · 2D 互动数字人'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 1. Tip banner explaining touch capabilities
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF0F766E).withValues(alpha: 0.2),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.touch_app_rounded,
                      color: Color(0xFF0F766E),
                      size: 22,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '💡 试着点击小昌的头部或肚子，或者在屏幕上滑动手指让小昌看向你！',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF134E4A),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // 2. Central Live2D Character Interactive Stage
              Container(
                height: 340,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const RadialGradient(
                    colors: [Color(0xFFE1F4EF), Colors.transparent],
                    radius: 0.75,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Live2DCharacterWidget(
                  controller: _controller,
                  size: 240,
                ),
              ),

              const SizedBox(height: 20),

              // 3. Interactive Touch Feedback Badges
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildStatusChip(
                        label: '摸头次数: ${_controller.hitCount}',
                        icon: Icons.face_retouching_natural_rounded,
                        active: _controller.lastHitZone == Live2DHitZone.head,
                      ),
                      _buildStatusChip(
                        label:
                            '说话状态: ${_controller.mouthOpen > 0.1 ? "讲话中..." : "待机"}',
                        icon: Icons.record_voice_over_rounded,
                        active: _controller.mouthOpen > 0.1,
                      ),
                      _buildStatusChip(
                        label: '表情: ${_controller.expression.name}',
                        icon: Icons.mood_rounded,
                        active: _controller.expression != Live2DExpression.idle,
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 24),

              // 4. Emotion & Action Controls
              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🎮 互动与口型同步测试',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF0F766E),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Speech & Talking Simulation Buttons
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () {
                                _controller.showSpeechBubble(
                                  '欢迎来到续樟！我是你的智能助理小昌~',
                                );
                                _controller.startTalkingSimulation(
                                  duration: const Duration(seconds: 3),
                                );
                              },
                              icon: const Icon(
                                Icons.volume_up_rounded,
                                size: 18,
                              ),
                              label: const Text('模拟说话口型'),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF0F766E),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              _controller.playMotion('tap_head');
                              _controller.showSpeechBubble('摸摸小脑袋，智慧长出来！');
                            },
                            icon: const Icon(Icons.favorite_rounded, size: 18),
                            label: const Text('摸摸头'),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              _controller.playMotion('poke_belly');
                              _controller.setExpression(
                                Live2DExpression.surprised,
                              );
                              _controller.showSpeechBubble('哎呀，肚子要被你戳扁啦！');
                            },
                            icon: const Icon(Icons.back_hand_rounded, size: 18),
                            label: const Text('戳肚子'),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Expression switcher buttons
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildEmotionButton(
                              '😊 开心',
                              Live2DExpression.happy,
                            ),
                            const SizedBox(width: 8),
                            _buildEmotionButton(
                              '🤔 思考',
                              Live2DExpression.thinking,
                            ),
                            const SizedBox(width: 8),
                            _buildEmotionButton('😳 害羞', Live2DExpression.shy),
                            const SizedBox(width: 8),
                            _buildEmotionButton(
                              '😛 吐舌',
                              Live2DExpression.tongueOut,
                            ),
                            const SizedBox(width: 8),
                            _buildEmotionButton('🌿 复位', Live2DExpression.idle),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // 5. Jump to Chat with Xiaochang
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/chat'),
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: const Text('打开小昌实时对话'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    foregroundColor: const Color(0xFF0F766E),
                    side: const BorderSide(
                      color: Color(0xFF0F766E),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmotionButton(String title, Live2DExpression expr) {
    final isSelected = _controller.expression == expr;
    return OutlinedButton(
      onPressed: () => _controller.setExpression(expr),
      style: OutlinedButton.styleFrom(
        backgroundColor: isSelected
            ? const Color(0xFF0F766E).withValues(alpha: 0.12)
            : null,
        side: BorderSide(
          color: isSelected
              ? const Color(0xFF0F766E)
              : Colors.grey.withValues(alpha: 0.3),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: isSelected ? const Color(0xFF0F766E) : const Color(0xFF334155),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildStatusChip({
    required String label,
    required IconData icon,
    required bool active,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF0F766E).withValues(alpha: 0.15)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active
              ? const Color(0xFF0F766E)
              : Colors.grey.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: active ? const Color(0xFF0F766E) : Colors.grey,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? const Color(0xFF0F766E) : const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}
