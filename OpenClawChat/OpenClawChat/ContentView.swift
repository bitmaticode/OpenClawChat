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
                                ChatBubbleView(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: vm.items.count) {
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
                ComposerBar(
                    text: $vm.draft,
                    isEnabled: vm.isConnected,
                    onPlus: { showPlusMenu = true },
                    onSend: { vm.sendText() }
                )
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
                    if let data = image.jpegData(compressionQuality: 0.85) {
                        vm.sendImage(jpegData: data, fileName: "camera.jpg", caption: vm.draft)
                        vm.draft = ""
                    } else {
                        vm.items.append(.init(sender: .system, text: "No pude codificar la imagen", style: .error))
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
                    if let data = image.jpegData(compressionQuality: 0.85) {
                        vm.sendImage(jpegData: data, fileName: "photo.jpg", caption: vm.draft)
                        vm.draft = ""
                    } else {
                        vm.items.append(.init(sender: .system, text: "No pude codificar la imagen", style: .error))
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
            vm.applySelectedAgent(newAgent)
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
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showDrawer = true
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
            }

            Text("Chat")
                .font(.headline)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(vm.isConnected ? "OK" : "OFF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}
