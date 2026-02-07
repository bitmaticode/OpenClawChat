# Arquitectura mínima iOS (WS nativo) para OpenClaw

## Capas

### 1) Transport (`GatewayWebSocketClient`)
Responsable de:
- abrir/cerrar WS
- handshake (`connect.challenge` -> `connect`)
- multiplexar requests (`req/res`) por `id`
- exponer eventos (`event`)

### 2) Session/Chat (`ChatService`)
Responsable de:
- `chat.history`
- `chat.send`
- `chat.abort`
- stream de eventos `chat` (delta/final/error)

### 3) Attachments (`AttachmentPipeline`)
Responsable de:
- imágenes -> attachment base64 para WS
- no-imágenes -> fallback de ingesta textual/referencia

### 4) UI (SwiftUI)
Responsable de:
- estado de mensajes
- render streaming
- input de texto y picker de adjuntos

---

## Contrato WS mínimo

### Connect
```json
{
  "type":"req",
  "id":"...",
  "method":"connect",
  "params": {
    "minProtocol":3,
    "maxProtocol":3,
    "client":{"id":"openclaw-ios","version":"0.1.0","platform":"ios","mode":"ui"},
    "role":"operator",
    "scopes":["operator.read","operator.write"],
    "auth":{"token":"..."},
    "device":{"id":"...","publicKey":"...","signature":"...","signedAt":123,"nonce":"..."}
  }
}
```

### Send
```json
{
  "type":"req",
  "id":"...",
  "method":"chat.send",
  "params": {
    "sessionKey":"agent:codex:main",
    "message":"Hola",
    "attachments":[
      {"type":"image","mimeType":"image/jpeg","fileName":"x.jpg","content":"<base64>"}
    ],
    "idempotencyKey":"uuid"
  }
}
```

### Events chat
- `state = delta` -> streaming parcial
- `state = final` -> respuesta final
- `state = error|aborted` -> fin con error/cancelación

---

## Multimedia: realidad actual

- **Imágenes:** soportadas en `chat.send`.
- **Ficheros (pdf/doc/binarios):** no pasan por el parser WS de chat actual.

### Estrategia MVP recomendada
1. si es texto/markdown/json/csv/txt -> inline (con clipping)
2. si es binario -> subir a storage firmado + enviar URL contextual

### Estrategia V2 recomendada
- híbrido: WS para conversación + `/v1/responses` para `input_file` cuando toque fichero pesado

---

## Seguridad mínima

- No hardcodear token en app
- Guardar identidad en Keychain/Secure Enclave (no archivo plano en producción)
- Usar `wss://` (TLS)
- Rotar `idempotencyKey` por envío
- Aplicar timeouts por request
