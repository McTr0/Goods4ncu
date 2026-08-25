import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Coordinates a bottom bar with descendant vertical scrollables.
///
/// Only direct pointer drags and wheel/trackpad input affect visibility.
/// Programmatic scrolling (for example, keeping a streaming chat reply in
/// view) must not hide navigation.
class ScrollAwareBottomBarController extends ChangeNotifier {
  ScrollAwareBottomBarController({this.hideThreshold = 18});

  final double hideThreshold;

  bool _visible = true;
  bool _trackingUserDrag = false;
  double _accumulatedDelta = 0;
  double _currentPixels = 0;
  double _minimumExtent = 0;
  double _maximumExtent = 0;

  bool get visible => _visible;

  bool handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    _rememberMetrics(notification.metrics);

    if (_isAtTop) show();

    if (notification is ScrollStartNotification) {
      _trackingUserDrag = notification.dragDetails != null;
      _accumulatedDelta = 0;
      return false;
    }

    if (notification is ScrollUpdateNotification && _trackingUserDrag) {
      _consumeUserDelta(notification.scrollDelta ?? 0);
      return false;
    }

    if (notification is ScrollEndNotification) {
      _trackingUserDrag = false;
      _accumulatedDelta = 0;
    }
    return false;
  }

  bool handleScrollMetricsNotification(ScrollMetricsNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    _rememberMetrics(notification.metrics);
    if (!_canScroll || _isAtTop) show();
    return false;
  }

  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_canScroll) return;
    _consumeUserDelta(event.scrollDelta.dy);
  }

  void show() => _setVisible(true);

  void hide() => _setVisible(false);

  /// Restores navigation during a parent rebuild without notifying listeners.
  /// The shell is already rebuilding when its route changes.
  void resetForRoute() {
    _visible = true;
    _trackingUserDrag = false;
    _accumulatedDelta = 0;
    _currentPixels = 0;
    _minimumExtent = 0;
    _maximumExtent = 0;
  }

  bool get _canScroll => _maximumExtent > _minimumExtent + 1;

  bool get _isAtTop => _currentPixels <= _minimumExtent + 1;

  void _rememberMetrics(ScrollMetrics metrics) {
    _currentPixels = metrics.pixels;
    _minimumExtent = metrics.minScrollExtent;
    _maximumExtent = metrics.maxScrollExtent;
  }

  void _consumeUserDelta(double delta) {
    if (delta == 0) return;

    final changedDirection =
        _accumulatedDelta != 0 &&
        (_accumulatedDelta.isNegative != delta.isNegative);
    if (changedDirection) _accumulatedDelta = 0;
    _accumulatedDelta += delta;

    if (_accumulatedDelta >= hideThreshold &&
        _currentPixels > _minimumExtent + hideThreshold) {
      hide();
      _accumulatedDelta = 0;
    } else if (_accumulatedDelta <= -hideThreshold) {
      show();
      _accumulatedDelta = 0;
    }
  }

  void _setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    notifyListeners();
  }
}

class ScrollAwareBottomBar extends StatelessWidget {
  const ScrollAwareBottomBar({
    super.key,
    required this.controller,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
  });

  final ScrollAwareBottomBarController controller;
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final visible = controller.visible;
        return ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topCenter,
            heightFactor: visible ? 1 : 0,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: IgnorePointer(
              ignoring: !visible,
              child: ExcludeSemantics(excluding: !visible, child: child),
            ),
          ),
        );
      },
    );
  }
}
