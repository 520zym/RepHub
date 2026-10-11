// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RepHub",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "RepHub", targets: ["RepHubApp"])],
    targets: [
        .target(name: "VersionControlCore"),
        .target(name: "AICore"),
        .target(name: "AIApplication", dependencies: ["AICore"]),
        .target(name: "AIAdapters", dependencies: ["AICore", "ToolExecution"]),
        .target(name: "ToolExecution", dependencies: ["VersionControlCore"]),
        .target(name: "GitAdapter", dependencies: ["VersionControlCore", "ToolExecution"]),
        .target(name: "SVNAdapter", dependencies: ["VersionControlCore", "ToolExecution"]),
        .target(name: "RepositoryApplication", dependencies: ["VersionControlCore", "AICore"]),
        .target(name: "DesignSystem"),
        .target(name: "RepHubUI", dependencies: ["VersionControlCore", "RepositoryApplication", "DesignSystem", "AICore", "AIApplication"]),
        .executableTarget(name: "RepHubApp", dependencies: ["RepHubUI", "DesignSystem", "RepositoryApplication", "GitAdapter", "SVNAdapter", "AIAdapters", "AIApplication"]),
        .testTarget(name: "AICoreTests", dependencies: ["AICore", "AIApplication"]),
        .testTarget(name: "AIAdaptersTests", dependencies: ["AIAdapters", "AICore", "ToolExecution"]),
        .target(name: "TestSupport", dependencies: ["VersionControlCore", "ToolExecution"], path: "Tests/TestSupport"),
        .testTarget(name: "CoreTests", dependencies: ["VersionControlCore", "RepositoryApplication", "ToolExecution", "TestSupport", "AICore"]),
        .testTarget(name: "GitAdapterTests", dependencies: ["GitAdapter", "ToolExecution", "TestSupport", "VersionControlCore"]),
        .testTarget(name: "SVNAdapterTests", dependencies: ["SVNAdapter", "ToolExecution", "TestSupport"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "RepHubUITests", dependencies: ["RepHubUI", "RepositoryApplication", "VersionControlCore", "AICore", "AIApplication"]),
        .testTarget(name: "IntegrationTests", dependencies: ["RepositoryApplication", "GitAdapter", "SVNAdapter", "ToolExecution", "TestSupport"]),
    ]
)
