import SwiftUI

struct SideMenuView: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var settings: AppSettings
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header
            HStack {
                Text("Ajustes")
                    .font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Scrollable settings
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Agente")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Picker("Agente", selection: $vm.selectedAgent) {
                                ForEach(AgentId.allCases) { agent in
                                    Text(agent.title).tag(agent)
                                }
                            }
                            .pickerStyle(.segmented)

                            if let d = vm.selectedAgent.detail {
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tema")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Picker("Tema", selection: Binding(
                                get: { settings.themeMode },
                                set: { settings.themeMode = $0 }
                            )) {
                                ForEach(ThemeMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gateway")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            SecureField("Token del gateway", text: $settings.gatewayToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)

                            Text("Se guarda en el llavero (Keychain). Si defines OPENCLAW_GATEWAY_TOKEN como env var, esa tendrá prioridad.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Conexión")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack {
                                Circle()
                                    .fill(vm.isConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(vm.isConnected ? "Conectado" : "Desconectado")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }

                            Button {
                                vm.isConnected ? vm.disconnect() : vm.connect()
                                close()
                            } label: {
                                Text(vm.isConnected ? "Desconectar" : "Conectar")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            // Fixed footer
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                    .padding(.bottom, 4)
                Text("OpenClawChat")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(vm.sessionKey)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
