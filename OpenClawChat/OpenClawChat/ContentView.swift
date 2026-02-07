import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var vm: ChatViewModel

    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showPDFPicker = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(vm.isConnected ? "Conectado" : "Desconectado")
                    .font(.headline)
                Spacer()

                Button("📄") {
                    showPDFPicker = true
                }
                .disabled(!vm.isConnected)

                Button("📷") {
                    // Simulator typically has no camera. Fall back to photo library.
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        showPhotoLibrary = true
                    }
                }
                .disabled(!vm.isConnected)

                Button(vm.isConnected ? "Salir" : "Conectar") {
                    vm.isConnected ? vm.disconnect() : vm.connect()
                }
            }
            .padding(.horizontal)

            List(vm.messages, id: \.self) { msg in
                Text(msg)
                    .font(.body)
            }

            HStack {
                TextField("Escribe…", text: $vm.draft)
                    .textFieldStyle(.roundedBorder)
                Button("Enviar") { vm.sendText() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom)
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
                        vm.messages.append("❌ No pude codificar la imagen")
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
                        vm.messages.append("❌ No pude codificar la imagen")
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
                    // Use the current draft as the question to the PDF (optional)
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
                    // Give the WS handshake a moment before sending.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    vm.draft = autoMsg
                    vm.sendText()
                }
            }

            if env["OPENCLAW_AUTO_PDF_HELLO"] == "1" {
                if !vm.isConnected {
                    vm.connect()
                }

                // Wait for WS connect (not strictly required for /v1/responses,
                // but keeps the UI consistent).
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                let b64 = "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA1NSA+PgpzdHJlYW0KQlQKL0YxIDI0IFRmCjcyIDcyMCBUZAooSGVsbG8gT3BlbkNsYXcgUERGKSBUagpFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDM0NiAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQxNgolJUVPRgo="
                if let data = Data(base64Encoded: b64) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hello.pdf")
                    try? data.write(to: url, options: [.atomic])
                    vm.sendPDF(fileURL: url, prompt: "Resume este PDF en una frase.")
                } else {
                    vm.messages.append("❌ No pude decodificar el PDF de prueba")
                }
            }
        }
    }
}
