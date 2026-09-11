import Foundation
import NotchCenterKit

func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: LidAngleDepthPlugin.self))
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key, bundle: Bundle(for: LidAngleDepthPlugin.self)), arguments: args)
}
