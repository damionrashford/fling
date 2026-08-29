public struct DeviceInfo: Equatable, Hashable, Sendable, Identifiable {
    public let ip: String
    public let name: String
    public let model: String

    public var id: String { ip }

    public init(ip: String, name: String, model: String) {
        self.ip = ip; self.name = name; self.model = model
    }
}
