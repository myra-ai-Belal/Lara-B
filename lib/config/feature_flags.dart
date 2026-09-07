class FeatureFlags {
  FeatureFlags._();

  // The floating round bubble that appears while a task runs in the
  // background. Wrapped defensively wherever it's used, so any platform
  // quirk with the overlay window never crashes the rest of the app.
  static const bool floatingOverlayEnabled = true;
}
