import CodexRunwayCore
import SwiftUI

/// High-frequency cost-scan progress, isolated from RunwayModel's @Published
/// surface so only the views that render progress re-evaluate on each tick.
@MainActor
final class CostProgressModel: ObservableObject {
    @Published var progress: CostScanProgress = .idle
}
