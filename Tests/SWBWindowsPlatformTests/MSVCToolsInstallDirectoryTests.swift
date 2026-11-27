//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
@_spi(Testing) import SWBWindowsPlatform
import SWBTestSupport
import SWBUtil
import Testing

@Suite fileprivate struct MSVCToolsInstallDirectoryTests {
    /// Builds a `VSInstallation` the way `vswhere -format json` reports it.
    private func installation(path: Path, version: String) throws -> VSInstallation {
        let json = """
            {"installationPath": \(try jsonString(path.str)), "installationVersion": "\(version)", "packages": []}
            """
        return try JSONDecoder().decode(VSInstallation.self, from: Data(json.utf8))
    }

    private func jsonString(_ string: String) throws -> String {
        String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
    }

    private func msvcDirectory(of installation: Path) -> Path {
        installation.join("VC").join("Tools").join("MSVC")
    }

    /// Creates `<installation>/VC/Tools/MSVC/<toolsets>` in the file system.
    private func addToolsets(_ toolsets: [String], to installation: Path, in fs: PseudoFS) throws {
        for toolset in toolsets {
            try fs.createDirectory(msvcDirectory(of: installation).join(toolset), recursive: true)
        }
    }

    private let buildTools = Path.root.join("Program Files (x86)").join("Microsoft Visual Studio").join("2022").join("BuildTools")
    private let community = Path.root.join("Program Files").join("Microsoft Visual Studio").join("2022").join("Community")

    @Test
    func picksLatestToolsetOfASingleInstallation() throws {
        let fs = PseudoFS()
        try addToolsets(["14.29.30133", "14.44.35207"], to: community, in: fs)
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: [try installation(path: community, version: "17.14.37906.3")], fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.44.35207"))
    }

    @Test
    func comparesToolsetVersionsNumerically() throws {
        let fs = PseudoFS()
        try addToolsets(["14.9.30000", "14.10.1", "14.2.99999"], to: community, in: fs)
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: [try installation(path: community, version: "17.14.37906.3")], fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.10.1"))
    }

    @Test
    func keepsToolsetFolderNameAsOnDisk() throws {
        // A folder name which parses as a version but does not print back to the same string, which would otherwise yield a path that does not exist.
        let fs = PseudoFS()
        try addToolsets(["14.044.1"], to: community, in: fs)
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: [try installation(path: community, version: "17.14.37906.3")], fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.044.1"))
        if let result {
            #expect(fs.exists(result))
        }
    }

    @Test
    func skipsInstallationWithoutVisualCppToolsetOfEqualVersion() throws {
        // Build Tools installed without the C++ workload has the same version as, and is reported before, the full installation.
        let fs = PseudoFS()
        try fs.createDirectory(buildTools, recursive: true)
        try addToolsets(["14.44.35207"], to: community, in: fs)
        let installations = [
            try installation(path: buildTools, version: "17.14.37906.3"),
            try installation(path: community, version: "17.14.37906.3"),
        ]
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.44.35207"))
    }

    @Test
    func skipsNewerInstallationWithoutVisualCppToolset() throws {
        let fs = PseudoFS()
        try fs.createDirectory(buildTools, recursive: true)
        try addToolsets(["14.40.33807"], to: community, in: fs)
        let installations = [
            try installation(path: buildTools, version: "17.14.37906.3"),
            try installation(path: community, version: "17.10.35013.160"),
        ]
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.40.33807"))
    }

    @Test
    func prefersNewestInstallationVersion() throws {
        let fs = PseudoFS()
        try addToolsets(["14.40.33807"], to: buildTools, in: fs)
        try addToolsets(["14.44.35207"], to: community, in: fs)
        let installations = [
            try installation(path: buildTools, version: "17.10.35013.160"),
            try installation(path: community, version: "17.14.37906.3"),
        ]
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.44.35207"))
    }

    @Test
    func keepsVswhereOrderForEqualVersionsWithToolsets() throws {
        let fs = PseudoFS()
        try addToolsets(["14.40.33807"], to: buildTools, in: fs)
        try addToolsets(["14.44.35207"], to: community, in: fs)
        let installations = [
            try installation(path: buildTools, version: "17.14.37906.3"),
            try installation(path: community, version: "17.14.37906.3"),
        ]
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: fs)
        #expect(result == msvcDirectory(of: buildTools).join("14.40.33807"))
    }

    @Test
    func ignoresEntriesWhichAreNotToolsetVersions() throws {
        let fs = PseudoFS()
        try addToolsets(["14.44.35207", "Preview", "readme"], to: community, in: fs)
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: [try installation(path: community, version: "17.14.37906.3")], fs: fs)
        #expect(result == msvcDirectory(of: community).join("14.44.35207"))
    }

    @Test
    func returnsNilWithoutAnyVisualCppToolset() throws {
        let fs = PseudoFS()
        try fs.createDirectory(buildTools, recursive: true)
        try fs.createDirectory(msvcDirectory(of: community), recursive: true)
        let installations = [
            try installation(path: buildTools, version: "17.14.37906.3"),
            try installation(path: community, version: "17.14.37906.3"),
        ]
        #expect(WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: fs) == nil)
        #expect(WindowsPlugin.latestMSVCToolsInstallDirectory(in: [], fs: fs) == nil)
    }

    /// Runs the lookup against the Visual Studio installations of the machine the tests run on.
    @Test(.requireHostOS(.windows))
    func findsToolsetAmongInstalledVisualStudios() async throws {
        let installations = try await VSInstallation.findInstallations(fs: localFS)
        let providingToolset = installations.filter { installation in
            let msvcDir = msvcDirectory(of: installation.installationPath)
            return ((try? localFS.listdir(msvcDir)) ?? []).contains { (try? Version($0)) != nil }
        }
        let result = WindowsPlugin.latestMSVCToolsInstallDirectory(in: installations, fs: localFS)
        if providingToolset.isEmpty {
            #expect(result == nil)
        } else {
            let toolsetDirectory = try #require(result)
            #expect(providingToolset.contains { msvcDirectory(of: $0.installationPath) == toolsetDirectory.dirname })
            #expect(localFS.isDirectory(toolsetDirectory))
        }
    }
}
