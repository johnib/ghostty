import SwiftUI
import GhosttyKit

struct AIPromptOverlay: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var aiPromptState: Ghostty.SurfaceView.AIPromptState
    let ghosttyConfig: Ghostty.Config
    let onClose: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                // Error message
                if let error = aiPromptState.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 8) {
                    // AI badge
                    Text("AI")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple)
                        .cornerRadius(4)

                    if aiPromptState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating command...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                    } else {
                        TextField("Describe a command...", text: $aiPromptState.prompt)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .focused($isInputFocused)
                            .onSubmit {
                                submitPrompt()
                            }
                            #if canImport(AppKit)
                            .onExitCommand {
                                cancelAndClose()
                            }
                            #endif
                    }

                    // Close button
                    Button(action: { cancelAndClose() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onAppear {
            isInputFocused = true
        }
    }

    private func cancelAndClose() {
        aiPromptState.currentProcess?.terminate()
        aiPromptState.currentProcess = nil
        onClose()
    }

    private func submitPrompt() {
        let prompt = aiPromptState.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        guard let apiKey = ghosttyConfig.aiApiKey, !apiKey.isEmpty else {
            aiPromptState.error = "No API key configured. Set ai-api-key in your Ghostty config."
            return
        }

        aiPromptState.isLoading = true
        aiPromptState.error = nil

        let model = ghosttyConfig.aiModel ?? "claude-sonnet-4-20250514"
        let endpoint = ghosttyConfig.aiEndpoint ?? "https://api.anthropic.com/v1/messages"

        // Gather context
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let pwd = surfaceView.pwd ?? "unknown"

        let systemPrompt = """
        You are a command-line assistant. The user will describe what they want to do, \
        and you must respond with ONLY the shell command to accomplish it. Do not include \
        any explanation, markdown formatting, or code blocks. Just output the raw command.

        Operating system: \(osString)
        Shell: \(shell)
        Current working directory: \(pwd)
        """

        // Build the JSON payload
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            aiPromptState.isLoading = false
            aiPromptState.error = "Failed to build request."
            return
        }

        let state = aiPromptState
        let surface = surfaceView

        Task.detached {
            do {
                let command = try await Self.runCurl(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    payload: payloadData,
                    state: state
                )

                await MainActor.run {
                    state.isLoading = false
                    Self.insertCommand(command, into: surface)
                    onClose()
                }
            } catch is CancellationError {
                // User cancelled
            } catch {
                await MainActor.run {
                    state.isLoading = false
                    state.error = error.localizedDescription
                }
            }
        }
    }

    private static func runCurl(
        endpoint: String,
        apiKey: String,
        payload: Data,
        state: Ghostty.SurfaceView.AIPromptState
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "-s",
                "-X", "POST",
                endpoint,
                "-H", "Content-Type: application/json",
                "-H", "x-api-key: \(apiKey)",
                "-H", "anthropic-version: 2023-06-01",
                "-d", "@-"
            ]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            DispatchQueue.main.async {
                state.currentProcess = process
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Write payload to stdin then close
            stdinPipe.fileHandleForWriting.write(payload)
            stdinPipe.fileHandleForWriting.closeFile()

            process.waitUntilExit()

            DispatchQueue.main.async {
                state.currentProcess = nil
            }

            guard process.terminationStatus == 0 else {
                continuation.resume(throwing: AIPromptError.curlFailed(
                    "curl exited with status \(process.terminationStatus)"
                ))
                return
            }

            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                continuation.resume(throwing: AIPromptError.invalidResponse("Failed to parse API response."))
                return
            }

            // Check for API error
            if let apiError = json["error"] as? [String: Any],
               let message = apiError["message"] as? String {
                continuation.resume(throwing: AIPromptError.apiError(message))
                return
            }

            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                continuation.resume(throwing: AIPromptError.invalidResponse("No text in API response."))
                return
            }

            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(returning: command)
        }
    }

    private static func insertCommand(_ command: String, into surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        ghostty_surface_text(
            surface,
            command,
            UInt(command.utf8.count)
        )
    }
}

enum AIPromptError: LocalizedError {
    case curlFailed(String)
    case invalidResponse(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .curlFailed(let msg): return msg
        case .invalidResponse(let msg): return msg
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
