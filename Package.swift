// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RepHub",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "RepHub", targets: ["RepHubApp"])],
    targets: [
        .target(name: "VersionControlCore"),
        .target(name: "ToolExecution", dependencies: ["VersionControlCore"]),
        .target(name: "GitAdapter", dependencies: ["VersionControlCore", "ToolExecution"]),
        .target(name: "SVNAdapter", dependencies: ["VersionControlCore", "ToolExecution"]),
        .target(name: "RepositoryApplication", dependencies: ["VersionControlCore"]),
        .target(name: "DesignSystem"),
        .target(name: "RepHubUI", dependencies: ["VersionControlCore", "RepositoryApplication", "DesignSystem"]),
        .executableTarget(name: "RepHubApp", dependencies: ["RepHubUI", "DesignSystem", "RepositoryApplication", "GitAdapter", "SVNAdapter"]),
        .testTarget(name: "CoreTests", dependencies: ["VersionControlCore", "RepositoryApplication", "ToolExecution"]),
        .testTarget(name: "GitAdapterTests", dependencies: ["GitAdapter", "ToolExecution"]),
        .testTarget(name: "SVNAdapterTests", dependencies: ["SVNAdapter", "ToolExecution"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "RepHubUITests", dependencies: ["RepHubUI", "RepositoryApplication", "VersionControlCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["RepositoryApplication", "GitAdapter", "SVNAdapter", "ToolExecution"]),
    ]
)
