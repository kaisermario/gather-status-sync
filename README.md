# StatusSync

A small macOS menu bar app that keeps your status in sync between
[Gather](https://gather.town) (V2 desktop app) and Microsoft Teams — without any
Teams API, Graph permissions or admin consent.

- **Talking to someone in Gather** → Teams is set to *Do not disturb* with the
  status message "🍇 In einem Gather-Call".
- **In a Teams call** → Gather is set to *Busy* with the status "📞 Im Teams-Call".
- When the call ends, both are reset — but only if you haven't changed the
  status yourself in the meantime.

Everything happens in the background; neither app is brought to the front.

## How it works

| | Detect | Change |
|---|---|---|
| Teams | Microphone in use by Teams (CoreAudio per-process input, macOS 14+) | Teams UI via the Accessibility API and key events posted to the Teams process |
| Gather | Direct audio/video connection to another person | Gather's web app via the Chrome DevTools Protocol |

A call only counts after 5 seconds and ends 15 seconds after it was last seen.
What StatusSync changed is persisted, so it can still be undone after a crash.

## Requirements and limitations

- macOS 14 or later, the new Teams app ("Microsoft Teams", `com.microsoft.teams2`)
  and the Gather V2 desktop app.
- **Teams must use the German UI.** StatusSync finds the controls by their labels
  ("Nicht stören", "Status ändern", …). Other languages need the strings in
  `Teams.swift` adapted.
- The Teams window must be open (it may be in the background or on another screen).
- Teams UI automation can break with any Teams update.
- **Gather is restarted with `--remote-debugging-port=9333`.** StatusSync does this
  automatically once when Gather runs without it and is not using the microphone.
  While the port is open, **any local program can control Gather**.

## Build and install

```sh
./build.sh
```

This builds a release binary, wraps it in `StatusSync.app`, signs it ad hoc and
installs it to `/Applications`. Then:

1. Start StatusSync and allow it under *System Settings → Privacy & Security →
   Accessibility*.
2. Optionally enable *Beim Login starten* in the menu.

Because the app is signed ad hoc, macOS forgets the Accessibility permission after
every rebuild. If the menu still says the permission is missing although the toggle
is on, reset it and grant it again:

```sh
tccutil reset Accessibility mariokaiser.statussync.app
```

## Menu bar icon

A grape cluster after the Gather icon. A red dot means Teams is on *Do not disturb*
because of a Gather conversation, a purple dot means Gather is *Busy* because of a
Teams call, an orange dot means a problem (details in the menu). Crossed out means
paused; pausing or quitting resets everything StatusSync changed.

## License

MIT
