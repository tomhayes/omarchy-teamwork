// Markup and process-argument safety: the shared sinks the widget hands
// Teamwork text to. Run with: node --test ui-tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const M = require("../Model.js")

const ROOT = path.join(__dirname, "..")
const QML = fs.readdirSync(ROOT).filter((f) => f.endsWith(".qml"))

// The body of the `{ ... }` block opening at `start` (the index of "{"),
// with nested blocks removed, so only the element's own properties remain.
function ownBody(src, start) {
  let depth = 0
  let out = ""
  let quote = null
  for (let i = start; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      if (c === "\\") { i++; continue }
      if (c === quote) quote = null
      if (depth === 1) out += c
      continue
    }
    if (c === '"' || c === "'") { quote = c; if (depth === 1) out += c; continue }
    if (c === "{") { depth++; continue }
    if (c === "}") { depth--; if (depth === 0) return out; continue }
    if (depth === 1) out += c
  }
  throw new Error("unbalanced braces")
}

test("every Text element in the plugin's QML is plain text", () => {
  let count = 0
  for (const file of QML) {
    const src = fs.readFileSync(path.join(ROOT, file), "utf8")
    // `Text {` as an element, or `component X: Text {`; not TextField/TextInput.
    const re = /(^|[\s:])Text\s*\{/g
    let m
    while ((m = re.exec(src)) !== null) {
      const brace = src.indexOf("{", m.index)
      const body = ownBody(src, brace)
      const line = src.slice(0, m.index).split("\n").length
      assert.match(body, /textFormat:\s*Text\.PlainText/, `${file}:${line} Text without textFormat: Text.PlainText`)
      count++
    }
    assert.doesNotMatch(src, /Text\.(AutoText|StyledText|RichText|MarkdownText)/, `${file} uses a rich text format`)
    assert.doesNotMatch(src, /\b(TextEdit|TextArea|Label)\s*\{/, `${file} uses a text element without a plain-text check`)
  }
  assert.ok(count > 30, "expected to find the plugin's Text elements, found " + count)
})

test("processes run as argv, never through a shell", () => {
  for (const file of QML) {
    const src = fs.readFileSync(path.join(ROOT, file), "utf8")
    assert.doesNotMatch(src, /["'](sh|bash|\/bin\/sh|\/bin\/bash)["']/, `${file} runs a shell`)
    assert.doesNotMatch(src, /Qt\.openUrlExternally/, `${file} opens URLs outside xdg-open`)
  }
  const panel = fs.readFileSync(path.join(ROOT, "Panel.qml"), "utf8")
  // Each notify-send ends its options with "--" before summary and body.
  const sends = panel.split('["notify-send"').length - 1
  const ends = (panel.match(/args\.push\("--", /g) || []).length
  assert.equal(sends, 2)
  assert.equal(ends, sends)
  // The search query follows "--"; descriptions and the sort field are one
  // --opt=value argument each, so a leading "-" can't become an option.
  assert.match(panel, /\["search", "--", root\.searchQuery\]/)
  assert.match(panel, /"--description=" \+ desc/)
  assert.match(panel, /"--sort-field=" \+ root\.sortField/)
  assert.match(panel, /command: \["xdg-open", url\]/)
})

test("notification text: markup, entities, links and bidi controls are inert", () => {
  const samples = [
    '<img src="https://tracker.invalid/p.png">',
    '<a href="https://evil.invalid">Open</a>',
    "<b>bold</b> <i>it</i> <u>u</u> <s>s</s> <em>em</em> <strong>st</strong> <br/>",
    "&lt;b&gt;double&lt;/b&gt; &amp;lt;i&amp;gt; &#60;u&#62; &#x3c;s&#x3e;",
    "Click https://evil.invalid/login now",
    "HTTP://EVIL.INVALID and file:///etc/passwd and ftp://x.invalid",
    "abc‮dcba⁦x⁩"
  ]
  for (const s of samples) {
    const out = M.notifySafe(s, 200)
    assert.ok(!/[<>&]/.test(out), out)
    // Omarchy's notification server links /https?:\/\/[^\s<]+/ in a body.
    assert.ok(!/https?:\/\//i.test(out), out)
    assert.ok(!/[a-z]:\/\//i.test(out), out)
    assert.ok(!/[‪-‮⁦-⁩]/.test(out), JSON.stringify(out))
  }
  // Still readable: the words survive.
  assert.ok(M.notifySafe("Click https://evil.invalid/login now").indexOf("evil.invalid/login") !== -1)
  assert.equal(M.notifySafe("-r 5 --app-name=x"), "-r 5 --app-name=x")
})

test("templates are filled in one pass", () => {
  assert.equal(M.formatArgs("%1 has been timing for %2.", ["Task %2 %1", "1:05"]), "Task %2 %1 has been timing for 1:05.")
  assert.equal(M.formatArgs("%2 then %1", ["a", "b"]), "b then a")
  assert.equal(M.formatArgs("%1 and %3", ["a"]), "a and %3")
  assert.equal(M.formatArgs(undefined, ["a"]), "")
  // The Panel builds the long-timer body this way, not with chained .arg().
  const panel = fs.readFileSync(path.join(ROOT, "Panel.qml"), "utf8")
  assert.match(panel, /Model\.formatArgs\(root\.tr\("notify\.longBody"\)/)
})

test("site URL matches what bin/teamwork accepts", () => {
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com:8443"), "")
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com:443"), "")
  assert.equal(M.cleanSiteUrl("https://projects.example.co.uk"), "https://projects.example.co.uk")
  assert.equal(M.cleanSiteUrl("https://Kacme.teamwork.com"), "")
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com\\@evil.invalid"), "")
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com/%2e%2e"), "")
  assert.equal(M.cleanSiteUrl("https://" + "a".repeat(63) + "." + "b".repeat(63) + "." + "c".repeat(63) + "." + "d".repeat(63) + ".com"), "")
  assert.equal(M.taskUrl("https://acme.teamwork.com:8443", 1), "")
  assert.equal(M.taskUrl("https://acme.teamwork.com", "1/../../x"), "")
  assert.equal(M.taskUrl("https://acme.teamwork.com", -1), "")
  assert.equal(M.taskUrl("https://acme.teamwork.com", 1.5), "")
})
