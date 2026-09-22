# YAMilter

Yet another Milter program.

`yamilter --config /etc/yamilter.cfg`

The focus here is to have some overlooked filters & common business logic that you can load up with simple configuration.

Any sub-namespace of `Milter::Recipe` is considered available to be loaded.

Based on `Sendmail::PMilter`; most of the work making a recipe is in writing a milter callback used thereby.

While there exist older modular milters such as Mail::Milter, they have not recieved updates in many, many years.
Most of the functionality therein is better covered by other software such as opendmarc/opendkim or postfix itself.

## Configuration

```
[service]
pidfile=/var/run/YAMilter.pid
sock=/var/run/YAMilter.sock
debug=0
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

The values above are the defaults if you omit these parameters.

You'll likely want to configure chrooted dovecot to have the sock inside its chroot.

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

Writing them should be made significantly easier thanks to being able to test with `Milter::Client`.
There is also a testing helper library in `t/lib/YAMilterTest.pm` that facilitates actually running the milter in testing context.

### Testing recipes against real mail

`yamilter-corpus` replays a copy of your mailboxes through a yamilter configuration.
It records the verdict for each message in an SQLite database.
You can then look at the mail that got through for patterns, and write a recipe for them.

1. Index a copy of your mail. The tool reads Maildir++ folders and mbox files.
   It does not copy the mail into the database. It stores a pointer to each message, plus its headers.

       yamilter-corpus index --db corpus.db --source /path/to/Maildir

2. Replay the mail through your recipes. `--each` makes one run for each recipe, so you see what each recipe blocked.

       yamilter-corpus run --db corpus.db --config recipes.cfg --each --jobs 8

3. Look at the mail that got through.

       yamilter-corpus report --db corpus.db headers
       yamilter-corpus report --db corpus.db values --header Subject
       yamilter-corpus report --db corpus.db list

4. Change a recipe, run again, and compare the two runs.

       yamilter-corpus report --db corpus.db diff 1 2

Run `yamilter-corpus --help` for all reports and options.
You can also query the database with `sqlite3`. `perldoc Milter::Corpus` describes the tables.

A recipe section in the configuration must have at least one key, for example `action=reject`.
Config::Simple ignores an empty section, so yamilter does not load that recipe.

### Language

Reject mails which are not comprehensible to your userbase.
Explicit whitelist specified by `langs` in the config file.

Uses Lingua::Identify to scan the body of messages and rejects those without a high probability of being written in the preferred language(s).

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
