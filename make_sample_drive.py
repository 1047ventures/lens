#!/usr/bin/env python3
"""Builds a realistic sample setup for Lens to play with:
- a 3.2 GB disk image that mounts as its own drive, "Emma SSD"
- real video clips in project folders, loose card dumps, duplicates, Premiere cache
- a "Home Server" folder with one archived project
- projects.json (Colorado gigs at every stage) and deals.json (the pipeline, led by the real CEJ pitch)
"""
import json, os, subprocess, uuid, shutil, time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, "Lens Sample")
IMAGE = os.path.join(BASE, "Emma SSD.sparseimage")
SSD = "/Volumes/Emma SSD"
SERVER = os.path.join(BASE, "Home Server")
APP_SUPPORT = os.path.join(HOME, "Library/Application Support/Lens")
FFMPEG = "/opt/homebrew/bin/ffmpeg"

def run(*args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL)

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

# ---- the drive -------------------------------------------------------------
os.makedirs(BASE, exist_ok=True)
if os.path.ismount(SSD):
    run("hdiutil", "detach", SSD, "-force")
if os.path.exists(IMAGE):
    os.remove(IMAGE)
run("hdiutil", "create", "-size", "3.2g", "-fs", "APFS", "-volname", "Emma SSD", "-type", "SPARSE", IMAGE)
run("hdiutil", "attach", IMAGE)
for _ in range(20):
    if os.path.ismount(SSD):
        break
    time.sleep(0.5)

if os.path.exists(SERVER):
    shutil.rmtree(SERVER)
os.makedirs(SERVER)

def clip(path, seconds, pattern="testsrc2", make=None, model=None, location=None, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    src = f"{pattern}=size=1920x1080:rate=24:duration={seconds},noise=alls=40:allf=t"
    cmd = [FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", src,
           "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
    if make: cmd += ["-metadata", f"make={make}"]
    if model: cmd += ["-metadata", f"model={model}"]
    if location: cmd += ["-metadata", f"location={location}"]
    cmd.append(path)
    subprocess.run(cmd, check=True, stdin=subprocess.DEVNULL)
    if mtime:
        os.utime(path, (ts(mtime), ts(mtime)))

def blob(path, megabytes):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        for _ in range(megabytes):
            f.write(os.urandom(1024 * 1024))

P = lambda *parts: os.path.join(SSD, *parts)

# Ortiz Brand Film — in the edit
for name, secs, pat, mk, md, loc in [
    ("interview_A_cam1.mov", 4, "testsrc2", "Sony", "ILME-FX3", None),
    ("interview_A_cam2.mov", 4, "smptehdbars", "Sony", "ILME-FX3", None),
    ("drone_skyline.mov", 3, "testsrc", "DJI", "Mavic 3 Pro", "+39.7684-104.9783+000.000/"),
    ("broll_roasting.mov", 3, "testsrc2", "Sony", "ILME-FX3", None),
    ("broll_pour.mov", 2, "rgbtestsrc", "Sony", "ILME-FX3", None),
    ("product_closeups.mov", 2, "testsrc2", "Sony", "ILME-FX3", None),
]:
    clip(P("Ortiz Brand Film", name), secs, pat, mk, md, loc, "2026-10-22T18:00:00Z")

# Lopez Engagement — delivered, waiting on payment
for name, secs, pat in [("walk_on_the_beach.mov", 3, "testsrc2"), ("ring_closeup.mov", 2, "rgbtestsrc"),
                        ("golden_hour_portraits.mov", 3, "testsrc")]:
    clip(P("Lopez Engagement", name), secs, pat, "Sony", "A7S III", "+39.9989-105.2817+000.000/", "2026-10-10T00:30:00Z")
blob(P("Client Deliveries", "Lopez_Engagement_Final_4K.zip"), 380)

# Chen Anniversary — paid, ready for the server
for name, secs, pat in [("toast.mov", 3, "testsrc2"), ("first_dance.mov", 3, "smptehdbars"), ("vineyard_drone.mov", 2, "testsrc")]:
    clip(P("Chen Anniversary", name), secs, pat, "Sony", "A7S III", "+40.3772-105.5217+000.000/", "2026-09-19T23:00:00Z")

# Hartley Wedding — shoots tomorrow, folder ready, no footage yet
os.makedirs(P("Hartley Wedding"), exist_ok=True)

# Loose footage: a card dump nobody filed, a phone clip, an old forgotten clip
clip(P("Card Dump 10-28", "C0041.MP4"), 3, "testsrc2", mtime="2026-10-28T20:00:00Z")
clip(P("Card Dump 10-28", "C0042.MP4"), 2, "rgbtestsrc", mtime="2026-10-28T20:05:00Z")
clip(P("IMG_4021.MOV"), 2, "testsrc2", "Apple", "iPhone 15 Pro", "+40.0150-105.2705+000.000/", "2026-11-01T19:00:00Z")
clip(P("old_broll_2024.mov"), 2, "smptehdbars", "Sony", "A7S III", mtime="2024-07-15T18:00:00Z")

# Duplicates: copies that piled up from re-downloading and re-dumping cards
os.makedirs(P("Downloads dump"), exist_ok=True)
shutil.copy2(P("Ortiz Brand Film", "interview_A_cam1.mov"), P("Downloads dump", "interview_A_cam1 copy.mov"))
shutil.copy2(P("Chen Anniversary", "toast.mov"), P("Card Dump 10-28", "toast.mov"))

# Premiere cache and preview renders
blob(P("Adobe Premiere Pro Preview Files", "Ortiz Brand Film.PRV", "Rendered - 1a2b.mxf.pek"), 420)
blob(P("Media Cache Files", "interview_A_cam1 48000.cfa"), 240)

# Home server: one project already archived
for name, secs in [("court_of_honor.mov", 2), ("father_daughter_dance.mov", 2)]:
    clip(os.path.join(SERVER, "Rivera Quinceanera", name), secs, "testsrc2", "Sony", "A7S III", mtime="2026-06-14T02:00:00Z")

# ---- projects --------------------------------------------------------------
from datetime import timedelta

def ev(date, text):
    return {"id": str(uuid.uuid4()).upper(), "date": date, "text": text}

def local_iso(days_from_now, hour):
    """A wall-clock time on this Mac N days from today, as UTC ISO 8601."""
    d = (datetime.now().astimezone() + timedelta(days=days_from_now)).replace(hour=hour, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def project(name, client, shoot, location, stage, events, folder=True, archived=None, testimonial=None, portfolio=None):
    return {
        "id": str(uuid.uuid4()).upper(), "name": name, "client": client, "shootDate": shoot,
        "location": location, "folderPath": P(name) if folder else None, "archivedPath": archived,
        "stage": stage, "events": events, "createdAt": events[0]["date"],
        "testimonial": testimonial, "portfolioURL": portfolio,
    }

hartley = project("Hartley Wedding", "Sarah & James Hartley", local_iso(1, 14), "Planet Bluegrass, Lyons", 2, [
    ev("2026-09-14T17:12:00Z", "Inquiry came in by email"),
    ev("2026-09-16T19:40:00Z", "Quote sent · $5,200"),
    ev("2026-10-02T16:05:00Z", "Booked: $1,500 deposit by Venmo"),
    ev(NOW, "Pack list ready"),
])
# Past work with no footage on the drive: proof for future proposals
restoration = project("Boulder Creek Restoration Film", "Boulder Watershed Collective", "2025-09-12T16:00:00Z", "Boulder Creek", 6, [
    ev("2025-07-01T16:00:00Z", "Booked"), ev("2025-09-12T22:00:00Z", "Shot"),
    ev("2025-10-20T16:00:00Z", "Delivered"), ev("2025-11-01T16:00:00Z", "Paid")], folder=False,
    testimonial="Emma found the people behind the project and let them tell it. Our donors still bring it up. (sample, replace with a real quote)")
foodbank = project("Front Range Food Bank Story", "Front Range Food Bank", "2025-04-18T16:00:00Z", "Denver", 6, [
    ev("2025-03-02T16:00:00Z", "Booked"), ev("2025-04-18T22:00:00Z", "Shot"),
    ev("2025-05-20T16:00:00Z", "Delivered"), ev("2025-06-01T16:00:00Z", "Paid")], folder=False)
ortiz = project("Ortiz Brand Film", "Ortiz Coffee Roasters", "2026-10-22T17:00:00Z", "RiNo, Denver", 3, [
        ev("2026-09-30T18:20:00Z", "Inquiry from the website form"),
        ev("2026-10-03T21:00:00Z", "Booked: $1,000 deposit"),
        ev("2026-10-22T23:30:00Z", "Shot: 2 cameras plus drone, 6 clips"),
        ev("2026-10-23T16:00:00Z", "Moved to Edit"),
        ev("2026-11-01T20:15:00Z", "Rough cut sent for notes"),
    ])
projects = [
    hartley, ortiz, restoration, foodbank,
    project("Lopez Engagement", "Maria & Andre Lopez", "2026-10-10T00:30:00Z", "Chautauqua Park, Boulder", 4, [
        ev("2026-08-28T18:00:00Z", "Inquiry by email"),
        ev("2026-09-02T17:30:00Z", "Booked: $600 deposit"),
        ev("2026-10-10T03:00:00Z", "Shot at golden hour"),
        ev("2026-10-20T22:00:00Z", "Edit finished"),
        ev("2026-10-24T18:45:00Z", "Delivered: final $1,800 invoice sent"),
    ]),
    project("Chen Anniversary", "Linda & Wei Chen", "2026-09-19T23:00:00Z", "Estes Park", 5, [
        ev("2026-08-05T16:00:00Z", "Inquiry by phone"),
        ev("2026-08-09T18:00:00Z", "Booked"),
        ev("2026-09-20T05:00:00Z", "Shot"),
        ev("2026-10-06T19:00:00Z", "Delivered"),
        ev("2026-10-15T17:20:00Z", "Paid in full"),
    ], testimonial="We cried at the toast all over again. (sample, replace with a real quote)"),
    project("Summit Gym Promo", "Summit Gym", local_iso(12, 9), "Summit Gym, Boulder", 1, [
        ev("2026-11-02T18:00:00Z", "Quote sent · $2,200"),
        ev("2026-11-04T21:30:00Z", "Booked: deposit received"),
    ], folder=False),
    project("Rivera Quinceanera", "Rivera family", "2026-06-13T23:00:00Z", "Pueblo", 6, [
        ev("2026-04-10T18:00:00Z", "Booked"),
        ev("2026-06-14T06:00:00Z", "Shot"),
        ev("2026-07-08T19:00:00Z", "Delivered"),
        ev("2026-07-15T17:00:00Z", "Paid"),
        ev("2026-08-03T20:00:00Z", "Footage moved to the server"),
    ], archived=os.path.join(SERVER, "Rivera Quinceanera")),
]

# ---- pipeline --------------------------------------------------------------
def uid():
    return str(uuid.uuid4()).upper()

def option(name, tagline, pitch, local, crew, interviewees, minutes, revisions, extras=(), travel=0, places="",
           travel_crew=1, allowance=0, quote=None, client_tasks=(), note="", hand_off=()):
    return {"id": uid(), "name": name, "tagline": tagline, "pitch": pitch, "localDays": local, "travelDays": travel,
            "travelPlaces": places, "localCrew": crew, "travelCrew": travel_crew, "interviewees": interviewees,
            "filmMinutes": minutes, "revisionRounds": revisions, "extras": list(extras), "clientTakesOn": list(client_tasks),
            "travelAllowance": allowance, "quote": quote, "note": note, "handOff": list(hand_off)}

def point(title, text):
    return {"id": uid(), "title": title, "text": text}

EMPTY_STORY = {"headline": "", "logline": "", "callout": "", "whyTitle": "", "why": [], "feelings": [],
               "approachTitle": "", "pillars": [], "choices": []}

def deal(client, title, source, stage, last_touch, events, options=(), contacts=(), location="", event_date=None,
         budget="", notes="", story=None, milestones=(), steps=(), links=(), chosen=None, lost=None, project_id=None):
    return {"id": uid(), "client": client, "title": title, "source": source, "stage": stage,
            "contacts": [{"id": uid(), "name": n, "role": r, "email": e} for n, r, e in contacts],
            "location": location, "eventDate": event_date, "budgetHint": budget, "callNotes": notes,
            "options": list(options), "chosenOptionID": chosen, "story": story or EMPTY_STORY,
            "milestones": [{"id": uid(), "phase": p, "when": w} for p, w in milestones],
            "nextSteps": [{"id": uid(), "text": t, "done": d} for t, d in steps],
            "originalLinks": list(links), "events": events, "lastTouch": last_touch,
            "lostReason": lost, "projectID": project_id, "createdAt": events[0]["date"]}

# The real CEJ pitch, rebuilt from Emma's working proposal and options packet.
cej_story = {
    "headline": "Thirty Years of Memories. A World Full of Stories.",
    "logline": "An anniversary documentary celebrating the visionary people behind 30 years of environmental journalism and the impact of their reporting on the world.",
    "callout": "A film about those who move mountains to pursue their life's purpose and uncover the stories that shed light on the impact we make on our environment.",
    "whyTitle": "A monumental milestone worth celebrating.",
    "why": [
        "30 years is a long run! An opportunity to honor the Fellowship's legacy and share what this program is all about.",
        "The Ted Scripps Fellowship empowers journalists to deepen their understanding of environmental issues and bring that knowledge and reporting to the rest of the world, keeping us connected to the things that really matter.",
        "As a CU Journalism alum, this topic is highly personal to me. My approach to photojournalism shares core tenets with the Fellowship as we uncover local stories with big impact, shining light on voices that would otherwise go unheard and connecting communities across the world.",
        "I look forward to bringing this same care, intention and dedication to the current, past and future Fellows, the Scripps family, and the broader CEJ community behind this world-renowned program.",
    ],
    "feelings": ["A connection to the people.", "An understanding of why this Fellowship matters.",
                 "A sense of possibility and hope for the future of environmental journalism."],
    "approachTitle": "Meet the people first; let the stories unfold from there.",
    "pillars": [
        point("The people behind it", "Explore why the Fellowship was created and what has made it special for 30 years. Cindy, Meredith, and selected fellows can speak to the commitment to journalism that drives this program."),
        point("The Fellowship in action", "Follow current fellows into field trips, research and conversations. Pair these moments with interviews that show what they are learning and how the experience is shaping their reporting."),
        point("The impact on fellows", "Bring former fellows into the story through specific career milestones and personal experiences that show how the Fellowship has impacted them."),
    ],
    "choices": [
        point("Which voices?", "Plan around five to six interviewees for a five- to seven-minute film. Together, choose the mix of current and former fellows, and confirm Cindy and Meredith's participation."),
        point("Which moments?", "Prioritize field trips, interviews, and meaningful activity that shows the Fellowship in action. Five local filming days are the proposed baseline."),
        point("Where do we film?", "One filming day in Nevada and one in Cincinnati, with one outbound travel/preparation day per trip. Confirm participant availability, locations and flights before booking."),
        point("How do we allocate coverage?", "If interview arrangements allow one trip instead of two, explore redirecting time toward one or two additional Colorado filming days."),
    ],
}
cej = deal("Center for Environmental Journalism", "Ted Scripps Fellowship 30th Anniversary Film", "Referral", 2,
    "2026-10-23T22:00:00Z",
    [ev("2026-10-06T16:00:00Z", "Intro to the CEJ through a CU Journalism referral"),
     ev("2026-10-09T18:30:00Z", "Discovery call with Cindy and Meredith"),
     ev("2026-10-14T20:00:00Z", "Working proposal sent · $49,000"),
     ev("2026-10-20T17:15:00Z", "They asked to see a range of options"),
     ev("2026-10-23T22:00:00Z", "Options packet sent · A $44k + travel, B $29k, C $18k")],
    options=[
        option("Option A", "Full vision", "The full vision, plus every asset for a multi-channel campaign.",
               5, 2, 6, 7, 3, ["trailer", "socialCut", "verticalCut", "interviewLibrary", "rawFootage"],
               travel=2, places="Nevada, Cincinnati", allowance=5000, quote=44000, hand_off=["planning", "media"]),
        option("Option B", "Close to full vision", "Close to the full vision, with a smaller team and fewer days. The main film only.",
               4, 2, 5, 6, 2, quote=29000, hand_off=["planning", "media"]),
        option("Option C", "Bare bones", "The essentials, simply told. The main film only.",
               3, 1, 4, 5, 2, quote=18000, hand_off=["planning", "media"], client_tasks=[
                   "Research and select the fellows with the strongest stories, with backgrounds and key milestones",
                   "Arrange participants, interview times, quiet campus rooms and filming access",
                   "Supply background materials and any archives, with permission information"],
               note="With one collaborator, camera, sound and lighting overlap while Emma directs. Setup is more sequential, simultaneous coverage is limited and the edit is simpler."),
    ],
    contacts=[("Cindy", "CEJ", ""), ("Meredith", "CEJ", "")],
    location="Boulder and Denver, plus Nevada and Cincinnati",
    budget="Open; asked to see a range",
    notes="30th anniversary of the Ted Scripps Fellowship. Want something that feels alive: honest voices, field trips, cinematic footage. Cindy and Meredith may both appear. Former fellows in Nevada and Cincinnati; one trip instead of two is possible if interviews line up. Premiere in spring 2027.",
    story=cej_story,
    milestones=[("Research + planning", "After approval / fall 2026"), ("Filming", "Fall 2026 – February 2027"),
                ("Post-production", "January – March 2027"), ("First delivery", "Early March 2027"),
                ("Final delivery", "By end of March 2027")],
    steps=[("Finalize the scope and budget together", False), ("Complete contracting and confirm the payment schedule", False),
           ("Sign the project agreement and begin pre-production", False)],
    links=["https://claude.ai/artifact/DPQFCVkDiThGpaRNnT61yc", "https://claude.ai/artifact/MQg6JDRMWVSy62bf2UC2i5"])
cej["milestones"] = [{"id": uid(), "phase": p, "when": w} for p, w in [
    ("Kickoff call", "Nov 20, 2026"), ("Research + planning", "Nov 20 – Dec 11, 2026"),
    ("Filming", "Dec 1, 2026 – Feb 12, 2027"), ("Rough cut", "Mar 2, 2027"),
    ("Your feedback due", "Mar 9, 2027"), ("Final delivery", "Mar 26, 2027")]]
cej.update({
    "discovery": {
        "goal": "Celebrate 30 years of the Ted Scripps Fellowship and show why it matters, through the people behind it",
        "audience": "Current and former fellows, the Scripps family, CU and the wider environmental journalism community",
        "whereWatched": "The 30th anniversary celebration, the CEJ website and social channels",
        "onCamera": "Cindy, Meredith and 3–4 current and former fellows",
        "locations": "Boulder and Denver, plus former fellows in Nevada and Cincinnati",
        "formats": "One anniversary film, a trailer, social cutdowns and an interview library",
        "goLive": "2027-04-01T16:00:00Z", "callDate": "2026-10-09T18:30:00Z"},
    "exclusions": ["Location permits and fees", "Travel beyond the $5,000 allowance", "Additional interview sessions", "Rush turnaround"],
    "formats": ["4K master", "Web-ready version (1080p)", "Captions file (SRT)", "Vertical 9:16 versions"],
    "shootStart": "2026-12-01T16:00:00Z",
    "addOns": [{"id": uid(), "name": "Extra revision round", "price": 500, "note": "One more round of consolidated feedback"},
               {"id": uid(), "name": "Drone footage", "price": 400, "note": "Where permitted, per shoot day"}],
    "terms": {"depositPercent": 30,
              "paymentSchedule": "30% to begin pre-production, 40% when filming starts, 30% on final delivery.",
              "usageRights": "CEJ can use the finished films anywhere, forever. Emma keeps the copyright and may show the work in her portfolio.",
              "cancellation": "Payments for completed phases are non-refundable. Filming dates can move with a week's notice.",
              "weather": "If weather makes an outdoor shoot unsafe or unusable, we reschedule together at no extra cost."},
    "proofProjectIDs": [restoration["id"], foodbank["id"], ortiz["id"]],
    "testimonial": "\u201cEmma found the people behind the project and let them tell it. Our donors still bring it up.\u201d (sample, replace with a real quote) — Boulder Watershed Collective",
    "acceptHow": "Reply to say which option you'd like. I'll send the agreement and the first invoice the same day.",
    "expiresOn": "2026-11-20T23:00:00Z", "nameChecked": True, "shortProposal": False,
})

deals = [
    cej,
    deal("Anh & Tom Nguyen", "Nguyen Wedding Film", "Email", 1, "2026-10-30T19:30:00Z",
         [ev("2026-10-29T17:00:00Z", "Inquiry came in by email"), ev("2026-10-30T19:30:00Z", "Proposal sent · $6,500")],
         options=[option("Option A", "Wedding day", "Ceremony, toasts and a six-minute highlight film.", 1, 1, 0, 6, 1, ["socialCut"], quote=6500)],
         contacts=[("Anh Nguyen", "Bride", "")], location="Chautauqua Community House, Boulder",
         event_date="2027-01-23T21:00:00Z", budget="Around $6–7k",
         notes="Winter wedding, about 90 guests. Want the toasts in full and a short teaser for Instagram."),
    deal("Switchback Supply Co.", "Spring catalog video", "Website form", 2, "2026-11-04T18:00:00Z",
         [ev("2026-10-27T15:00:00Z", "Inquiry from the website form"), ev("2026-10-29T18:00:00Z", "Call: two days on trails above Golden"),
          ev("2026-11-01T17:00:00Z", "Proposal sent"), ev("2026-11-04T18:00:00Z", "They asked about adding a vertical cut")],
         options=[option("Option A", "Catalog film", "A two-minute catalog film with cuts for social.", 2, 1, 0, 2, 2, ["socialCut", "verticalCut"])],
         contacts=[("Dana Reyes", "Marketing lead", "")], location="Golden, CO", budget="$10–12k"),
    deal("Priya Patel", "Family portraits + short film", "Email", 0, local_iso(-1, 16),
         [ev(local_iso(-2, 9), "Inquiry came in by email"), ev(local_iso(-1, 16), "Discovery call")],
         location="Chautauqua Park, Boulder", event_date="2026-12-12T23:00:00Z", budget="About $600",
         notes="Three generations visiting for the holidays. Mostly photos, maybe a one-minute film."),
    deal("Kestrel Ridge", "Ski season promo", "Instagram", 0, NOW,
         [ev(NOW, "DM on Instagram asking about a season promo")],
         budget="Didn't say", notes="Small ski area near Nederland. Want something for opening weekend in December."),
    deal("Sarah & James Hartley", "Hartley Wedding", "Email", 3, "2026-10-02T16:05:00Z",
         [ev("2026-09-14T17:12:00Z", "Inquiry came in by email"), ev("2026-09-16T19:40:00Z", "Quote sent · $5,200"),
          ev("2026-10-02T16:05:00Z", "Won · booked with a $1,500 deposit")],
         options=[option("Option A", "Wedding day", "Ceremony and reception with a highlight film.", 1, 1, 0, 6, 1, quote=5200)],
         location="Planet Bluegrass, Lyons", project_id=hartley["id"]),
    deal("Old Mill Brewing", "Taproom brand reel", "Referral", 4, "2026-10-27T20:00:00Z",
         [ev("2026-10-08T17:00:00Z", "Referral from Ortiz Coffee"), ev("2026-10-13T18:00:00Z", "Proposal sent · $3,800"),
          ev("2026-10-27T20:00:00Z", "Lost: went with someone cheaper")],
         options=[option("Option A", "Brand reel", "A 90-second taproom reel.", 1, 0, 1, 2, 1, quote=3800)],
         lost="Went with someone cheaper"),
]
deals[3]["discovery"] = {
    "goal": "Holiday portraits of three generations, plus a one-minute film to share with family far away",
    "audience": "The family, near and far", "whereWatched": "",
    "onCamera": "Priya, her parents and her kids: 7 people", "locations": "Chautauqua Park, one morning",
    "formats": "", "goLive": "2026-12-20T17:00:00Z", "callDate": local_iso(-1, 16)}

# The won deal points at its option
deals[5]["chosenOptionID"] = deals[5]["options"][0]["id"]

# ---- money + gear -----------------------------------------------------------
pid = {p["name"]: p["id"] for p in projects}
def t(date, amount, desc, account, category, project=None):
    return {"id": uid(), "date": date + "T17:00:00Z", "amount": amount, "description": desc, "account": account,
            "category": category, "projectID": pid.get(project) if project else None, "note": None}
txns = [
    # September
    t("2026-09-02", 600, "Venmo from Maria Lopez · engagement deposit", "venmo", "weddings", "Lopez Engagement"),
    t("2026-09-05", -59.99, "ADOBE *CREATIVE CLOUD", "card", "software"),
    t("2026-09-06", -15.00, "FRAME.IO PRO", "card", "software"),
    t("2026-09-10", -24.99, "SQUARESPACE INC", "card", "marketing"),
    t("2026-09-12", -165.00, "HISCOX SMALL BUSINESS INSURANCE", "checking", "insurance"),
    t("2026-09-15", -11.99, "DROPBOX PLUS", "card", "storage"),
    t("2026-09-18", -400, "Venmo to Jordan Reyes · second shooter, Chen", "venmo", "crew", "Chen Anniversary"),
    t("2026-09-20", -86.40, "SHELL OIL · Estes Park", "card", "travel", "Chen Anniversary"),
    t("2026-09-22", -1500, "Transfer to personal savings", "checking", "ownerDraw"),
    t("2026-09-25", -16.99, "ARTLIST.IO", "card", "music"),
    t("2026-09-28", -350, "Payment to credit card", "checking", "transfer"),
    t("2026-09-28", 350, "Payment thank you", "card", "transfer"),
    # October
    t("2026-10-02", 1500, "Venmo from Sarah Hartley · wedding deposit", "venmo", "weddings", "Hartley Wedding"),
    t("2026-10-03", 1000, "ACH ORTIZ COFFEE ROASTERS · deposit", "checking", "brand", "Ortiz Brand Film"),
    t("2026-10-05", -59.99, "ADOBE *CREATIVE CLOUD", "card", "software"),
    t("2026-10-06", -15.00, "FRAME.IO PRO", "card", "software"),
    t("2026-10-07", -1998.00, "B&H PHOTO · Sony FE 24-70mm GM II", "card", "gear"),
    t("2026-10-09", -42.50, "Lunch with Cindy + Meredith (CEJ)", "card", "meals"),
    t("2026-10-10", -300, "Venmo to Alex Moreno · second shooter, Lopez", "venmo", "crew", "Lopez Engagement"),
    t("2026-10-12", -24.99, "SQUARESPACE INC", "card", "marketing"),
    t("2026-10-15", 1600, "Zelle from Wei Chen · balance", "checking", "weddings", "Chen Anniversary"),
    t("2026-10-15", -11.99, "DROPBOX PLUS", "card", "storage"),
    t("2026-10-18", -125.00, "LENSRENTALS · Ronin RS3 kit", "card", "rentals", "Ortiz Brand Film"),
    t("2026-10-20", -1000, "Transfer to bank", "venmo", "transfer"),
    t("2026-10-20", 1000, "Transfer from Venmo", "checking", "transfer"),
    t("2026-10-22", -600, "Venmo to Jordan Reyes · camera op, Ortiz", "venmo", "crew", "Ortiz Brand Film"),
    t("2026-10-22", -64.20, "CONOCO · Denver", "card", "travel", "Ortiz Brand Film"),
    t("2026-10-25", -16.99, "ARTLIST.IO", "card", "music"),
    t("2026-10-27", -2400, "Payment to credit card", "checking", "transfer"),
    t("2026-10-27", 2400, "Payment thank you", "card", "transfer"),
    t("2026-10-28", -2000, "Transfer to personal savings", "checking", "ownerDraw"),
    t("2026-10-30", 450, "PayPal · headshot mini-session", "paypal", "portraits"),
    t("2026-10-30", -13.35, "PayPal fee", "paypal", "fees"),
    # November
    t("2026-11-02", -59.99, "ADOBE *CREATIVE CLOUD", "card", "software"),
    t("2026-11-04", 1100, "ACH SUMMIT GYM LLC · deposit", "checking", "brand", "Summit Gym Promo"),
    t("2026-11-04", -189.99, "SAMSUNG T7 SHIELD 2TB", "card", "storage"),
    t("2026-11-05", -18.75, "SQ *BLUEBIRD COFFEE BOULDER", "card", "uncategorized"),
    t("2026-11-05", -45.12, "AMZN MKTP US*2K4", "card", "uncategorized"),
]
def r(project, client, label, amount, due):
    return {"id": uid(), "projectID": pid.get(project), "client": client, "label": label, "amount": amount,
            "due": due + "T17:00:00Z", "paidOn": None}
receivables = [
    r("Lopez Engagement", "Maria & Andre Lopez", "Final invoice (sent Oct 24)", 1800, "2026-11-03"),
    r("Ortiz Brand Film", "Ortiz Coffee Roasters", "Balance on delivery", 3800, "2026-11-20"),
    r("Summit Gym Promo", "Summit Gym", "Balance on delivery", 1100, "2026-12-04"),
    r("Hartley Wedding", "Sarah & James Hartley", "Balance on delivery", 3700, "2026-12-18"),
]
def g(name, kind, bought, paid, life, shoots, service=None, note=None, serial=None):
    return {"id": uid(), "name": name, "kind": kind, "bought": bought + "T17:00:00Z", "paid": paid, "lifeYears": life,
            "serial": serial, "lastService": (service + "T17:00:00Z") if service else None, "serviceNote": note, "shoots": shoots}
gear = [
    g("Sony A7S III · body 1", "camera", "2023-03-14", 3498, 5, 41, "2026-08-12", "Sensor clean"),
    g("Sony A7S III · body 2", "camera", "2024-01-20", 3498, 5, 28),
    g("Sony FE 24-70mm f/2.8 GM II", "lens", "2026-10-07", 1998, 7, 2),
    g("Sony FE 85mm f/1.4 GM", "lens", "2023-05-02", 1398, 7, 37, "2025-11-03", "Clean + check"),
    g("DJI Mavic 3 Pro", "drone", "2024-04-11", 2199, 4, 16, "2025-09-30", "Firmware + props"),
    g("DJI Ronin RS3 Pro", "support", "2023-05-20", 869, 5, 33, "2026-09-08", "Firmware update"),
    g("Rode Wireless Pro", "audio", "2024-06-03", 399, 5, 19),
    g("Aputure 300d II", "lighting", "2023-02-10", 849, 6, 22),
    g("MacBook Pro 16\" M3 Max", "computer", "2023-11-15", 3999, 4, None),
]
money = {"txns": txns, "openingDate": "2026-09-01T00:00:00Z",
         "openings": {"checking": 9800, "card": 0, "venmo": 350, "paypal": 0},
         "rules": [], "receivables": receivables, "gear": gear}

os.makedirs(APP_SUPPORT, exist_ok=True)
with open(os.path.join(APP_SUPPORT, "projects.json"), "w") as f:
    json.dump(projects, f, indent=2)
with open(os.path.join(APP_SUPPORT, "money.json"), "w") as f:
    json.dump(money, f, indent=2)
with open(os.path.join(APP_SUPPORT, "deals.json"), "w") as f:
    json.dump(deals, f, indent=2)
with open(os.path.join(APP_SUPPORT, "rate_card.json"), "w") as f:
    json.dump({"ownerName": "Emma Pion-Berlin", "businessName": "Visual Storytelling",
               "email": "emmapionberlin@gmail.com", "website": "emmapionberlin.com"}, f)
with open(os.path.join(APP_SUPPORT, "trust_settings.json"), "w") as f:
    json.dump({"staleAfterDays": 180, "checkpointGigabytes": 100, "checkpointFileCount": 200,
               "archiveDestinationPath": SERVER,
               "autoApply": {"Archive": False, "Duplicate Removal": False, "Cache Cleanup": False, "Organize": False}}, f)
for stale in ("action_log.json",):
    p = os.path.join(APP_SUPPORT, stale)
    if os.path.exists(p):
        os.remove(p)
run("defaults", "write", "com.1047ventures.lens", "scanRootPaths", "-array", SSD)

used = shutil.disk_usage(SSD)
print(f"Emma SSD: {used.used / 1e9:.2f} GB used of {used.total / 1e9:.2f} GB ({used.used / used.total:.0%})")
