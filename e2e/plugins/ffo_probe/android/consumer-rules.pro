# R8 renames classes in release builds. Keep the plugin's classes under their
# own names, so the e2e checks can find them in an app's dex by name.
-keep class io.github.mavoryl.ffo_probe.** { *; }
