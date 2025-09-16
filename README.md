# YAMilter

Yet another Milter program.

`yamilter --config /etc/yamilter.cfg`

The focus here is to have some overlooked filters & common business logic that you can load up with simple configuration.

Any sub-namespace of `Milter::Recipe` is considered available to be loaded.

Based on `Sendmail::Milter`; most of the work making a recipe is in writing a milter callback used thereby.

## Configuration

```
[service]
pidfile=/var/run/YAMilter.pid
sock=/var/run/YAMilter.sock
[recipes]
Language
MatchingFrom
[Language]
langs=en, fr, es
action=discard
...
```

List the recipes you want to load, and then specify any configuration relevant to them (if applicable).

### Service configuration

Included in the service/ directory is a systemd service configuration you can drop in and use right away.
It is written to refer to /etc/yamilter.cfg as the config file.

The `service` section above allows configuration of where the PID/Socket files live.

You'll likely want to configure chrooted dovecot to have these inside its chroot.

### Recipe configuration

Each recipe will accept an 'action' parameter.
By default, each recipe MUST reject, but if the action is set, do that instead.

The only meaningful actions to take other than reject are discard or tempfail.
Maybe you want to accept, but that is usually ill-advised.

TODO: add a 'spam' action to add a spam header and accept.

All other recipe configuration is up to the recipe itself and you should refer to their documentation.

## Milter Recipes

The ones provided with the YAMilter program are both scratching my personal itch,
and considered sufficient example for other authors to do the same.

### Language

Reject mails which are not comprehensible to your userbase, as specified by the langs in the config file.

Uses Lingua::Identify to scan the body of messages and rejects those not a high probability of the preferred language(s).

## TODO: Further Ideas

Based on the spam I currently recieve, implementing these below (and the above) would remove 99.99% of the spam I recieve on my mx.

I suspect most of this has prior art elsewhere, as if I could come up with this in an afternoon I'm sure for-pay MXes figured these out years ago.

### MatchingFrom

Reject mails which have a differing envelope sender and 'From' Header.

A common oversight by spammers, especially when they are sending spoofed email from a rooted box.

### RejectUnsolicitedMailingLists

Spammers now frequently include a Mailing list unsubscribe header, because google looks for it specifically.

Normally, mailing list software has a mechanism to verify that a user has in fact signed up for this list.

Spammers do not get in the habit of hosting services which might respond in the affirmative to this, as people tend to retaliate against them quite fiercly.

As such, checking for this much like sender verification connections is valuable.

It is also of value to reject mails without an unsubscribe header, but some variation of "to stop recieving such communications reply, or click etc".

### 419Detect

Uses an LLM to identify if an email is obviously a 419 (advance fee) scam of some kind, and rejects it.

### InsiderThreats

Reject sender domains coming from local which are known to not resolve to this host.

This is one of the problems with shared hosting.
You will eventually get a client that wants to run sendmail overtime to phish with a stolen CC.

This way they at least have to go to the trouble of buying a domain to attempt fraud.

### PhishingDomains

Reject mails from domains which resolve to other live domains when homoglyph replaced, as these are almost always phishing.

Reject mails from domains which resolve to other live domains when the TLD is swapped, e.g. `google.su` versus `google.com`.

(You should already configure your mx to reject domains that do not resolve).

### ASNBlock

Outright block entire ASNs.  For when all else fails.

### HeaderIfSize

Add a header (likely to control relaying behavior) if the mail is above a certain size.

It is a common practice to throw up your hands and use a for-pay SMTP relay to be deliverable to the big 10 email providers.
However this can get pricey (or fail outright) if you send things with big attachements, and you probably want to avoid that.

### LICENSE

MIT
