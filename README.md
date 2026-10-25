# foobar2000 Discord Rich Presence (alternating status)

A small PowerShell script that shows what you are playing in [foobar2000](https://www.foobar2000.org) on Discord, without installing any foobar2000 component.

What makes it different: the short status line under your name in the member list **alternates every few seconds** between the app name (`foobar2000`) and the song title, while the "Listening to" card stays put.

## Features

- **Listening to foobar2000** card, laid out like [foo_discord_rich](https://github.com/TheQwertiest/foo_discord_rich):
  - **Title** (bold)
  - `by` album artist
  - `on` album
- Album cover looked up on [MusicBrainz](https://musicbrainz.org) / [Cover Art Archive](https://coverartarchive.org), cached per album, retried if MusicBrainz is busy.
- Elapsed time of the current song (time spent paused is not counted).
- Status line under your name alternates between `foobar2000` and the song title (uses Discord's `status_display_type`).
- Clears the presence when playback is paused or stopped, reconnects if Discord restarts, and refuses to run twice.

## How it works

foobar2000 writes the current song into its window title. The script reads that title once a second and talks to the Discord desktop app through its local IPC pipe (`\\.\pipe\discord-ipc-0`). Nothing is sent anywhere else except the MusicBrainz / Cover Art Archive lookups for covers.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- Discord desktop app
- foobar2000 (tested with v2.x and Columns UI)

## Setup

1. **Create a Discord application.** Go to the [Discord Developer Portal](https://discord.com/developers/applications), click *New Application* and name it `foobar2000`. That name is what Discord shows as "Listening to foobar2000". Copy the **Application ID** from *General Information*.
   Optional: under *Rich Presence → Art Assets* upload a foobar2000 logo with the key `foobar2000`. It is used when no album cover is found.

2. **Create `config.json`.** Copy `config.example.json` to `config.json` and paste your Application ID:

   ```json
   {
     "clientId": "YOUR_DISCORD_APPLICATION_ID",
     "intervalSeconds": 10,
     "largeImageKey": "foobar2000"
   }
   ```

   | Setting | Meaning |
   |---|---|
   | `clientId` | Your Discord Application ID (required) |
   | `intervalSeconds` | Seconds each text stays in the status line (default 20) |
   | `largeImageKey` | Art asset key shown when no cover is found (optional) |

3. **Set the foobar2000 window title.** The script expects `Title · Album artist · Album - foobar2000`, with `(paused) ` in front while paused. Paste this formatting script:

   ```
   $if(%isplaying%,$if(%ispaused%,(paused) ,)%title% · $if2(%album artist%,%artist%) · %album% - ,)foobar2000
   ```

   - Columns UI: *Preferences → Display → Columns UI → Main window → Main window title formatting script*
   - Default UI: *Preferences → Display → Default User Interface → Window title* (not tested)

4. **Turn off other Rich Presence plugins.** If you use foo_discord_rich, untick *Enable Rich Presence* in its preferences, otherwise both fight over your status.

5. **Run it.** Double-click `start.cmd`. It starts the script hidden in the background.
   To start it with Windows, press <kbd>Win</kbd>+<kbd>R</kbd>, type `shell:startup` and put a shortcut to `start.cmd` there.

To stop it, end the `powershell.exe` process that runs `foobar-discord-rpc.ps1` (Task Manager → Details, add the *Command line* column).

## Troubleshooting

The script writes `log.txt` next to itself: connection, every presence update, cover lookups and errors. It is trimmed automatically when it grows past 200 KB.

## Limitations

- Elapsed time is counted by the script, not read from foobar2000. Seeking inside a song is not reflected, and if the script starts in the middle of a song it counts from 0.
- Song data comes from the window title. A title that itself contains ` · ` can be split in the wrong place.
- Covers depend on MusicBrainz matching the artist and album tags.
- The alternating status line relies on `status_display_type`, which needs a recent Discord client. Older clients show the app name only.

## Credits

- The card layout and the MusicBrainz cover lookup follow [foo_discord_rich](https://github.com/TheQwertiest/foo_discord_rich) by TheQwertiest.
- Covers from [MusicBrainz](https://musicbrainz.org) and the [Cover Art Archive](https://coverartarchive.org).

## License

[MIT](LICENSE)
