# owui-ios

An iOS client for [Open WebUI](https://github.com/open-webui/open-webui): the chat is the official web app in a
WebView, plus a native realtime voice call that can be started from the Action button and shows its state in the
Dynamic Island.

- **Chat**: the server's own web UI. The app reads the signed-in token from the page; nothing is configured at build time.
- **Voice**: OWUI's Realtime ("Bridge") call. The voice model listens and speaks; substantive requests are delegated to
  the chosen chat model with its tools (MCP, web search, memory), and every turn is saved to a chat you can review.
- **Background**: keeps running with the screen locked or in another app; Live Activity with mute / open / end.

Requires Open WebUI 0.12 with Realtime calls enabled by the admin. See [INSTALL.md](INSTALL.md) to build and install
with a free Apple ID.
