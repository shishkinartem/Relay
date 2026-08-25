# Connecting an upload destination

**Status:** Current
**Scope:** end-user setup for the two shipping destinations, and pre-seeding a build
**Review when:** a destination is added or removed, or `.env` keys change

Relay uploads to Telegram or WebDAV. Architecture and the destination contract live in
[`architecture/uploads.md`](architecture/uploads.md); this file is the setup guide.


Open **Settings → Upload destination → Set up**. Two destinations ship, and
neither needs a developer account, an API console or a payment method.
Credentials go to the macOS Keychain / Windows Credential Manager, never to a
file (§27).

| | Setup | Per-file limit | Good for |
|---|---|---|---|
| **Telegram** | a bot token and a chat id, both from inside the messenger | 50 MB, or 2000 MB with your own server | sending a clip to a chat |
| **WebDAV** | an app password from your storage provider | none | anything that does not fit in a chat |

### Telegram

1. In Telegram, message **@BotFather** and send `/newbot`. Follow the prompts
   and copy the HTTP API token.
2. Send your new bot a message — or add it to the group or channel you want
   recordings in and post one message there. A bot cannot open a conversation
   itself, so this step is what makes the chat reachable.
3. Open `https://api.telegram.org/bot<your token>/getUpdates` in a browser and
   copy the numeric `"chat":{"id":…}` from the message you just sent. A channel
   id starts with `-100`.
4. Paste the token and the chat id into **Set up** and press **Connect**. Relay
   calls `getMe` and `getChat` before storing anything, so a typo is reported
   there and then.

### WebDAV (Koofr, Nextcloud, …)

WebDAV is a protocol rather than a service, so this works with any server that
speaks it. The suggested provider is [Koofr](https://koofr.eu): 10 GB free,
WebDAV included on the free plan, and app passwords you can revoke one at a
time. That is roughly eleven hours of 720p recording.

1. Sign up at koofr.eu.
2. Open *Preferences → Password → app-specific passwords*, create one for Relay
   and copy it. This is not your account password — providers reject that one on
   WebDAV.
3. In Relay, fill in:

   | Field | Koofr | Nextcloud |
   |---|---|---|
   | WebDAV address | `https://app.koofr.net/dav/Koofr` | `https://<host>/remote.php/dav/files/<user>` |
   | User name | the email you signed up with | your Nextcloud user name |
   | App password | the generated one | *Settings → Security → Devices & sessions* |
   | Folder | optional, `Relay` by default | same |

4. Press **Connect**. Relay checks the credentials with `PROPFIND` and creates
   the folder with `MKCOL` before storing anything, so a wrong address or a
   rejected password is reported there and then.

There is no size limit beyond your storage quota. There is also no resume: WebDAV
has no standard way to continue a partial upload, so an interrupted transfer
starts over — the recording stays on disk either way (§13).

**Yandex.Disk is not recommended**, although it would work: its WebDAV is
throttled to roughly a minute per megabyte, which turns a 50 MB recording into
an hour-long upload.

**Disconnect** forgets the credentials and survives a restart.

## Lifting Telegram's 50 MB limit

Only worth doing if you want long recordings *in a Telegram chat specifically*;
otherwise use WebDAV above, which has no limit and needs no server.

The hosted Bot API accepts at most 50 MB per video — about a minute and a half
at 1080p30, three and a half at 720p30. Telegram publishes the server itself,
and running your own raises the ceiling to **2000 MB**. It is free: no fees, no plan, nothing to register beyond
an `api_id` for your own Telegram account.

> Finish the four steps above **first**. Step 3 reads `getUpdates` from the
> hosted API, and logging the bot out of it (step 3 below) locks you out of the
> hosted API for 10 minutes.

1. **Get an `api_id` and `api_hash`.** Sign in at
   [my.telegram.org](https://my.telegram.org) → *API development tools* → fill
   in any app name. These identify *your Telegram account*, not the bot, and are
   free. Keep them out of the repository.

2. **Run the server.** Either is fine; Docker is less work.

   ```bash
   docker run -d --name telegram-bot-api --restart=always \
     -p 8081:8081 -v telegram-bot-api-data:/var/lib/telegram-bot-api \
     -e TELEGRAM_API_ID=<api_id> -e TELEGRAM_API_HASH=<api_hash> \
     -e TELEGRAM_LOCAL=true \
     aiogram/telegram-bot-api:latest
   ```

   Or build [telegram-bot-api](https://github.com/tdlib/telegram-bot-api) from
   source — the project generates per-OS instructions at
   [tdlib.github.io/telegram-bot-api/build.html](https://tdlib.github.io/telegram-bot-api/build.html);
   there is no Homebrew formula — and run it:

   ```bash
   telegram-bot-api --api-id=<api_id> --api-hash=<api_hash> --local --http-port=8081
   ```

3. **Log the bot out of the hosted API.** A bot lives on one Bot API server at a
   time, and Telegram requires this before it runs locally. This is the step
   that is easy to miss.

   ```bash
   curl "https://api.telegram.org/bot<your token>/logOut"
   ```

4. **Point Relay at it.** Settings → Telegram → Set up → **Bot API base URL** =
   `http://127.0.0.1:8081` → **Connect**. Relay re-checks the token and the chat
   against the new endpoint, the `50 MB max` tag disappears from the
   destination, and the pre-flight stops refusing large recordings.

The server has to be running whenever you press Send. It runs on your machine —
nothing goes through it except your own uploads on their way to Telegram.

To go back to the hosted API, clear the base URL field, and call
`close` on the local server first:
`curl "http://127.0.0.1:8081/bot<your token>/close"`.

## Configuration

A build can be pre-seeded so it ships already connected. This is a development
and internal-deployment convenience; anything connected in Settings takes
precedence, and a disconnect is not undone by it.

```bash
cp .env.example .env
```

| Key | Used by |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Telegram Bot API |
| `TELEGRAM_BOT_API_BASE_URL` | optional; your own Bot API server, e.g. `http://127.0.0.1:8081` |

With no credentials from either route, Send reports a typed *not configured*
error and the recording stays on disk.

The file is looked for in this order, and the first one that exists wins:

1. `$RELAY_ENV_FILE`, if it is set;
2. `.env` in the working directory — `flutter run` from the repository root;
3. `.env` beside the executable — the whole Windows bundle is one directory;
4. `relay.app/Contents/Resources/.env` — inside a macOS bundle;
5. `.env` beside `settings.json` in application support — droppable into an
   installed build without touching a signed bundle.

There is more than one because a bare relative `.env` resolves against the
process working directory, which is the repository root under `flutter run` and
`/` for a bundle the Finder launched: the file used to work in development and
be silently ignored in an installed build. Startup logs `environment_loaded`
with the path it read and the key names — never a value.
