# Universal Chat Translator

Translates incoming and outgoing chat messages in real time using a [LibreTranslate](https://libretranslate.com/) instance. Supports over 50 languages.

## Installation

Copy https://github.com/WybrenKoelmans/BAR-Widgets/tree/main/gui_translate_chat/gui_translate_chat.lua to the widget directory.

By default this widget uses a public community LibreTranslate server. If you'd rather self-host for better privacy or reliability:

1. Install and run your own LibreTranslate instance by following the official guide: [docs.libretranslate.com/guides/installation](https://docs.libretranslate.com/guides/installation/). By default LibreTranslate listens on port `5000`, which is what this widget expects.
2. In-game, open the custom options menu (**Settings → Custom Options**) and find the **Translate Chat** section.
3. Disable **Use (public) community server** to point the widget at your local server (`localhost:5000`).
4. Set **Incoming** to the language you want other players' messages translated into, and **Outgoing** to the language you want your own messages translated into before being sent. If you only ever type in English, please set **Outgoing** to **Off**, there's no need to translate English to English, and it saves a requests to the translation server.
5. Optionally enable **Replace original messages** to replace the original chat line with the translation instead of showing it as a separate line (see Known Issues below).

## Features

- **Incoming translation** — translates messages from other players into your chosen language. Translated lines are shown inline, prefixed with `[T]`.
- **Outgoing translation** — translates your own messages before sending them to the channel, so other players receive the translation instead.
- **Channel-aware** — respects ally, spectator, and all-chat modes when re-sending translated outgoing messages.
- **Public or local server** — connects to the community-hosted LibreTranslate server by default, or a local instance running on `localhost:5000`.
- **Replace original messages** — optionally replaces the original chat line with the translation instead of appending a new line.

## Not (yet) LLM/AI-based

LibreTranslate uses traditional, lightweight machine translation models rather than an LLM. This keeps resource requirements low, so it's easy to self-host on your own PC if you'd rather not rely on the public server. However, LibreTranslate has no idea what BAR is, so things like "figs" will get translated as the fruit, not "fighter planes".

I may add a LLM based solution later if wanted.

## Privacy

Every chat message you send or receive is sent to the configured LibreTranslate server for translation. Using the public community server means **all your chat messages leave your machine and are visible to that server and send without encryption** — forfeiting any privacy over your chat contents. If privacy matters to you, run your own local LibreTranslate instance instead (see "Use (public) community server" option).

## Known Issues

### Map markers become unclickable when "Replace original messages" is enabled

When the replace mode is active, translated map-mark messages overwrite the original chat line. This causes the clickable map-marker link in the chat to stop working.

**Workaround:** click the **!** (exclamation mark) button next to the player list to jump to the map marker location instead.
