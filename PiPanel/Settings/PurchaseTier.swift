import Foundation

/// The three device-count license tiers sold on the pricing page — must match the Creem Product
/// IDs configured in Server/cloudflare-worker (env vars CREEM_PRODUCT_SINGLE/DUAL/MULTI).
enum PurchaseTier: String, CaseIterable, Identifiable {
    case single
    case dual
    case multi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "单设备"
        case .dual: return "双设备"
        case .multi: return "多设备"
        }
    }
}
