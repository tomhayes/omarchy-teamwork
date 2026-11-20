# Teamwork timers for Omarchy

A bar widget for [Teamwork.com](https://www.teamwork.com) time tracking in the [Omarchy](https://omarchy.org) shell. The running timer and its task tick in the bar; the panel lets you start, pause, log and discard timers, log time by hand, and see how much of your work time today and this week is accounted for. It nudges you when nothing is timing during work hours.

![The Teamwork panel open under the bar](preview.png)

## Install

```bash
omarchy plugin add https://github.com/tomhayes/omarchy-teamwork --enable
```

Requires `python3` (standard library only), `notify-send`, `xdg-open`, and optionally `secret-tool` (libsecret) for keyring storage. All ship with Omarchy.

## Remove

1. In the panel's **Settings**, press **Remove** next to the API key. It deletes the key from the keyring and the fallback file (under the current and the old `tom.teamwork` id) and its site binding, then looks again: it says **API key removed** only when no copy is left, and otherwise shows an error with **Retry** (for example while the keyring is locked or unreachable). By hand: `secret-tool clear service tomhayes.teamwork account api-key`.
2. Remove the plugin. This disables it and deletes its folder:

   ```bash
   omarchy plugin remove tomhayes.teamwork
   ```

   If its entry (with your settings) is still in `bar.layout` in `~/.config/omarchy/shell.json`, delete the `tomhayes.teamwork` object there.

3. Optionally delete its cache and state: `rm -rf ~/.cache/tomhayes.teamwork ~/.local/state/tomhayes.teamwork`.

The plugin writes nothing outside those two folders (the state folder holds the site binding, and the key itself only without a keyring), the keyring entry and its own bar entry in `~/.config/omarchy/shell.json`.

## First run

1. Click the timer icon in the bar. The panel opens on **Settings**.
2. Enter your site address, `https://<yours>.teamwork.com` (https only, no path).
3. Paste your API key and press **Connect**. Find it in Teamwork under your profile, *Edit my details*, *API & Mobile*. Connect checks the key with that site, stores it, binds it to the site, and saves the site: one step.

The key goes to `bin/teamwork set-key` on stdin and is stored in the Secret Service keyring (`secret-tool`, attributes `service tomhayes.teamwork account api-key`). Without a keyring it falls back to `~/.local/state/tomhayes.teamwork/api-key` (mode 0600, directory 0700), and Settings says so. **Remove** deletes it.

### The key is bound to its site

The key is bound to the site it was checked against: `~/.local/state/tomhayes.teamwork/site` (0600) records that site and a SHA-256 fingerprint of the key (never the key, and never in `shell.json`). `bin/teamwork` checks the binding before every request that sends the key and refuses (`site-mismatch`) without contacting anything when the site in Settings is a different one, or the stored key isn't the one that was bound.

So if you change the site URL, the widget stops polling and Settings says **Reconnect: enter the API key for this site**. Paste the key for the new site and press **Connect**; it's checked with the new site and bound to it. Changing the site back to the one the key is bound to reconnects without re-entering it.

**Upgrading from 1.0.0**, whose key has no binding yet: when the shell starts, the widget asks `bin/teamwork bind-legacy` to bind the saved key to the site already in your settings, so you don't have to enter it again. The helper does that once, and only when all of these hold: no binding file exists at all (so never after Connect or Remove), the site is one of Teamwork's own addresses (`<name>.teamwork.com` or `<name>.eu.teamwork.com`), and the cache shows this install has already used a key with that exact site. It then checks the key there (`GET me.json`) before binding it. It's never tried after the site has been changed. Otherwise (a custom domain, a cleared cache, a site changed in the meantime) Settings asks you to reconnect.

## Using it

- **Bar**: the glyph pauses or resumes the current timer (with none, it restarts the last task); the text or a right click opens the panel; a middle click refreshes. While nothing is timing during work hours the pill is tinted toward the urgent colour.
- **Current timer**: pause/resume, **Log it** (completes the timer as a time entry, with an optional description), **Discard** (asks first), open in Teamwork. The log and discard forms stay with the timer they were opened for: a refresh that changes the current timer meanwhile doesn't retarget them, and if that timer is gone (logged or deleted elsewhere) the form closes with a note and nothing is done.
- **Today / This week**: time logged plus unlogged timer time, against the work time elapsed so far and the full day or week, with a bar per work day.
- **Tasks**: your open assigned tasks plus anything with a timer or time logged this week, grouped by due date (Timers, Today, Overdue, Tomorrow, This week, Next week, Later, No due date). Filter locally; press Enter with no local match to search Teamwork. Each row can start a timer, log time by hand, or open the task.
- **Sort field** (optional): name a Teamwork task custom field and its value shows as a badge on each task; tasks whose value starts with a number ("1st", "2", "#3") sort first in their group, lowest first.

Keys in the panel: `p` pause/resume, `/` or `f` filter, `s` settings, `r` refresh, Up/Down or `j`/`k` scroll, Esc backs out.

## Settings

Edited in the panel's Settings (the cog) or the stock Omarchy widget settings, and saved to the widget's entry in `~/.config/omarchy/shell.json`. The API key is never written there.

| Key | Default | Meaning |
|---|---|---|
| `siteUrl` | `""` | Your Teamwork address, `https://<yours>.teamwork.com`. Empty means not set up. Set it together with the key with **Connect**; a site other than the one the key is bound to needs reconnecting (see [the key is bound to its site](#the-key-is-bound-to-its-site)). |
| `sortField` | `""` | Task custom field to show and rank by, matched ignoring case. Empty turns it off. |
| `workDays` | `1,2,3,4,5` | ISO weekdays, 1 = Monday. |
| `workStart` / `workEnd` | `09:00` / `17:30` | Work hours, 24-hour `HH:MM`. |
| `lunchStart` / `lunchEnd` | `12:30` / `13:30` | Lunch, not counted as work time. |
| `nagEnabled` | `true` | Notify when no timer is running during work hours. |
| `nagIntervalMin` | `15` | Minutes between nags (5–120). |
| `refreshIntervalSec` | `60` | Background refresh interval in seconds (15–3600); `0` turns background polling off. |
| `longTimerWarnHours` | `3` | Warn once when a timer passes this many hours; 0 is off. |
| `notifyAfterHours` | `true` | Warn once a day each if a timer is still running at lunch or after hours. |

## Network use

All traffic goes through `bin/teamwork`, over HTTPS, to the site URL you set, and only once a key is saved and bound to that site. Redirects are not followed. It calls the Teamwork Projects v3 API:

| When | Endpoints |
|---|---|
| Each refresh | `GET /projects/api/v3/me/timers.json`, `tasks.json` (your open tasks, plus tasks you timed this week), `time.json` (this week's time entries); `me.json` once, then cached |
| Starting, pausing, resuming, logging, discarding | `POST me/timers.json`, `PUT me/timers/{id}[/pause\|/resume\|/complete].json`, `DELETE me/timers/{id}.json`, `GET tasks/{id}.json`, `GET timers/{id}.json`, `POST tasks/{id}/time.json` |
| Searching | `GET tasks.json?searchTerm=…` |
| Connecting (saving a key) | `GET me.json`, to check it with the site it will be bound to |
| Shell start, once, for a key saved by 1.0.0 | `GET me.json`, to check it before binding it (see above) |

It refreshes in the background every `refreshIntervalSec` (60 s by default, configurable from 15 s to an hour), when the panel opens, and after each action; after failures it backs off, doubling up to 10 minutes. With several monitors only one bar instance polls. Set `refreshIntervalSec` to `0` to turn background polling off: it then contacts Teamwork only when the shell starts, when the panel opens, and after an action you take. The running timer still ticks locally, but reminders and warnings rely on the last refresh, so a timer started or stopped elsewhere (the Teamwork web app, another machine) isn't noticed until the next one.

Each request times out after 15 s of silence and each helper call after 90 s in all; responses over 5 MiB are refused. The custom-field sideload (`include=customfieldTasks,customfields`) is requested only when `sortField` is set. Nothing else is contacted: no telemetry, no update checks. Opening a task hands its URL to `xdg-open`.

## Notifications

Sent with `notify-send`, all optional in Settings:

- **No timer running**: during work hours (outside lunch), after `nagIntervalMin` minutes with nothing timing, with **Resume/Start** and **Open** actions. Each nag replaces the last.
- **Timer still running**: once per timer, past `longTimerWarnHours`.
- **Lunch / after hours**: once a day each, if a timer is still running.

With background polling off (`refreshIntervalSec` 0), these rely on the last refresh: open the panel now and then to keep them accurate.

## IPC

```bash
omarchy-shell tomhayes.teamwork open|close|toggle|show|hide
omarchy-shell tomhayes.teamwork settings      # open on Settings
omarchy-shell tomhayes.teamwork toggleTimer   # same as clicking the glyph
omarchy-shell tomhayes.teamwork refresh
omarchy-shell tomhayes.teamwork state         # JSON summary, no secrets
```

## Privacy and security

- The API key is read from the keyring or the 0600 file only by `bin/teamwork`; it is never printed, logged, cached, put in `shell.json`, or passed on a command line.
- `~/.cache/tomhayes.teamwork/me.json` caches your Teamwork user id and name, nothing else.
- Text from Teamwork is shown as plain text and bounded (names to 300 characters, sort-field values to 40, at most 500 tasks). In notification text, markup characters are replaced with look-alikes, URLs are kept from turning into links, and bidirectional-override characters are dropped.
- Commands run as argv arrays, never through a shell. Task links are built from the validated site URL and a numeric id.
- The site URL must be a bare `https://` origin: no credentials, port, path or query. Custom Teamwork domains work.
- The key is bound to the site it was checked against, and `bin/teamwork` refuses to send it anywhere else: changing the site URL (in Settings, the stock widget settings, or `shell.json`) never sends the existing key to the new site. You connect the new site with its own key. A key without a binding is refused the same way, apart from the one-time upgrade step described under [the key is bound to its site](#the-key-is-bound-to-its-site).
- **Remove** reports success only after checking that no copy of the key is left in the keyring or on disk. It deletes the binding and the cached user first, so a copy that survives a failed removal can't be used, or bound again by the upgrade step, until you connect again.

## Tests

```bash
python3 -m unittest discover -s tests   # helper, against a local mock Teamwork server
node --test ui-tests/                   # work-time maths, snapshot model, due groups
```

The helper tests never touch your keyring or real state: they point `HOME`, the XDG directories and `secret-tool` at temporary fakes.

## License

[MIT](LICENSE)
