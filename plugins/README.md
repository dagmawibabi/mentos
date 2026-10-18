# Mentos plugins

Plugins are small scripts that add to Mentos: chat commands, themes, pages,
automations. The app downloads and runs them at runtime, so a new plugin
never needs an app update or rebuild.

People find them in **Settings › Plugins › Discover**, which reads this
folder's `index.json` (and any other registry they add). Installing shows the
plugin's permissions first; nothing runs until the person approves.

## Layout

```
plugins/
  index.json          the registry (generated, do not edit by hand)
  build.dart          regenerates index.json
  <id>/plugin.json    manifest
  <id>/main.js        script
```

After adding or changing a plugin, run from the repo root:

```bash
dart run plugins/build.dart
```

It pins each script's sha256 in `index.json`. The app refuses a download that
doesn't match, so a registry entry can't be swapped for different code.

## Manifest

```json
{
  "id": "dice",
  "name": "Dice",
  "version": "1.0.0",
  "author": "You",
  "description": "Roll dice in any chat.",
  "icon": "casino",
  "permissions": ["commands"],
  "main": "main.js"
}
```

- `id`: lowercase letters, digits and dashes, 2-40 characters, matching the folder name.
- `version`: bump it to offer an update. People see Update in Discover, and any new permission is highlighted.
- `icon`: one of `palette casino translate bolt sparkle chat timer calculate music brush code star heart public shield robot wallet cloud sun moon text emoji away note` (anything else shows a puzzle piece).

### Single-file plugins

For quick experiments, put the manifest in a leading comment and install the
`.js` file directly (Plugins › + › Install from a file, or the developer API):

```js
/* @plugin {"id": "hello", "name": "Hello", "version": "0.1", "permissions": ["commands"]} */
mentos.commands.add('hello', 'Say hi', () => 'Hello from a plugin 👋');
```

## The language

Scripts are a JavaScript subset that runs in a sandbox inside the app:
`let`/`const`/`var`, functions and arrow functions (with closures), objects,
arrays, template strings, `if`/`else`, `while`, `for`, `for…of`, `for…in`,
`try`/`catch`/`throw`, spread (`...`), `?.` and `??`, plus common `String`,
`Array`, `Math`, `JSON`, `Object` and `Date.now()` helpers.

There is no `import`, `eval`, DOM, `fetch`, file or network access except
through `mentos` below. Every call into a plugin runs on a step budget, so an
endless loop stops the plugin instead of the app. Errors go to the plugin's
log (Plugins › the plugin › Log).

## The `mentos` API

| Call | Permission | What it does |
|---|---|---|
| `mentos.log(...values)` / `console.log` | none | Writes to the plugin log |
| `mentos.me()` | none | `{id, name}` of the person using the app |
| `mentos.plugin` | none | `{id, name, version, permissions}` |
| `mentos.timer.after(sec, fn)` / `every(sec, fn)` / `cancel(id)` | none | Timers (`every` is at least 5 s; 20 timers max) |
| `mentos.commands.add(name, description, fn)` | `commands` | Adds `/name`. `fn(args, {scope})` returns the text to send instead, or `''` to send nothing |
| `mentos.compose.onSend(fn)` | `compose` | `fn(text, {scope})` returns the text to actually send |
| `mentos.on('message', fn)` | `messages.read` | `fn({id, scope, from, name, text})` for each incoming chat message |
| `mentos.chats.send(scope, text)` | `messages.send` | Sends a chat message |
| `mentos.chats.list()` | `chats.read` | `[{scope, title, peer, group, unread, last}]` |
| `mentos.contacts.name(id)` | `contacts.read` | Display name for an id |
| `mentos.wallet.balance()` | `wallet.read` | `{minor, mentos}` |
| `mentos.storage.get(key, fallback)` / `set(key, value)` / `remove(key)` / `keys()` | `storage` | Saved on this device, per plugin (500 keys, 64 KB each) |
| `mentos.notify(text)` | `notify` | Shows a short notice in the app |
| `mentos.http.request({url, method, headers, body, timeout}, cb)` | `net` | Any https API: GET, POST, PUT, PATCH, DELETE, HEAD. 2 MB max, 6 at a time. `cb({ok, status, headers, body, json, ms, error})` |
| `mentos.http.get(url, cb)` / `post(url, body, cb)` | `net` | Shortcuts for `request` |
| `mentos.peers.list()` | `p2p` | `[{id, name, online}]` of your contacts |
| `mentos.peers.send(id, data)` / `peers.on(fn)` | `p2p` | Messages the same plugin on a contact's device, end-to-end encrypted. `fn({from, name, data})`, 32 KB max |
| `mentos.layout.set({...})` / `reset()` | `layout` | Rearranges the app, see below |
| `mentos.ui.slot(name, render)` | `ui` | Puts a card inside one of the app's screens, see below |
| `mentos.ui.tab({title, icon, page})` | `ui` | Pins one of your pages to the bottom bar |
| `mentos.theme.set({...})` / `reset()` | `theme` | Recolors the app, see below |
| `mentos.ui.page({id, title, icon, render})` / `refresh()` | `ui` | Adds a page, see below |

### Themes

```js
mentos.theme.set({
  accent: '#7C3AED',                 // both modes
  textScale: 1.1,                    // 0.8 – 1.4
  light: { bubbleMine: '#1E1B4B' },  // light mode only
  dark:  { bg: '#0B0A1A', surface: '#13112A' },
});
```

Colors: `bg surface raised line ink inkSoft muted faint accent accentInk accentSoft danger bubbleMine bubbleMineInk`.

### Layout

```js
mentos.layout.set({
  hideTabs: ['wallet', 'network'],        // also 'feed'
  hide: ['stories', 'composeButton'],     // also 'quickActions', 'marketBanner'
  density: 'compact',                     // or 'comfortable'
  navLabels: false,                       // icon-only bottom bar
  feedImages: 'original',                 // or 'square' (the default)
});
```

Everything a layout plugin changes goes back to normal when it is turned off
or removed. See `focus/` for a settings page built on this.

### Cards in the app

`mentos.ui.slot(name, render)` draws a card using the same nodes as pages, in
one of: `feed.top`, `chats.top`, `profile.top`, `wallet.top`, `network.top`.
Return `null` from `render` to hide it. See `weather/`, which fetches live data
and shows it at the top of the feed.

### Pages

`render()` returns a list of nodes. Mentos draws them with its own widgets,
calls your handlers, and calls `render()` again afterwards.

```js
let count = 0;
mentos.ui.page({
  title: 'Counter',
  render: () => [
    { type: 'stat', label: 'taps', value: `${count}` },
    { type: 'button', label: 'Tap', onTap: () => { count++; } },
  ],
});
```

| Node | Fields |
|---|---|
| `text` | `text`, `style`: `body title heading strong muted mono error` |
| `title` | `text` |
| `button` | `label`, `onTap`, `style`: `primary outline text` |
| `input` | `key`, `label`, `hint`, `value`, `multiline`, `onChange(text)`, `onSubmit(text)` |
| `switch` | `label`, `subtitle`, `value`, `onChange(bool)` |
| `slider` | `label`, `min`, `max`, `value`, `onChange(number)` |
| `list` | `items: [{title, subtitle, trailing, onTap}]` |
| `stat` | `label`, `value` |
| `progress` | `value` 0–1, or none for a spinner bar |
| `row` / `column` / `card` | `children` |
| `divider`, `space` | `space` takes `size` |

A plain string is shorthand for a text node; `null` is skipped.

## Developing against a running app

Turn on **Settings › Developer**, then push a plugin from your editor and it
reloads instantly:

```bash
curl -X POST http://127.0.0.1:8787/v1/plugins -H "Authorization: Bearer <access code>" --data-binary @hello.js
```

The browser dashboard at `http://127.0.0.1:8787` has a Plugins tab with live
logs, reload and enable switches.

## Hosting a registry elsewhere

Any https URL serving an `index.json` like this one works (for example
`dagmawibabi/mentossite/plugins`). Entries' `manifest` paths resolve against
the index URL. People add registries under Plugins › + › Registries.
