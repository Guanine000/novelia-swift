import SwiftUI

extension ReaderSettings {
    var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .system }
    var backgrounds: ReaderBackgroundStore { .shared }

}
