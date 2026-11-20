# Setting up Instagram and Facebook messages for Lens (for Claude, walking Emma through it)

**Current route (Meta changed its menus in late 2026):** one Facebook Page code covers both the Page's
Messenger messages and the Instagram DMs of the Instagram professional account linked to that Page.
1. developers.facebook.com/apps, Create app (type Business), name Lens.
2. Add Product: Messenger (Set up). Instagram's "Unified login" needs a web server, so skip it.
3. Graph API Explorer (developers.facebook.com/tools/explorer): Meta App = Lens; User or Page = Get Page
   Access Token; Permissions: pages_show_list, pages_messaging, pages_read_engagement, pages_manage_metadata,
   instagram_basic, instagram_manage_messages, business_management. Generate Access Token, log in, choose
   her Page and her Instagram account. Then pick her Page in "User or Page" so the token is the Page's.
4. Make it last: click the (i) next to the token, Open in Access Token Tool, Extend Access Token, copy the
   long-lived token; back in the Explorer paste it, run GET me/accounts, and copy her Page's access_token
   (a Page token from a long-lived user token doesn't expire).
5. In Lens: Log-ins, Instagram + Facebook, paste it in "Paste your Facebook Page code", Connect Facebook.

The older steps below (Instagram login with its own code) still work where Meta offers them.

Lens reads Emma's Instagram DMs and Facebook Page messages through a small private Meta app on her own
account. Both her accounts are professional. Walk her through it one click at a time and wait for "done"
after each step. Meta renames menus often: if a name below doesn't match what she sees, ask her what's on
screen (Ask Lens can't see the browser) and adapt. Never ask her to paste a code into a chat or an issue:
she pastes each code into Lens itself (Log-ins, Instagram + Facebook), which keeps it in the Keychain.

1. Open https://developers.facebook.com/apps and sign in with her Facebook account. If asked, register as
   a developer (accept the terms, confirm her email).
2. **Create app**. Use case: **Other**, then **Next**. App type: **Business**, then **Next**.
   Name it `Lens`, contact email: her own, then **Create app**. No business verification is needed:
   the app stays in development mode and only reads her own accounts.
3. **Instagram:** on the app's dashboard find **Instagram** and click **Set up**. Choose
   **API setup with Instagram login**. Under **1. Generate access tokens**, click **Add account** and log
   in to her Instagram professional account. If Instagram asks her to accept a tester invite, accept it
   (Instagram app: Settings, Apps and websites, Tester invites). Then click **Generate token** next to her
   account, tick that she understands, and **Copy**. In Lens: Log-ins, Instagram + Facebook, paste it in
   **Paste your Instagram code**, click **Connect Instagram**. Lens renews this code by itself.
4. **Facebook Page:** back on the dashboard, add the **Messenger** product (**Set up**). In
   **Messenger API settings**, under **Generate access tokens**, click **Connect** (or **Add Page**), pick
   her Facebook Page and allow it. Click **Generate** next to the Page, tick that she understands, and
   **Copy**. In Lens, paste it in **Paste your Facebook Page code**, click **Connect Facebook**.
5. Lens says "Instagram connected" and "Facebook connected" and reads messages straight away, then every
   hour. Real inquiries appear on Pipeline tagged Instagram or Facebook.

Webhooks, App Review and publishing the app are not needed: Lens checks hourly and only reads her own
accounts (Meta's Standard Access).

If Lens says a code "needs a new token": repeat step 3 or 4 for that one and paste the new code.
If it says Instagram or Facebook "isn't letting Lens read messages": the app is missing the messages
permission. Instagram: make sure `instagram_business_manage_messages` is listed under the Instagram
product's permissions. Facebook: make sure the Page token was generated in Messenger API settings (it
includes `pages_messaging`).
