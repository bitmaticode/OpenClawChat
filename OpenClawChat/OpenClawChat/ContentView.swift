import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var vm: ChatViewModel
    @ObservedObject var settings: AppSettings

    @Environment(\.scenePhase) private var scenePhase

    @State private var showDrawer = false

    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showPDFPicker = false
    @State private var showPlusMenu = false

    @StateObject private var stt = LocalSTTManager()

    // UX: only autoscroll if the user hasn't dragged up.
    @State private var autoScrollEnabled = true

    var body: some View {
        DrawerContainer(
            isOpen: $showDrawer,
            menu: AnyView(
                SideMenuView(vm: vm, settings: settings) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showDrawer = false
                    }
                }
            )
        ) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemBackground),
                        Color(uiColor: .secondarySystemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.items) { item in
                                ChatBubbleView(item: item, isStreaming: vm.streamingBubbleId == item.id)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { _ in
                                autoScrollEnabled = false
                            }
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if !autoScrollEnabled {
                            Button {
                                guard let last = vm.items.last else { return }
                                autoScrollEnabled = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .padding(12)
                            }
                        }
                    }
                    .onChange(of: vm.items.count) {
                        guard autoScrollEnabled else { return }
                        guard let last = vm.items.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top) {
                topBar
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let palette = commandPalette {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(palette) { cmd in
                                Button {
                                    vm.draft = cmd.template
                                } label: {
                                    HStack {
                                        Text(cmd.template)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(cmd.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)

                                Divider().opacity(0.25)
                            }
                        }
                        .background(.thinMaterial)
                    }

                    ComposerBar(
                        text: $vm.draft,
                        isEnabled: vm.isConnected,
                        isRecording: stt.isRecording,
                        isMicEnabled: stt.isRecording || (!stt.isTranscribing && vm.isConnected),
                        onPlus: { showPlusMenu = true },
                        onMic: { handleMicTap() },
                        onSend: { handleSend() }
                    )
                }
            }
        }
        .confirmationDialog("Adjuntar", isPresented: $showPlusMenu, titleVisibility: .visible) {
            Button("PDF") { showPDFPicker = true }
            Button("Cámara") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    showPhotoLibrary = true
                }
            }
            Button("Fotos") { showPhotoLibrary = true }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                source: .camera,
                onImage: { image in
                    showCamera = false
                    do {
                        let data = try ImageUploadEncoder.encodeJPEG(image)
                        vm.sendImage(jpegData: data, fileName: "camera.jpg", caption: vm.draft)
                        vm.draft = ""
                    } catch {
                        vm.items.append(.init(sender: .system, text: "No pude preparar la imagen: \(error.localizedDescription)", style: .error))
                    }
                },
                onCancel: {
                    showCamera = false
                }
            )
        }
        .sheet(isPresented: $showPhotoLibrary) {
            CameraPicker(
                source: .photoLibrary,
                onImage: { image in
                    showPhotoLibrary = false
                    do {
                        let data = try ImageUploadEncoder.encodeJPEG(image)
                        vm.sendImage(jpegData: data, fileName: "photo.jpg", caption: vm.draft)
                        vm.draft = ""
                    } catch {
                        vm.items.append(.init(sender: .system, text: "No pude preparar la imagen: \(error.localizedDescription)", style: .error))
                    }
                },
                onCancel: {
                    showPhotoLibrary = false
                }
            )
        }
        .sheet(isPresented: $showPDFPicker) {
            DocumentPicker(
                allowedTypes: [.pdf],
                onPick: { url in
                    showPDFPicker = false
                    let q = vm.draft
                    vm.draft = ""
                    vm.sendPDF(fileURL: url, prompt: q)
                },
                onCancel: {
                    showPDFPicker = false
                }
            )
        }
        .onChange(of: vm.selectedAgent) { _, newAgent in
            vm.applySelectedAgent(newAgent, shouldAutoConnect: settings.shouldAutoConnect)
        }
        .onChange(of: settings.ttsEnabled) { _, enabled in
            vm.setTTSEnabled(enabled)
        }
        .onChange(of: settings.gatewayToken) { _, _ in
            vm.reconfigureConnection(gatewayURL: settings.gatewayURL, token: settings.gatewayToken)
        }
        .onChange(of: settings.gatewayURLString) { _, _ in
            vm.reconfigureConnection(gatewayURL: settings.gatewayURL, token: settings.gatewayToken)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, settings.shouldAutoConnect, !vm.isConnected {
                vm.connect()
            }
        }
        .task {
            vm.setTTSEnabled(settings.ttsEnabled)

            stt.onPartial = { partialText in
                DispatchQueue.main.async {
                    self.vm.draft = partialText
                }
            }

            stt.onFinal = { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                DispatchQueue.main.async {
                    self.vm.draft = trimmed
                    self.handleSend()
                }
            }

            // Smoke-test helpers (only active when env vars are set)
            let env = ProcessInfo.processInfo.environment

            if env["OPENCLAW_UI_DRAWER_OPEN"] == "1" {
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showDrawer = true
                }
            }

            // Real autoconnect (preferred).
            if settings.shouldAutoConnect {
                vm.connect()
            }

            // Legacy smoke-test path.
            if env["OPENCLAW_AUTOCONNECT"] == "1" {
                if !vm.isConnected { vm.connect() }

                if let autoMsg = env["OPENCLAW_AUTO_MESSAGE"], !autoMsg.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    vm.draft = autoMsg
                    vm.sendText()
                }
            }

            if env["OPENCLAW_AUTO_PDF_HELLO"] == "1" {
                if !vm.isConnected { vm.connect() }
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                let b64 = "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA1NSA+PgpzdHJlYW0KQlQKL0YxIDI0IFRmCjcyIDcyMCBUZAooSGVsbG8gT3BlbkNsYXcgUERGKSBUagpFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDM0NiAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQxNgolJUVPRgo="
                if let data = Data(base64Encoded: b64) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hello.pdf")
                    try? data.write(to: url, options: [.atomic])
                    vm.sendPDF(fileURL: url, prompt: "Resume este PDF en una frase.")
                } else {
                    vm.items.append(.init(sender: .system, text: "No pude decodificar el PDF de prueba", style: .error))
                }
            }
        }
    }

    private var topBar: some View {
        ZStack {
            // Centered title
            Text("Chat \(vm.selectedAgent.shortTitle)")
                .font(.headline)

            // Left / right controls
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showDrawer = true
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .semibold))
                }

                Spacer()

                if vm.isStreaming {
                    Text("escribiendo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if stt.isLoadingModel {
                    Text(stt.statusMessage.isEmpty ? "cargando modelo…" : stt.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if stt.isRecording {
                    Text("grabando…")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if stt.isTranscribing {
                    Text("transcribiendo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if vm.isStreaming {
                    Button {
                        vm.abort()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(vm.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(vm.isConnected ? "OK" : "OFF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    // MARK: - Commands (/)

    private struct CommandItem: Identifiable {
        let id = UUID()
        let template: String
        let title: String
    }

    private var commandPalette: [CommandItem]? {
        let t = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }

        let all: [CommandItem] = [
            .init(template: "/help", title: "Ayuda"),
            .init(template: "/agent opus", title: "Cambiar agente"),
            .init(template: "/agent codex", title: "Cambiar agente"),
            .init(template: "/agent main", title: "Cambiar agente"),
            .init(template: "/clear", title: "Borrar historial"),
            .init(template: "/reconnect", title: "Reconectar"),
            .init(template: "/tts on", title: "TTS"),
            .init(template: "/tts off", title: "TTS")
        ]

        if t == "/" { return Array(all.prefix(6)) }

        let filtered = all.filter { $0.template.hasPrefix(t) }
        return filtered.isEmpty ? nil : filtered
    }

    private func handleSend() {
        let text = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.hasPrefix("/") {
            runCommand(text)
            vm.draft = ""
            return
        }

        vm.sendText()
    }

    private func handleMicTap() {
        Task { @MainActor in
            do {
                if stt.isRecording {
                    stt.stopStreaming(sendPending: true)
                } else {
                    try await stt.startStreaming()
                }
            } catch {
                vm.items.append(.init(sender: .system, text: "STT local: \(error.localizedDescription)", style: .error))
            }
        }
    }

    private func runCommand(_ raw: String) {
        // Show command in chat for transparency.
        vm.items.append(.init(sender: .user, text: raw))

        let parts = raw.split(separator: " ").map(String.init)
        let cmd = parts.first?.lowercased() ?? raw.lowercased()
        let arg = parts.dropFirst().first?.lowercased()

        switch cmd {
        case "/help":
            vm.items.append(.init(sender: .system, text: "Comandos:\n- /agent opus|codex|main\n- /clear\n- /reconnect\n- /tts on|off", style: .status))

        case "/agent":
            guard let arg else {
                vm.items.append(.init(sender: .system, text: "Uso: /agent opus|codex|main", style: .error))
                return
            }
            if let agent = AgentId(rawValue: arg) {
                vm.selectedAgent = agent
            } else {
                vm.items.append(.init(sender: .system, text: "Agente inválido: \(arg)", style: .error))
            }

        case "/clear":
            vm.clearThread()

        case "/reconnect":
            vm.reconnect()

        case "/tts":
            guard let arg else {
                vm.items.append(.init(sender: .system, text: "Uso: /tts on|off", style: .error))
                return
            }
            switch arg {
            case "on", "1", "true":
                settings.ttsEnabled = true
                vm.setTTSEnabled(true)
                vm.items.append(.init(sender: .system, text: "TTS activado", style: .status))
            case "off", "0", "false":
                settings.ttsEnabled = false
                vm.setTTSEnabled(false)
                vm.items.append(.init(sender: .system, text: "TTS desactivado", style: .status))
            default:
                vm.items.append(.init(sender: .system, text: "Uso: /tts on|off", style: .error))
            }

        default:
            vm.items.append(.init(sender: .system, text: "Comando desconocido. Usa /help", style: .error))
        }
    }
}
