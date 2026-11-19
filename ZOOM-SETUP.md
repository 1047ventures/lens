# Setting up Zoom for Lens (for Claude, walking Emma through it)

Lens reads Emma's Zoom AI Companion summaries straight from Zoom. To do that, Zoom needs a small
private "app" on Emma's Zoom account that only has permission to *read*. This is done once, on her
Mac. Walk her through it one click at a time, and wait for her to say "done" after each step.
Never ask her to paste the Client Secret into a chat or an issue: you write it straight into the file
in step 7.

1. Open https://marketplace.zoom.us in her browser and have her **Sign in** with her Zoom account.
2. Top right: **Develop**, then **Build App**.
3. Pick **General App**, then **Create**.
4. In **Basic Information**:
   - Name it `Lens`.
   - "How will the app be managed?": choose **Admin-managed** if she owns her Zoom account (a
     solo Pro account does). If Zoom won't let her, choose **User-managed**; Lens still works, it
     just goes through her own meetings one by one.
   - **OAuth Redirect URL**: `http://127.0.0.1:8765/zoom`
   - **OAuth Allow List**: add the same address, `http://127.0.0.1:8765/zoom`
5. Left side: **Scopes**, then **Add Scopes**. Tick only these read permissions (the names end in
   `:admin` for an Admin-managed app):
   - Meetings: `meeting:read:list_summaries` (list meeting summaries)
   - Meetings: `meeting:read:summary` (read a meeting summary)
   - Meetings: `meeting:read:list_meetings` (list her meetings, used if the list above isn't allowed)
   - Meetings: `meeting:read:list_past_participants` (who was in each meeting)
   - Users: `user:read:user` (which Zoom account is connected)
   Nothing else. Lens never changes or deletes anything in Zoom.
6. Left side: **Basic Information** (or **App Credentials**). Have her click the copy button next to
   **Client ID** and then **Client Secret**, one at a time, and paste each into Claude Code on her Mac.
   The app does not need to be published: it stays private to her account.
7. Write the two values into `~/Downloads/lens_zoom_client.json` like this:
   ```json
   { "client_id": "…", "client_secret": "…" }
   ```
   Lens picks the file up as soon as Log-ins is opened (or Lens comes to the front), saves both
   values in the Mac's Keychain, and moves the file to the Trash.
8. In Lens: **Log-ins → Zoom → Connect Zoom**. Zoom opens in the browser; she signs in and presses
   **Allow**. Back in Lens it says "Connected" and starts reading every summary in the background.
   When it's done it shows something like "Connected · 143 summaries read · newest Nov 18".

If Zoom says the address doesn't match, check step 4 (both boxes, exactly `http://127.0.0.1:8765/zoom`).
If Lens says Zoom isn't letting it read summaries, check the scopes in step 5.
