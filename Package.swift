// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "IDeviceKit",
	platforms: [
		.iOS(.v15),
		.macOS(.v12),
	],
	products: [
		.library(
			name: "IDevice",
			targets: ["IDevice"]
		),
		.library(
			name: "IDeviceSwift",
			targets: ["IDeviceSwift"]
		),
	],
	targets: [
		.binaryTarget(
			name: "IDevice",
			path: "Frameworks/IDevice.xcframework"
		),
		.target(
			name: "IDeviceSwift",
			dependencies: ["IDevice"]
		),
	]
)
