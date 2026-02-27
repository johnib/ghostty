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
        aiPromptState.currentTask?.cancel()
        aiPromptState.currentTask = nil
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

        guard endpoint.hasPrefix("https://") else {
            aiPromptState.isLoading = false
            aiPromptState.error = "AI endpoint must use HTTPS to protect your API key."
            return
        }

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
            "max_tokens": 128,
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
        let closeFn = onClose

        state.currentTask = Task {
            do {
                let command = try await Self.callAPI(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    payload: payloadData
                )

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    state.isLoading = false
                    Self.insertCommand(command, into: surface)
                    closeFn()
                }
            } catch is CancellationError {
                // User cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession cancelled via task cancellation
            } catch {
                await MainActor.run {
                    state.isLoading = false
                    state.error = error.localizedDescription
                }
            }
        }
    }

    private static func callAPI(
        endpoint: String,
        apiKey: String,
        payload: Data
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw AIPromptError.invalidResponse("Invalid endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apiError = json["error"] as? [String: Any],
               let message = apiError["message"] as? String {
                throw AIPromptError.apiError(message)
            }
            throw AIPromptError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIPromptError.invalidResponse("Failed to parse API response.")
        }

        if let apiError = json["error"] as? [String: Any],
           let message = apiError["message"] as? String {
            throw AIPromptError.apiError(message)
        }

        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw AIPromptError.invalidResponse("No text in API response.")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case requestFailed(String)
    case invalidResponse(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return msg
        case .invalidResponse(let msg): return msg
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
