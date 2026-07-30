<div align="center">
<img width="1200" height="475" alt="GHBanner" src="https://github.com/user-attachments/assets/0aa67016-6eaf-458a-adb2-6e31a0763ed6" />
</div>

# Aid'Habitat Manager

## Run locally

**Prerequisites:** Node.js

1. Install dependencies: `npm install`
2. Run the app: `npm run dev`

## Local note rewriting

The Express API can reformulate written notes with the locally hosted
`gemma3:4b` model. Note contents stay between the application backend and
Ollama.

1. Install Ollama: `brew install ollama`
2. Start it at login: `brew services start ollama`
3. Download the model: `ollama pull gemma3:4b`
4. Check the service: `curl http://127.0.0.1:11434/api/tags`

Authenticated endpoints:

- `GET /api/ai/status`
- `POST /api/ai/rewrite` with `{ "text": "...", "mode": "professional" }`

Available modes are `professional`, `concise`, and `correct`.

Optional server variables:

- `OLLAMA_BASE_URL` defaults to `http://127.0.0.1:11434`
- `OLLAMA_REWRITE_MODEL` defaults to `gemma3:4b`
- `OLLAMA_REWRITE_TIMEOUT_MS` defaults to `120000`
