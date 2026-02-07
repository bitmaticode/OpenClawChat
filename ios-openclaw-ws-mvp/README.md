# OpenClaw WS Native iOS MVP

Arquitectura mínima (pero seria) para una app iOS conectada al Gateway de OpenClaw por **WebSocket nativo**.

## Objetivo

- Chat en tiempo real con streaming (`delta` / `final`)
- Soporte multimedia:
  - ✅ imágenes (attachment base64 por WS `chat.send`)
  - ⚠️ ficheros no imagen: estrategia de fallback (ingesta a texto / referencia por enlace)

---

## Qué incluye

- `GatewayProtocol.swift`
  - Tipos de frames WS (`req`, `res`, `event`)
  - Tipos de `connect`, `chat.send`, `chat.history`, `chat.abort`
- `DeviceIdentity.swift`
  - Identidad de dispositivo + firma Ed25519 del `connect.challenge`
- `GatewayWebSocketClient.swift`
  - Cliente WS con handshake, request/response, manejo de eventos
- `AttachmentPipeline.swift`
  - Pipeline de adjuntos (imagen + fallback de ficheros)
- `ChatService.swift`
  - API de alto nivel para historial/envío/abort + stream de eventos de chat

---

## Flujo WS

1. Gateway envía `event: connect.challenge`
2. iOS firma payload v2 con su clave de dispositivo
3. iOS manda `req: connect`
4. Gateway responde `res: hello-ok`
5. iOS usa `chat.send`, `chat.history`, `chat.abort`
6. iOS recibe eventos `chat` en streaming

---

## Uso rápido (conceptual)

```swift
let identityURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("openclaw/device.json")
let identity = try DeviceIdentityStore.loadOrCreate(storageURL: identityURL)

let wsURL = URL(string: "wss://TU_HOST:18789")!
let client = GatewayWebSocketClient(
    configuration: .init(url: wsURL, token: "TU_GATEWAY_TOKEN"),
    identity: identity
)

let chat = ChatService(client: client)
let hello = try await chat.connect()
print("Conectado. Métodos disponibles: \(hello.features.methods.count)")

let stream = await chat.streamChatEvents()
Task {
    for await event in stream {
        print("[\(event.state)] run=\(event.runId)")
    }
}

_ = try await chat.send(sessionKey: "agent:codex:main", text: "Hola")
```

---

## Limitación actual (importante)

En `chat.send` del Gateway, los adjuntos procesables por WS hoy son imágenes.

Para PDFs/docs/otros binarios en este MVP:
- se hace fallback a texto extraído (si aplica), o
- se añade referencia textual para análisis por enlace.

> Si quieres manejo binario completo de ficheros, la vía más robusta hoy es combinar WS para chat + `/v1/responses` para `input_file`.

---

## Siguiente paso recomendado

- Integrarlo en SwiftUI (`ChatViewModel` + `MessageStore` local)
- Reconexión automática con backoff
- Persistir identidad en Keychain (en vez de archivo)
- Subida de archivos a storage firmado + envío de URL contextual
