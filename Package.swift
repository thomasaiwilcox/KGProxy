// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KGProxy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KGProxy", targets: ["KGProxy"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.0"),
        .package(url: "https://github.com/thomasaiwilcox/KnowledgeGraphKit.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "KGProxy",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "KGKit", package: "KnowledgeGraphKit"),
                .product(name: "KGKitKuzu", package: "KnowledgeGraphKit")
            ],
            path: "Sources/KGProxy"
        )
    ]
)