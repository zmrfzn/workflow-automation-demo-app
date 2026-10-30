/**
 * Parse New Relic pool-lab invitation emails from a Gmail label.
 *
 * Pool-lab variant of automation/appsscript/parse-invitations.gs.
 * Differences: no workload names, configurable address prefix/domain/label/lookback,
 * and when several invites exist for the same address the NEWEST one wins.
 *
 * For every pool user (${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}) it extracts the
 * recipient address and the Accept Invitation link, adds the shared password, and
 * emails the result to you as a JSON array:
 *
 *   [ { "to": "<bare email>", "accept_link": "<url>", "password": "<shared pw>" }, ... ]
 *
 * Save that JSON as pool-lab/invites.json (read by pool-lab/selenium/pool_users.py).
 *
 * The password is NEVER written to the Apps Script log.
 * The emailed JSON necessarily contains it, so delete that email once invites.json is saved.
 */

// ============================== CONFIG ==============================
// Edit these before running. Everything is a plain `var` constant.

// Gmail label that your filter applies to the invite emails.
var GMAIL_LABEL = "lab-invites";

// Substring searched for in the subject. The real subject is
// "Your <org name> admin has invited you to New Relic" and the org name is not known here,
// so the default matches only the stable tail of it. If you want stricter matching, paste
// a real subject line from one of your invites (for example
// "Your Acme admin has invited you to New Relic").
var EMAIL_SUBJECT_FILTER = "has invited you to New Relic";

// Pool users are ${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}, for example labpool+001@example.com.
// "labpool+" is only an example: set your own prefix (including the trailing "+") and domain.
var POOL_EMAIL_PREFIX = "labpool+";
var POOL_USER_DOMAIN = "example.com";

// The one password shared by every pool user. If empty, the script aborts and includes NO user.
var POOL_USER_PASSWORD = ""; // e.g. "ChangeMe123!"

// Maximum number of Gmail threads to read.
var MAX_THREADS = 500;

// Only invites newer than this many hours are used. Computed at run time on every run.
var LOOKBACK_HOURS = 24;

// How many pool users you expect (001..N). Addresses in that range with no invite are listed
// in the log so you can see which invites are missing.
var POOL_USER_COUNT_EXPECTED = 20;

// ============================ END CONFIG ============================

var RESULTS_EMAIL_RECIPIENT = Session.getActiveUser().getEmail();

/** Escape every regex special character in a literal string. */
function escapeRegex(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\\/-]/g, "\\$&");
}

/** Anchored, case-insensitive matcher for exactly ${prefix}<digits>@${domain}. */
function buildPoolRegex() {
  return new RegExp("^" + escapeRegex(POOL_EMAIL_PREFIX) + "\\d+@" + escapeRegex(POOL_USER_DOMAIN) + "$", "i");
}

/**
 * Pull every bare address out of a header value such as
 * `Name <a@b.com>, c@d.com, "Last, First" <e@f.com>`.
 */
function extractAddresses(headerValue) {
  if (!headerValue) return [];
  var found = String(headerValue).match(/[^\s<>,;"'()]+@[^\s<>,;"'()]+/g);
  return found || [];
}

/** First address in the header value that matches the pool pattern, lowercased, or null. */
function matchPoolAddress(headerValue, poolRegex) {
  var addrs = extractAddresses(headerValue);
  for (var i = 0; i < addrs.length; i++) {
    if (poolRegex.test(addrs[i])) return addrs[i].toLowerCase();
  }
  return null;
}

/**
 * Find the pool address a message was sent to.
 * Order: To, then Cc, then Bcc, then X-Original-To / Delivered-To style lines in the raw
 * message headers. Returns { address, source } or null.
 * `source` says which place matched and is logged so you can see which fallback fired.
 */
function findPoolAddress(message, poolRegex) {
  var fields = [
    ["To", function () { return message.getTo(); }],
    ["Cc", function () { return message.getCc(); }],
    ["Bcc", function () { return message.getBcc(); }]
  ];
  for (var i = 0; i < fields.length; i++) {
    var value = null;
    try { value = fields[i][1](); } catch (e) { value = null; }
    var hit = matchPoolAddress(value, poolRegex);
    if (hit) return { address: hit, source: fields[i][0] };
  }

  // Last resort: the original recipient can survive only in a delivery header.
  var raw = null;
  try { raw = message.getRawContent(); } catch (e2) { raw = null; }
  if (raw) {
    var headerEnd = raw.search(/\r?\n\r?\n/);
    var headers = headerEnd >= 0 ? raw.substring(0, headerEnd) : raw;
    var lineRe = /^(X-Original-To|Delivered-To|X-Forwarded-To|Envelope-To):[ \t]*(.+)$/gim;
    var m;
    while ((m = lineRe.exec(headers)) !== null) {
      var rawHit = matchPoolAddress(m[2], poolRegex);
      if (rawHit) return { address: rawHit, source: "raw header " + m[1] };
    }
  }
  return null;
}

/**
 * Turn a list of Gmail messages into invite entries.
 * Pure of Gmail calls apart from the message getters, so it can be unit tested with mocks.
 * Returns { results, stats }.
 */
function collectInvites(messages, cutoff, poolRegex) {
  var stats = { scanned: 0, skippedOld: 0, skippedNoAddress: 0, skippedNoLink: 0, superseded: 0 };
  var newestByAddress = {};

  messages.forEach(function (message) {
    stats.scanned++;
    var date = message.getDate();

    if (date < cutoff) {
      stats.skippedOld++;
      Logger.log("Skipping old email from " + date + " (subject: " + message.getSubject() + ")");
      return;
    }

    var hit = findPoolAddress(message, poolRegex);
    if (!hit) {
      stats.skippedNoAddress++;
      Logger.log("Skipping message with no pool address (subject: " + message.getSubject() + ")");
      return;
    }
    if (hit.source !== "To") {
      Logger.log("Fallback used for " + hit.address + ": matched via " + hit.source + ", not the To header");
    }

    var link = extractAcceptLink(message.getBody());
    if (!link) {
      stats.skippedNoLink++;
      Logger.log("WARNING: no Accept Invitation link found for " + hit.address);
      return;
    }

    var prev = newestByAddress[hit.address];
    if (prev) {
      stats.superseded++;
      if (date <= prev.date) return; // keep the newer invite already stored
    }
    newestByAddress[hit.address] = { date: date, accept_link: link };
  });

  var addresses = Object.keys(newestByAddress).sort();
  var results = addresses.map(function (addr) {
    return { to: addr, accept_link: newestByAddress[addr].accept_link, password: POOL_USER_PASSWORD };
  });
  return { results: results, stats: stats };
}

/** Expected pool addresses (001..count) that have no entry in `results`. */
function findMissing(results, count) {
  var have = {};
  results.forEach(function (r) {
    var m = r.to.match(/(\d+)@/);
    if (m) have[parseInt(m[1], 10)] = true;
  });
  var missing = [];
  for (var i = 1; i <= count; i++) {
    if (!have[i]) {
      var n = String(i);
      while (n.length < 3) n = "0" + n;
      missing.push((POOL_EMAIL_PREFIX + n + "@" + POOL_USER_DOMAIN).toLowerCase());
    }
  }
  return missing;
}

function parseInvitations() {
  if (!POOL_USER_PASSWORD) {
    Logger.log("ABORT: POOL_USER_PASSWORD is empty. Set it in the CONFIG block and run again. No invites were processed or emailed.");
    return [];
  }

  var cutoff = new Date(Date.now() - LOOKBACK_HOURS * 60 * 60 * 1000);
  var poolRegex = buildPoolRegex();
  var query = "label:" + GMAIL_LABEL + " subject:\"" + String(EMAIL_SUBJECT_FILTER).replace(/"/g, "") + "\"";
  var threads = GmailApp.search(query, 0, MAX_THREADS);

  var messages = [];
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (message) { messages.push(message); });
  });

  var out = collectInvites(messages, cutoff, poolRegex);
  var results = out.results;
  var stats = out.stats;
  var missing = findMissing(results, POOL_USER_COUNT_EXPECTED);

  Logger.log("Query: " + query + " (" + threads.length + " threads, " + stats.scanned + " messages)");
  Logger.log("Parsed " + results.length + " invitations (one per address, newest wins).");
  Logger.log("Skipped old (older than " + LOOKBACK_HOURS + "h): " + stats.skippedOld);
  Logger.log("Skipped no Accept Invitation link: " + stats.skippedNoLink);
  Logger.log("Skipped no matching pool address: " + stats.skippedNoAddress);
  Logger.log("Older duplicate invites superseded: " + stats.superseded);
  if (missing.length) {
    Logger.log("MISSING " + missing.length + " of " + POOL_USER_COUNT_EXPECTED + " expected: " + missing.join(", "));
  } else {
    Logger.log("All " + POOL_USER_COUNT_EXPECTED + " expected addresses were found.");
  }

  Logger.log("Sending results via email...");
  emailResults(results);
  return results;
}

function emailResults(results) {
  var subject = "Pool-lab invitations (" + results.length + " parsed) — " + new Date().toLocaleString();
  var body = JSON.stringify(results, null, 2); // contains the shared password: delete this email after use
  GmailApp.sendEmail(RESULTS_EMAIL_RECIPIENT, subject, body);
  Logger.log("Results emailed to " + RESULTS_EMAIL_RECIPIENT);
}

/**
 * Web App entry point — call remotely via curl to get the JSON directly.
 * Deploy via: Deploy → New deployment → Web app (Execute as: Me, Access: Only myself)
 */
function doGet() {
  var results = parseInvitations();
  return ContentService
    .createTextOutput(JSON.stringify(results, null, 2))
    .setMimeType(ContentService.MimeType.JSON);
}

function extractAcceptLink(html) {
  // Match <a ...> tags whose visible text contains "Accept Invitation"
  var pattern = /<a[^>]+href="([^"]+)"[^>]*>[\s\S]*?Accept Invitation[\s\S]*?<\/a>/i;
  var match = html.match(pattern);
  if (match) return match[1];

  // Fallback: match any New Relic invitation or verification URL directly (US or EU login host)
  var fallback = html.match(/https:\/\/login\.(?:eu\.)?newrelic\.com\/(?:invitations|user_email_verifications)\/[^"'\s]+/i);
  return fallback ? fallback[0] : null;
}
