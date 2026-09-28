import Foundation
import NotchCenterKit

func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: MediaControlsPlugin.self))
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
