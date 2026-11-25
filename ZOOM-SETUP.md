# Setting up Zoom for Lens (for Claude, walking Emma through it)

Lens reads Emma's Zoom AI Companion summaries straight from Zoom. To do that, Zoom needs a small
private "app" on Emma's Zoom account that only has permission to *read*. This is done once.
The same steps are shown on the Zoom card in **Lens → Log-ins → Zoom**. Walk her through them one
click at a time, and wait for her to say "done" after each step. Never ask her to paste the Client
Secret into a chat or an issue: she pastes both keys into the Zoom card in Lens herself.

1. Open https://marketplace.zoom.us and **Sign in** with her Zoom account.
2. Top right: **Develop**, then **Build App**.
3. Pick **General App**, then **Create**. Name it `Lens`.
4. "How will the app be managed?": **User-managed**. (Admin-managed also works; then the scope
   names below end in `:admin`.)
5. **OAuth Redirect URL**: `http://127.0.0.1:8765/zoom`. Add the same address to the **OAuth Allow List**.
6. Left side: **Scopes**, then **Add Scopes**. Tick only these read permissions:
   - `meeting:read:list_summaries` (list her meeting summaries)
   - `meeting:read:summary` (read one meeting summary)
   - `meeting:read:list_past_participants` (who was in each meeting)
   - `meeting:read:list_meetings` (her past meetings, a backup way to find summaries)
   - `user:read:user` (which Zoom account is connected)
   - Optional, only if she uses My Notes: `my_notes:read:note`, `my_notes:read:content` and
     `canvas:write:file_search` (despite the name it only searches; Lens uses it to list her notes).
   Nothing else. Lens never changes or deletes anything in Zoom.
7. Left side: **Basic Information** (or **App Credentials**). She copies the **Client ID** and
   **Client Secret** and pastes them into the Zoom card in Lens, then clicks **Save keys**.
   The app does not need to be published: it stays private to her account.
8. In Lens: **Connect Zoom**. Zoom opens in the browser; she signs in and presses **Allow**.
   Back in Lens it says "Connected" and reads every past summary in the background, then checks
   for new ones every hour. The card shows something like "Connected · 143 summaries found · newest Nov 18".

Lens still picks up the older setup file (`~/Downloads/lens_zoom_client.json` with `client_id` and
`client_secret`) if one is there, but pasting the keys on the card is the normal way now.

If Zoom says the address doesn't match, check step 5 (both boxes, exactly `http://127.0.0.1:8765/zoom`).
If Lens says Zoom isn't letting it read summaries, check the scopes in step 6, then click **Connect Zoom** again.
If Zoom doesn't accept the keys, click **Use different keys** on the Zoom card and paste them again.
