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

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskConstruction
import Foundation

@Suite
fileprivate struct WindowsTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.windows), arguments: ["MD", "MDd", "MT", "MTd", ""])
    func windowsLibcFlags(runtime: String) async throws {
        try await withTemporaryDirectory { tmpDir in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "auto",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": swiftVersion,
                                    "CC": clangCompilerPath.str,
                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.c"),
                                TestBuildFile("SwiftFile.swift"),
                            ])
                        ])
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let buildParameters = BuildParameters(configuration: "Debug", overrides: runtime.nilIfEmpty.map { ["DEFAULT_USE_RUNTIME": $0] } ?? [:])
            await tester.checkBuild(buildParameters, runDestination: .windows, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("CompileC")) { task in
                    if runtime.hasSuffix("d") {
                        // Debug
                        task.checkCommandLineContains(["-D_DEBUG"])
                    } else {
                        // Release
                        task.checkCommandLineDoesNotContain("-D_DEBUG")
                    }

                    if runtime.hasPrefix("MD") || runtime == "" {
                        // Multithreaded DLL
                        task.checkCommandLineContains(["-D_DLL"])
                    } else {
                        // Multithreaded static
                        task.checkCommandLineDoesNotContain("-D_DLL")
                    }

                    // All runtimes are multithreaded
                    task.checkCommandLineContains(["-D_MT"])

                    let dependentLib =
                        switch runtime {
                        case "MDd": "msvcrtd"
                        case "MD": "msvcrt"
                        case "MTd": "libcmtd"
                        case "MT": "libcmt"
                        default: "msvcrt"
                        }
                    task.checkCommandLineContains(["-Xclang", "--dependent-lib=\(dependentLib)"])
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-libc", runtime.nilIfEmpty ?? "MD"])
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.windows))
    func windowsDualCompilationForDLL() async throws {
        try await withTemporaryDirectory { tmpDir in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyDLL",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "auto",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": swiftVersion,
                                    "SWIFT_COMPILE_ALSO_FOR_STATIC_LINKING": "YES",
                                ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SwiftFile.swift"),
                            ])
                        ])
                ])
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(BuildParameters(configuration: "Debug"), runDestination: .windows, fs: localFS) { results in
                // Collect all Swift compilation tasks for MyDLL.
                let compilationTasks = results.getTasks(.matchTargetName("MyDLL"), .matchRuleType("SwiftDriver Compilation"))
                #expect(compilationTasks.count == 2, "Expected two Swift compilation tasks for dual compilation")

                let hasStaticTask = compilationTasks.contains { task in
                    task.commandLine.contains(where: { $0 == ByteString(encodingAsUTF8: "-static") })
                }
                let hasDynTask = compilationTasks.contains { task in
                    !task.commandLine.contains(where: { $0 == ByteString(encodingAsUTF8: "-static") })
                }
                #expect(hasStaticTask, "Expected a -static compilation task")
                #expect(hasDynTask, "Expected a non-static (DLL) compilation task")

                // There should be a Libtool task producing the companion static archive.
                results.checkTask(.matchTargetName("MyDLL"), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineContains(["MyDLL-static.lib"])
                }

                results.checkNoDiagnostics()
            }
        }
    }
}
