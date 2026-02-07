import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var vm: ChatViewModel

    @State private var showCamera = false
    @State private var showPhotoLibrary = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(vm.isConnected ? "Conectado" : "Desconectado")
                    .font(.headline)
                Spacer()

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
        }
    }
}
