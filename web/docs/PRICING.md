# termio Pricing Strategy

Source of truth for numbers: [`pricing.json`](./pricing.json). This memo
explains the reasoning; if the two ever disagree, `pricing.json` wins.

## The model: one-time lifetime license, no subscription

termio sells a **one-time lifetime license**. Pay once, own it forever, **all
future updates included**. There is **no subscription, no yearly renewal, and no
"updates expire" cliff** — the version you buy keeps working, and you keep
getting new versions for free.

Two personal tiers split by **how many Macs** the license covers, plus a volume
Team tier:

| Plan | Price | Covers | Recommended |
|------|-------|--------|-------------|
| Solo | **$19.90** one-time | 1 Mac | |
| Pro | **$39.90** one-time | up to 3 Macs | ✅ |
| Team | **$39.90 / seat** one-time | 5+ seats, centrally managed + invoiced | |

Backed by a **30-day money-back guarantee** and a **7-day no-account free
trial**.

### Why one-time, and not a subscription

- **Near-zero marginal cost.** termio is a local-only developer tool. Sessions,
  PTYs, and git worktrees all run on the user's own machine. There is no
  per-user cloud compute to amortize, so a recurring charge would be renting out
  a cost we don't actually incur. The only hosted surface is a small
  accounts/licensing backend that scales with *purchases*, not daily use.
- **Developers prefer to own their tools.** The buyer runs agent CLIs from a
  terminal and is allergic to renting a local app by the month. A license they
  own outright removes that friction at the point of sale.
- **Simplicity is a feature — especially for a beta.** One price, one purchase,
  done. No "what happens when my year runs out?" No renewal anxiety. For a young
  product earning trust, a clean transaction is part of the pitch.
- **It mirrors the best indie Mac apps.** The apps this buyer already loves and
  pays for are one-time purchases. termio prices like the category it belongs to.

A subscription (the [superwhisper](https://superwhisper.com/) shape) makes sense
when the vendor carries ongoing per-user cost — hosted inference, storage, sync.
termio carries none of that, so it shouldn't price like it does. We also dropped
the previous per-seat + 50%/yr renewal idea: the renewal fence added explaining
to do for a product whose whole appeal is that it gets out of your way.

## Why tier by device count

Solo (1 Mac) vs Pro (up to 3 Macs) is a **natural, honest fence**. It charges
for something the customer can feel and self-assess, not for crippled features:

- A solo dev who works on **one machine** pays the lower price. Nothing is held
  back from them — they get every feature.
- Someone with a **laptop + desktop + a spare** (or a work Mac and a personal
  one) pays a bit more, because the license genuinely does more for them: it
  follows them across machines.
- **No artificial crippling.** Both tiers are the full app. The only difference
  is how many of *your* Macs the one license covers — a dimension the buyer
  already knows the answer to before they read a feature list.

Device count is the cleanest line we can draw that feels fair from both sides:
light users aren't overcharged, multi-Mac users pay in proportion to the value
they actually get.

## The numbers, and why each one

### Solo — $19.90, the impulse entry

**$19.90** sits squarely in the developer-tool *impulse* zone: under $20 is an
"easy yes" nobody opens a spreadsheet for. termio is a new entrant and a v0.x
beta whose value is orchestration polish on top of CLIs that are themselves free,
so the entry price has to win the sale at the first moment of delight, not after
deliberation. $19.90 is that number.

### Pro — $39.90, the recommended anchor

**$39.90** is the **recommended** tier and the price anchor. Listing it next to
Solo makes Solo look like the budget option and Pro look like the "real" choice —
classic good/better framing where the better option is the one we want most
people to pick. It stays comfortably under $40 — still an easy buy for a tool you
own forever — while capturing meaningfully more value from people who'll use
termio across several machines. Against unpeel's ~$59/seat it still reads as the
cheaper, own-it-outright option.

### The $20 gap is deliberate

The Solo→Pro gap is **$20** for **3× the Macs** — about **$13/Mac** on Pro versus
$20 for Solo's single machine. Anyone who owns more than one Mac does that math
instantly and upgrades: the per-machine price actually drops as you scale up, so
covering three Macs for $39.90 beats buying Solo twice over (which you can't
anyway — Solo is one machine). The gap is wide enough to price multi-Mac value
honestly, small enough that it reads as a deal, not a penalty.

### Team — $39.90/seat (same as Pro), managed tier at 5+

Team is priced at **$39.90/seat — the same as Pro, deliberately not discounted.**
Volume discounts at this scale are backwards: a company buying ten seats is a
*higher*-value customer than a solo dev, not a lower-value one, and it has more
budget, not less. Per-seat price is never what a company optimizes — salaries
dwarf it. What a company actually needs is *manageability*, and that is what the
Team tier sells: centralized license + seat management (assign, reclaim,
reassign), priority support, and a single invoice / PO. A 10-developer shop buys
Team for the admin console and one invoice, not ten individual Pro receipts — at
the same per-seat price. The **5-seat floor** is the qualifying minimum for that
managed tier, not a discount trigger.

Real volume discounting belongs at **genuine scale and negotiated** — 50+ seats
go through "talk to us," where a large commitment can justify a custom price. That
keeps small teams paying list (they have the budget) and reserves concessions for
deals big enough to earn them.

## The 30-day money-back guarantee

The guarantee is a **conversion lever**, not a support policy. It removes the
last bit of purchase risk: if termio doesn't fit your workflow, you get your
money back, no questions asked. For a beta from a new vendor, that reassurance
often matters more than the price itself — it turns "what if I waste $20?" into
"there's no way to lose."

It **complements** the 7-day trial rather than overlapping it:

- The **7-day no-account trial** removes risk *before* you pay — run the full
  app against your own repos, no card, no signup.
- The **30-day guarantee** removes risk *after* you pay — buy with confidence,
  and you still have weeks of real use to back out if it's not for you.

Together they cover the entire decision: try it free, then buy it knowing you can
still change your mind.

## Competitor comparison

| | termio | unpeel | superwhisper |
|---|---|---|---|
| Model | **One-time lifetime** | One-time per-seat license | Subscription (+ lifetime option) |
| Entry price | **$19.90** (Solo, 1 Mac) | ~$59 / seat | ~$8.49/mo or $84.99/yr |
| Recommended / next tier | $39.90 (Pro, 3 Macs) | per-seat | $249.99 lifetime |
| Volume / team | $39.90 / seat (5+, managed; 50+ negotiated) | per-seat | per-account |
| Updates | **All included, forever** | First year, then 50%/yr (~$29.50) to keep updating | Bundled while subscribed |
| Free trial | **7 days, no account, no card** | 7 days, no account | Free tier (limited) |
| Refund | **30-day money-back** | — | 30-day refund |

termio is positioned as **own-it-outright, priced well below unpeel, with no
renewal at all** — and explicitly *not* a subscription like superwhisper.

## Growth: referral program (planned for 1.x)

**Philosophy: in beta, give the product away to grow.** A free license in the
hands of a real, active developer is worth more than the ~$20–40 we didn't charge
— that developer brings word of mouth and more users. We optimize for adoption and
network effects now, not for squeezing early revenue. So referral rewards are
deliberately generous and **reach a free license outright** — that is the point,
not a leak to plug.

### The one guardrail that remains — and why

Even when giving the product away, we gate rewards on **real activation**, not
signup. This is *not* about protecting revenue (we've decided we don't mind giving
licenses away). It's about **giveaway quality**: the whole reason to give a license
away is to buy real usage and word of mouth. A license farmed by throwaway/bot
accounts brings neither — it's a giveaway that buys nothing. So a referral only
counts when the invited friend **genuinely activates**: creates an account via the
invite link *and* runs at least one real agent session (started a CLI in a live
PTY). Opening an empty tab does not count — that bar is too low to be faked-proof.

### The ladder (linear, generous, no exponential)

| Active referrals (friends who really used it) | Referrer earns |
|-----------------------------------------------|----------------|
| **1** | **+1 month** of full free use (trial extension) |
| **3** | a **free Solo license** (1 Mac, lifetime) |
| **5** | a **free Pro license** (up to 3 Macs, lifetime) |

The invited friend also gets a sweetener: a **14-day trial** (vs. 7) and **$5 off**
if they buy. No exponential growth and no per-referral month-stacking is needed —
the ladder already reaches "free Pro" in five steps, which is both maximally
generous and easy to understand. "Free Pro" is the natural ceiling; you can't earn
more than the product.

### Privacy: opt-in only (hard constraint)

termio's core promise is **local-only, no telemetry, no account required to try**.
Tracking that a friend "really activated" inherently needs an account plus one
minimal "activated" event — which conflicts with that promise. The resolution is
that the referral program is **strictly opt-in**: only people who *choose* to join
it create an account and emit that single activation event. Everyone else stays
fully local-only with zero reporting. The product and copy must state plainly that
*joining the referral program is the one thing that turns that event on.* If we
can't honor that, the referral program fights termio's core positioning — so this
constraint is not optional.

A minimal `referral` schema scaffold exists in `web/server` (codes, referrer,
invitee, activation/conversion status, reward granted), marked for 1.x; it is not
wired into checkout or the desktop app yet.

## Future levers — NOT in v1

Documented so we don't relitigate them; none ship in the first release.

- **Raise prices at 1.0.** Today's numbers are beta-entry pricing. When termio
  ships 1.0 and has earned deliberation, the anchor can move up.
- **Education discount.** A student/teacher discount (superwhisper runs 40% off)
  is plausible later; there's no verification flow in v1.
- **Launch promo.** A time-boxed introductory price using the struck-through
  anchors already in `pricing.json` (`anchorPriceCents`: $29 → $19.90,
  $59 → $39.90) to seed early adopters and reviews. Held back so launch pricing
  stays clean and credible until we choose to run it.

## Sources

- [unpeel.com](https://unpeel.com/) — per-seat one-time license, ~$59, first year
  of updates then ~$29.50/yr (50%) renewal, 7-day no-account trial.
- [superwhisper.com](https://superwhisper.com/) — subscription (~$8.49/mo,
  $84.99/yr) plus a $249.99 lifetime option, free tier, 40% student discount,
  30-day refund. ([pricing overview](https://spokenly.app/blog/superwhisper-pricing))

---

**In one sentence:** termio is a one-time, lifetime-license Mac developer tool —
Solo at $19.90 for one Mac, Pro at $29.90 for three, Team at $23.90/seat for 5+ —
that you own forever with all updates included, no subscription and no renewal,
sold behind a 7-day no-account trial and a 30-day money-back guarantee.
