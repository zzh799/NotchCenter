import Foundation
import NotchCenterKit

func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: ClipboardHistoryPlugin.self))
}
