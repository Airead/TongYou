import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal

@Suite("ServerMessage Tests")
struct ServerMessageTests {

    private static let dummySessionID = SessionID()
    private static let dummyPaneID = PaneID()

    private static var dummySnapshot: ScreenSnapshot {
        ScreenSnapshot(
            cells: [Cell](repeating: .empty, count: 4),
            columns: 2,
            rows: 2,
            cursorCol: 0,
            cursorRow: 0,
            cursorVisible: true,
            cursorShape: .block,
            selection: nil,
            scrollbackCount: 0,
            viewportOffset: 0,
            dirtyRegion: .full
        )
    }

    private static var dummyDiff: ScreenDiff {
        ScreenDiff(
            dirtyRows: [0],
            cellData: [Cell](repeating: .empty, count: 2),
            columns: 2,
            cursorCol: 0,
            cursorRow: 0,
            cursorVisible: true,
            cursorShape: .block
        )
    }

    @Test("screenFull is a screen update")
    func screenFullIsScreenUpdate() {
        let msg = ServerMessage.screenFull(Self.dummySessionID, Self.dummyPaneID, Self.dummySnapshot)
        #expect(msg.isScreenUpdate == true)
    }

    @Test("screenDiff is a screen update")
    func screenDiffIsScreenUpdate() {
        let msg = ServerMessage.screenDiff(Self.dummySessionID, Self.dummyPaneID, Self.dummyDiff)
        #expect(msg.isScreenUpdate == true)
    }

    @Test("sessionList is not a screen update")
    func sessionListNotScreenUpdate() {
        let msg = ServerMessage.sessionList([])
        #expect(msg.isScreenUpdate == false)
    }

    @Test("sessionCreated is not a screen update")
    func sessionCreatedNotScreenUpdate() {
        let info = SessionInfo(
            id: Self.dummySessionID,
            name: "test",
            tabs: [],
            activeTabIndex: 0
        )
        let msg = ServerMessage.sessionCreated(info)
        #expect(msg.isScreenUpdate == false)
    }

    @Test("sessionClosed is not a screen update")
    func sessionClosedNotScreenUpdate() {
        let msg = ServerMessage.sessionClosed(Self.dummySessionID)
        #expect(msg.isScreenUpdate == false)
    }

    @Test("titleChanged is not a screen update")
    func titleChangedNotScreenUpdate() {
        let msg = ServerMessage.titleChanged(Self.dummySessionID, Self.dummyPaneID, "title")
        #expect(msg.isScreenUpdate == false)
    }

    @Test("bell is not a screen update")
    func bellNotScreenUpdate() {
        let msg = ServerMessage.bell(Self.dummySessionID, Self.dummyPaneID)
        #expect(msg.isScreenUpdate == false)
    }

    @Test("paneExited is not a screen update")
    func paneExitedNotScreenUpdate() {
        let msg = ServerMessage.paneExited(Self.dummySessionID, Self.dummyPaneID, exitCode: 0)
        #expect(msg.isScreenUpdate == false)
    }

    @Test("layoutUpdate is not a screen update")
    func layoutUpdateNotScreenUpdate() {
        let msg = ServerMessage.layoutUpdate(Self.dummySessionID, .leaf(Self.dummyPaneID))
        #expect(msg.isScreenUpdate == false)
    }

    @Test("clipboardSet is not a screen update")
    func clipboardSetNotScreenUpdate() {
        let msg = ServerMessage.clipboardSet("text")
        #expect(msg.isScreenUpdate == false)
    }
}
