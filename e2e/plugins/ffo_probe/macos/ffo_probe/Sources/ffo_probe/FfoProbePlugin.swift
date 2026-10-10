import Cocoa
import FlutterMacOS

public class FfoProbePlugin: NSObject, FlutterPlugin {
  // The e2e checks look for this string in the built app. It is longer than
  // 15 bytes on purpose: Swift keeps shorter literals inline in the machine
  // code, longer ones as C strings that `strings` finds.
  static let nativeMarker = "ffo_probe_native_marker_macos"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ffo_probe", binaryMessenger: registrar.messenger)
    let instance = FfoProbePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "nativeMarker":
      // Not part of the Dart API: keeps the marker reachable, so the linker
      // does not drop it.
      result(FfoProbePlugin.nativeMarker)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
