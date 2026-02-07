import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var vm: ChatViewModel

    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showPDFPicker = false

    var body: some View {
        NavigationStack {
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
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: vm.items.count) {
                        guard let last = vm.items.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("OpenClawChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.isConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(vm.isConnected ? "Conectado" : "Desconectado")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPDFPicker = true
                    } label: {
                        Image(systemName: "doc")
                    }
                    .disabled(!vm.isConnected)

                    Button {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCamera = true
                        } else {
                            showPhotoLibrary = true
                        }
                    } label: {
                        Image(systemName: "camera")
                    }
                    .disabled(!vm.isConnected)

                    Button {
                        vm.isConnected ? vm.disconnect() : vm.connect()
                    } label: {
                        Text(vm.isConnected ? "Salir" : "Conectar")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBar(text: $vm.draft, isEnabled: vm.isConnected) {
                    vm.sendText()
                }
            }
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
        .task {
            // Smoke-test helpers (only active when env vars are set)
            let env = ProcessInfo.processInfo.environment
            if env["OPENCLAW_AUTOCONNECT"] == "1" {
                vm.connect()

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
}
