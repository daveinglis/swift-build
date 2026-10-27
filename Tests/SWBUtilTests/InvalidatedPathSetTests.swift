//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBUtil

@Suite fileprivate struct InvalidatedPathSetTests {
    @Test
    func insertRecordsDirectoryAndAncestors() {
        let set = InvalidatedPathSet()
        #expect(set.allPaths.isEmpty)
        #expect(set.insert(directory: Path("/a/b/c")) == ["/a/b/c", "/a/b", "/a", "/"])
        #expect(Set(set.allPaths) == ["/a/b/c", "/a/b", "/a", "/"])
    }

    @Test
    func insertReturnsOnlyNewPaths() {
        let set = InvalidatedPathSet()
        _ = set.insert(directory: Path("/a/b/c"))
        // A sibling shares every ancestor, so only the directory itself is new.
        #expect(set.insert(directory: Path("/a/b/d")) == ["/a/b/d"])
        // An ancestor which is already recorded adds nothing.
        #expect(set.insert(directory: Path("/a/b")) == [])
        #expect(set.insert(directory: Path("/a/b/c")) == [])
        #expect(Set(set.allPaths) == ["/a/b/c", "/a/b/d", "/a/b", "/a", "/"])
    }

    @Test
    func insertingRootTerminates() {
        let set = InvalidatedPathSet()
        #expect(set.insert(directory: Path.root) == ["/"])
        #expect(set.insert(directory: Path.root) == [])
    }
}
