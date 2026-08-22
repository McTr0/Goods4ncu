/// Animation arbitration levels (master goal §29).
///
/// Higher wins. A running plan is cancelled the moment something of strictly
/// higher priority is requested — an idle stretch must never outlive the user
/// starting to talk.
enum AnimationPriority {
  idle(10),
  emotion(60),
  speechGesture(70),
  userInteraction(90),
  interrupt(100);

  const AnimationPriority(this.value);

  final int value;

  bool outranks(AnimationPriority other) => value > other.value;
}
