import Combine
import Foundation

/// Selling and licensing run entirely on Lemon Squeezy (Merchant of Record): it
/// hosts checkout, remits tax, and issues the license keys. termio never runs a
/// licensing backend — the desktop app talks to the Lemon Squeezy *License API*
/// directly, where the license key itself is the credential (no secret of ours is
/// involved), so these few constants are all the configuration the app needs.
enum LicenseConfiguration {
    /// Length of the free, no-account trial. After it lapses without a valid
    /// license the app keeps working (we never lock it), but reminds the user to
    /// buy once per day — see `LicenseManager.shouldNagOnLaunch`.
    static let trialDays = 7

    /// Lemon Squeezy License API root. `activate` / `validate` / `deactivate` hang
    /// off this and take the license key as a form field, so no API key is sent.
    static let licenseAPIBase = "https://api.lemonsqueezy.com/v1/licenses"

    /// Where "Buy termio" sends the user — the Lemon Squeezy store/checkout. Filled
    /// in once the store exists; until then it points at the placeholder store URL.
    static let purchaseURLString = "https://termio.lemonsqueezy.com"

    static var purchaseURL: URL? { URL(string: purchaseURLString) }
}

/// What the user is currently entitled to. `licensed` once a key is activated and
/// last validated active; otherwise the 7-day trial counts down to `expired`.
enum LicenseEntitlement: Equatable {
    case licensed
    case trial(daysRemaining: Int)
    case expired
}

/// Drives the License settings tab's transient feedback around an activate call.
enum LicenseActivationState: Equatable {
    case idle
    case working
    case failed(String)
}

/// Owns the license key and the trial clock, and talks to the Lemon Squeezy
/// License API.
///
/// Persistence is `UserDefaults`: the key, the Lemon Squeezy "instance" id this
/// Mac was activated as (needed to validate and to release the seat later), and a
/// `lastValidatedActive` flag that lets the app stay unlocked offline — we only
/// drop a license on a *definite* negative answer (a refunded/disabled key), never
/// on a network failure. The trial start is stamped on first launch.
///
/// Like the trial itself, enforcement is intentionally honest, not hardened: a
/// determined user can clear the stored dates. That is an acceptable trade for a
/// local-only tool — matching how the indie Mac apps in this category behave.
@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var entitlement: LicenseEntitlement = .expired
    @Published private(set) var activationState: LicenseActivationState = .idle
    /// The active license key, or nil when unlicensed. Shown masked in settings.
    @Published private(set) var licenseKey: String?
    /// How many of the key's device activations are in use, when Lemon Squeezy last
    /// told us — drives the "1 of 3 devices" line. Nil until we have a reading.
    @Published private(set) var activationUsage: Int?
    @Published private(set) var activationLimit: Int?

    private let defaults: UserDefaults
    private let session: URLSession

    private enum Key {
        static let licenseKey = "license.key"
        static let instanceId = "license.instanceId"
        static let lastValidatedActive = "license.lastValidatedActive"
        static let trialStart = "license.trialStart"
        static let lastNagDay = "license.lastNagDay"
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session

        // Stamp the trial start the first time we ever run, so the countdown is
        // anchored to first launch rather than to install or to this object's birth.
        if defaults.object(forKey: Key.trialStart) == nil {
            defaults.set(Date.timeIntervalSinceReferenceDate, forKey: Key.trialStart)
        }

        licenseKey = defaults.string(forKey: Key.licenseKey)
        recomputeEntitlement()
    }

    // MARK: Entitlement

    /// True when we hold a key that last checked out as active. Kept separate from
    /// `entitlement` so an offline launch (no fresh validation) still reads licensed.
    private var isLicensed: Bool {
        defaults.string(forKey: Key.licenseKey) != nil
            && defaults.bool(forKey: Key.lastValidatedActive)
    }

    private var trialDaysRemaining: Int {
        let start = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Key.trialStart))
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        return max(0, LicenseConfiguration.trialDays - elapsed)
    }

    private func recomputeEntitlement() {
        if isLicensed {
            entitlement = .licensed
        } else {
            let remaining = trialDaysRemaining
            entitlement = remaining > 0 ? .trial(daysRemaining: remaining) : .expired
        }
    }

    // MARK: Launch refresh

    /// Re-check a stored key against Lemon Squeezy at launch so a refunded or
    /// disabled key (its seat freed) stops counting as licensed. A network or
    /// transport failure is left as-is — we keep the last known-good state rather
    /// than locking a paying user out because they're offline.
    func refreshOnLaunch() async {
        guard let key = defaults.string(forKey: Key.licenseKey) else { return }
        let instanceId = defaults.string(forKey: Key.instanceId)
        do {
            let response = try await postValidate(key: key, instanceId: instanceId)
            applyKeyStatus(response.licenseKey, validatedActive: response.valid)
        } catch {
            // Offline / endpoint hiccup: do nothing, stay on the cached entitlement.
        }
    }

    // MARK: Activation (License settings tab)

    /// Activate a key for this Mac, registering it as one Lemon Squeezy "instance"
    /// (named after the machine). On success the app is licensed; on a definite
    /// rejection (unknown key, activation limit reached) we surface the message.
    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            activationState = .failed("Enter a license key.")
            return
        }

        activationState = .working
        do {
            let response = try await postActivate(key: key, instanceName: Self.deviceName)
            guard response.activated, let instance = response.instance else {
                activationState = .failed(response.error ?? "That license key could not be activated.")
                return
            }
            defaults.set(key, forKey: Key.licenseKey)
            defaults.set(instance.id, forKey: Key.instanceId)
            licenseKey = key
            applyKeyStatus(response.licenseKey, validatedActive: true)
            activationState = .idle
        } catch {
            activationState = .failed("Couldn't reach Lemon Squeezy. Check your connection and try again.")
        }
    }

    /// Release this Mac's activation and forget the key locally, freeing a seat so
    /// the license can move to another machine. Best-effort on the network side: we
    /// clear local state regardless, since the user asked to remove it here.
    func deactivate() async {
        let key = defaults.string(forKey: Key.licenseKey)
        let instanceId = defaults.string(forKey: Key.instanceId)
        if let key, let instanceId {
            _ = try? await postDeactivate(key: key, instanceId: instanceId)
        }
        defaults.removeObject(forKey: Key.licenseKey)
        defaults.removeObject(forKey: Key.instanceId)
        defaults.removeObject(forKey: Key.lastValidatedActive)
        licenseKey = nil
        activationUsage = nil
        activationLimit = nil
        activationState = .idle
        recomputeEntitlement()
    }

    /// Fold a Lemon Squeezy license-key payload into our state. `validatedActive`
    /// is the endpoint's own verdict (`activated`/`valid`); we additionally require
    /// the key's status to be "active" so an expired/disabled key never sticks.
    private func applyKeyStatus(_ payload: LicenseKeyPayload?, validatedActive: Bool) {
        let active = validatedActive && (payload?.status == "active")
        defaults.set(active, forKey: Key.lastValidatedActive)
        activationUsage = payload?.activationUsage
        activationLimit = payload?.activationLimit
        recomputeEntitlement()
    }

    // MARK: Daily purchase reminder

    /// Whether to show the once-a-day "your trial has ended" reminder this launch:
    /// only when the trial has lapsed with no valid license, and not already shown
    /// today. The app stays fully usable either way — this is a nudge, not a gate.
    func shouldNagOnLaunch() -> Bool {
        guard entitlement == .expired else { return false }
        return defaults.integer(forKey: Key.lastNagDay) != Self.currentDay
    }

    func recordNagShown() {
        defaults.set(Self.currentDay, forKey: Key.lastNagDay)
    }

    /// Days since the reference date, used as a stable "which day is it" stamp for
    /// the once-per-day reminder without dragging in date formatting.
    private static var currentDay: Int {
        Int(Date.timeIntervalSinceReferenceDate / 86_400)
    }

    private static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: Lemon Squeezy License API

    private func postActivate(key: String, instanceName: String) async throws -> ActivateResponse {
        try await post("activate", fields: ["license_key": key, "instance_name": instanceName])
    }

    private func postValidate(key: String, instanceId: String?) async throws -> ValidateResponse {
        var fields = ["license_key": key]
        if let instanceId { fields["instance_id"] = instanceId }
        return try await post("validate", fields: fields)
    }

    private func postDeactivate(key: String, instanceId: String) async throws -> DeactivateResponse {
        try await post("deactivate", fields: ["license_key": key, "instance_id": instanceId])
    }

    /// POST a form-encoded request to a License API endpoint and decode the JSON.
    /// Lemon Squeezy returns the same JSON body on success and on a 4xx rejection
    /// (with `error` populated), so we decode the body either way and only throw on
    /// a transport failure or a body we cannot parse at all.
    private func post<Response: Decodable>(
        _ endpoint: String, fields: [String: String]
    ) async throws -> Response {
        guard let url = URL(string: "\(LicenseConfiguration.licenseAPIBase)/\(endpoint)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Response shapes

/// The `license_key` object Lemon Squeezy embeds in every License API response.
private struct LicenseKeyPayload: Decodable {
    let status: String
    let activationLimit: Int?
    let activationUsage: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case activationLimit = "activation_limit"
        case activationUsage = "activation_usage"
    }
}

private struct InstancePayload: Decodable {
    let id: String
}

private struct ActivateResponse: Decodable {
    let activated: Bool
    let error: String?
    let instance: InstancePayload?
    let licenseKey: LicenseKeyPayload?

    enum CodingKeys: String, CodingKey {
        case activated, error, instance
        case licenseKey = "license_key"
    }
}

private struct ValidateResponse: Decodable {
    let valid: Bool
    let error: String?
    let licenseKey: LicenseKeyPayload?

    enum CodingKeys: String, CodingKey {
        case valid, error
        case licenseKey = "license_key"
    }
}

private struct DeactivateResponse: Decodable {
    let deactivated: Bool
    let error: String?
}
