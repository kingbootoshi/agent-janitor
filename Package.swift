// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-janitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CProbe"),
        .target(name: "JanitorCore", dependencies: ["CProbe"]),
        .executableTarget(name: "janitord", dependencies: ["JanitorCore"]),
        .executableTarget(name: "janitor", dependencies: ["JanitorCore"]),
        .executableTarget(name: "AgentJanitorMenu", dependencies: ["JanitorCore"]),
        .executableTarget(name: "agent-session", dependencies: ["JanitorCore"])
    ]
)
