import AppKit
import ArgumentParser

/// A Model Context Protocol server for coding agents, which talks to them over standard input and output.
///
/// Add it to Claude Code with `claude mcp add hypervisaur -- "/Applications/Hypervisaur.app/Contents/MacOS/vbmcp"`.
struct VBMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vbmcp",
        abstract: "A Model Context Protocol server for creating and running virtual machines in Hypervisaur."
    )

    func run() async throws {
        // vbmcp lives in the app bundle and talks to the app through NSWorkspace, so without this every MCP
        // client that starts it gets its own Hypervisaur icon in the Dock for as long as the client runs.
        await MainActor.run { _ = NSApplication.shared.setActivationPolicy(.prohibited) }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let server = MCPServer(
            name: "hypervisaur",
            version: version,
            instructions: VirtualMachineTools.instructions,
            tools: VirtualMachineTools.all
        )

        await server.run()
    }
}
