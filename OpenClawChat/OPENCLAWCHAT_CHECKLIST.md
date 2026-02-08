# OpenClawChat — Checklist

1) Campo en ajustes para configurar URL de gateway.
2) Configurar GitHub para el proyecto.
3) Nueva feature de TTS nativo de iOS.
4) Revisar el envío de multimedia (fotos y ficheros).
   - Nota: el gateway WS tiene `policy.maxPayload = 512KB` (cierra con 1009 si el frame es grande). Como las imágenes van inline en JSON+base64, hay que comprimir/redimensionar para quedar muy por debajo (~300KB) o fallará con “Gateway disconnected”.
5) Autonectar al iniciar la App y al cambiar de agente.
6) Persistencia de mensajes.
7) Añadir opciones con “/“ estilo bot de Telegram.
8) Revisar el TTS de la app.
