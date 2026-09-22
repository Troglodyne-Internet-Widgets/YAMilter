# NAME

Milter::Recipe - Framework for building a milter based on various recipes

# VERSION

version 1.001

# SYNOPSIS

```perl
# What yamilter --config /etc/yamilter.cfg does
use Milter::Recipe;
Milter::Recipe->new('/etc/yamilter.cfg')->run();
```

# DESCRIPTION

Yet another Milter program.

The focus here is to have some overlooked filters & common business logic that you can load up with simple configuration.

Any sub-namespace of `Milter::Recipe` is considered available to be loaded.

Based on [Sendmail::PMilter](https://metacpan.org/pod/Sendmail%3A%3APMilter); most of the work making a recipe is in writing a milter callback used thereby.

While there exist older modular milters such as `Mail::Milter`, they have not received updates in many, many years.
Most of the functionality therein is better covered by other software such as opendmarc/opendkim or postfix itself.

# CONFIGURATION

```
[service]
pidfile=/var/run/yamilter.pid
sock=/var/run/yamilter.sock
workers=10
debug=0
order=MailingList, EnvelopeMatch
[Language]
langs=en, fr, es
action=discard
...
```

List the recipes you want to load, and then specify any configuration relevant to them (if applicable).

A recipe section must have at least one key (`action=reject` will do).
[Config::Simple](https://metacpan.org/pod/Config%3A%3ASimple) does not see a section with no keys, so the recipe is not loaded.

## Service configuration

Included in the `service/` directory is a systemd service configuration you can drop in and use right away.
It is written to refer to `/etc/yamilter.cfg` as the config file.

The `service` section above allows configuration of where the PID/Socket files live, and how many workers to run.
The values above, apart from `order`, are the defaults if you omit these parameters.

`decision_log` names a file to append a line to for every decision a recipe makes (anything but continue):
the time, the MTA's queue id (the `{i}` macro, which postfix sends), the recipe, the callback, and the result, separated by tabs.
Off unless set.  `yamilter-corpus` uses it to record which recipe decided each message.

`order` sets the order recipes run in, which matters when one can accept a message outright (see [Milter::Recipe::MailingList](https://metacpan.org/pod/Milter%3A%3ARecipe%3A%3AMailingList)),
since that ends milter processing for the message.
Recipes it does not name run after those it does, alphabetically; by default that is all of them.

You'll likely want to configure chrooted dovecot to have the sock inside its chroot.

## Recipe configuration

Each recipe will accept an `action` parameter.
By default, each recipe MUST reject, but if the action is set, do that instead.

The only meaningful actions to take other than reject are discard or tempfail.
Maybe you want to accept, but that is usually ill-advised.

TODO: add a 'spam' action to add a spam header and accept.

All other recipe configuration is up to the recipe itself and you should refer to their documentation.

# RECIPES

The ones provided with the YAMilter program are both scratching my personal itch,
and considered sufficient example for other authors to do the same.

- [Milter::Recipe::Language](https://metacpan.org/pod/Milter%3A%3ARecipe%3A%3ALanguage)

    Reject mails which are not comprehensible to your userbase.

- [Milter::Recipe::EnvelopeMatch](https://metacpan.org/pod/Milter%3A%3ARecipe%3A%3AEnvelopeMatch)

    Reject mails whose From: is not the envelope sender, or which are not addressed To: or Cc: the envelope recipient.

- [Milter::Recipe::MailingList](https://metacpan.org/pod/Milter%3A%3ARecipe%3A%3AMailingList)

    Reject list and bulk mail with malformed list headers, or missing the ones you require, or with an unsubscribe link but no List-Unsubscribe header;
    and accept mail from lists you trust outright, when your MX's DKIM check vouches for them.

Writing them should be made significantly easier thanks to being able to test with [Milter::Client](https://metacpan.org/pod/Milter%3A%3AClient),
and [Milter::Harness](https://metacpan.org/pod/Milter%3A%3AHarness), which runs the milter for the duration of a test.

## Testing recipes against real mail

`yamilter-corpus` replays a copy of your mailboxes through a yamilter configuration,
and records the verdict for each message in an SQLite database.
You can then look at the mail that got through for patterns, and write a recipe for them.

```
yamilter-corpus index  --db corpus.db --source /path/to/Maildir
yamilter-corpus run    --db corpus.db --config recipes.cfg --each --jobs 8
yamilter-corpus report --db corpus.db headers
yamilter-corpus report --db corpus.db diff 1 2
```

# FURTHER IDEAS

Based on the spam I currently receive, implementing these below (and the above) would remove 99.99% of the spam I receive on my mx.

I suspect most of this has prior art elsewhere, as if I could come up with this in an afternoon I'm sure for-pay MXes figured these out years ago.

## RejectUnsolicitedMailingLists

[Milter::Recipe::MailingList](https://metacpan.org/pod/Milter%3A%3ARecipe%3A%3AMailingList) refuses list mail which gets its headers wrong, and unsubscribe links without a List-Unsubscribe header.
What it does not do yet is ask the list.

Normally, mailing list software has a mechanism to verify that a user has in fact signed up for this list.

Spammers do not get in the habit of hosting services which might respond in the affirmative to this, as people tend to retaliate against them quite fiercely.

As such, checking for this much like sender verification connections is valuable.

MailingList only counts unsubscribe links; mails asking you to reply with "unsubscribe" to stop receiving them get past it.

## 419Detect

Uses an LLM to identify if an email is obviously a 419 (advance fee) scam of some kind, and rejects it.

## InsiderThreats

Reject sender domains coming from local which are known to not resolve to this host.

This is one of the problems with shared hosting.
You will eventually get a client that wants to run sendmail overtime to phish with a stolen CC.

This way they at least have to go to the trouble of buying a domain to attempt fraud.

## PhishingDomains

Reject mails from domains which resolve to other live domains when homoglyph replaced, as these are almost always phishing.

Reject mails from domains which resolve to other live domains when the TLD is swapped, e.g. `google.su` versus `google.com`.

(You should already configure your mx to reject domains that do not resolve).

## ASNBlock

Outright block entire ASNs.  For when all else fails.

## HeaderIfSize

Add a header (likely to control relaying behavior) if the mail is above a certain size.

It is a common practice to throw up your hands and use a for-pay SMTP relay to be deliverable to the big 10 email providers.
However this can get pricey (or fail outright) if you send things with big attachments, and you probably want to avoid that.

# CONSTRUCTOR

## new($cfile)

Creates the Milter recipe singleton.  Subsequent calls simply return the same object.

## pidfile, sock, workers, cfile, debug

The `service` settings from the configuration (with their defaults), and the configuration file's path.

# STATIC METHODS

## $class->config()

Retrieve the config section relevant to the current class, as a hashref, with the service's `debug` and `no_accum` settings added.

If your Recipe requires configuration, this is the method to call.
It is a lookup on the singleton, so calling it from every callback costs nothing to speak of.

## $class->config\_action()

Every recipe MUST support returning an action to take after doing its' test.

Acceptable actions are (reject, discard, tempfail, accept, continue, loop).

This is the sub to call to accomplish that:

```
...
return __PACKAGE__->config_action();
...
```

## ($smtp\_code, $esmtp\_code) = $class->config\_code()

Sometimes you will want a callback to do $ctx->setreply() to have a complicated response.

This will map the config action to the appropriate response code to use as the first arg to setreply().

Dies in the event your action has no appropriate code (e.g. discard, loop).

## @values = $class->config\_list($value)

A configuration value as a list: [Config::Simple](https://metacpan.org/pod/Config%3A%3ASimple) hands back a comma separated value as an arrayref, and a single one as a string.
Values are trimmed, and empty ones dropped.  An undefined value is an empty list.

## $state = $class->stash($ctx, \[\\%fresh\])

The recipe's own part of the connection's private data, kept under its package name so recipes do not trample each other.
Given `\%fresh`, replaces it first, which recipes do at MAIL FROM so nothing carries over from an earlier message on the connection.
Returns undef if nothing was ever stashed.

## $class->config\_reply($ctx, $message)

Take the configured action, with `$message` as the SMTP reply when the action has one (reject and tempfail).
Returns the action, so a callback which has made up its mind can end with:

```
return __PACKAGE__->config_reply( $ctx, "Your mail is not welcome here" );
```

# METHODS

## run

Actually run the milter.

Sets up some default milter callbacks that generally do the right thing:

- 1)
Continue until EOM, then accept.  The recipes' own end of message callbacks run before this one, so they can still decide.
- 2)
On Connect() we setpriv an empty hashref that you can store connection specific state within to support functionality requiring multiple callbacks.
- 3)
On Header() and Body() we accumulate the header and body fragments into the 'header' and 'body' keys of said hashref, that you might consult them in EOH, EOB and EOM.
Each header is accumulated as a `"Name: value\n"` line.  Both start afresh at each MAIL FROM, since a connection can carry several messages.

3\. Has some consequences in that if you don't limit the size of msgs and headers.
With 10 workers each handling 100 conns, your upper limit if say, you get a bunch of 1MB mails would be ~1GB of ram worst case.

DOS prevention is outside the scope of this milter.  You should limit the scope of such with mailserver size limits and # of workers available to the milter.

If absolutely necessary, accumulation can be disabled with the `service.no_accum` config flag, but you will need to use Milter modules which can stream rather than slurp.
This is advertised to modules as the `no_accum` flag passed in their config, so they can make sane decisions about this.
It is necessary that Milter::Recipe child modules document what they do about this.

The acccumulation feature is primarily here to ease development and testing of new milters,
but there exist rare problems which require full context to be correct and which have incompressible intermediate results.

## cb

Return the hash of callbacks to be run by the milter.

## loaded\_recipes

The package names of the recipes loaded from the configuration, in the order they run (see `order` in ["Service configuration"](#service-configuration)).

## accept, cont, reject

Return `SMFIS_ACCEPT`, `SMFIS_CONTINUE` or `SMFIS_REJECT`, for recipe callbacks to return.
Most callbacks want `__PACKAGE__->cont()`, or `__PACKAGE__->config_action()` when they have made up their mind.

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/Troglodyne-Internet-Widgets/YAMilter/issues](https://github.com/Troglodyne-Internet-Widgets/YAMilter/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

# AUTHORS

Current Maintainers:

- George S. Baugh <teodesian@gmail.com>

# CONTRIBUTOR

Andy Baugh <andy@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2026 Troglodyne LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
