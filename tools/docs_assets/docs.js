/* Search for the documentation. No tracking, nothing leaves the page: the index is one file read from this site. */
(function () {
  "use strict";
  function norm(s) { return (s || "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, ""); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  // What was typed is kept after a # in the address, which the browser never sends to the server (a ? would be sent on a reload).
  function remember(q) { try { history.replaceState(null, "", location.pathname + location.search + (q ? "#q=" + encodeURIComponent(q) : "")); } catch (e) {} }
  function fromAddress() {
    var h = location.hash.match(/^#q=(.*)$/);
    if (h) { try { return decodeURIComponent(h[1].replace(/\+/g, " ")); } catch (e) { return h[1]; } }
    return new URLSearchParams(location.search).get("q");
  }
  function tokens(q) { return norm(q).split(/[^a-z0-9_.\-:#\/]+/).filter(Boolean); }
  function mark(text, toks) {
    var out = esc(text);
    toks.forEach(function (t) {
      if (t.length < 2) return;
      try { out = out.replace(new RegExp("(" + t.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&") + ")(?![^<]*>)", "ig"), "<mark>$1</mark>"); } catch (e) {}
    });
    return out;
  }

  // ---- filter box on a long page: hides the entries that do not match
  var filter = document.querySelector("[data-docs-filter]");
  if (filter) {
    var entries = [].slice.call(document.querySelectorAll(".d-entry"));
    var count = document.querySelector("[data-docs-count]");
    var sections = [].slice.call(document.querySelectorAll(".d-section, .d-block"));
    var apply = function () {
      var toks = tokens(filter.value), shown = 0;
      entries.forEach(function (e) {
        var q = e.getAttribute("data-q") || "";
        var ok = toks.every(function (t) { return q.indexOf(t) !== -1; });
        e.hidden = !ok;
        if (ok) shown++;
      });
      sections.forEach(function (s) { s.hidden = !s.querySelector(".d-entry:not([hidden])"); });
      if (count) count.textContent = toks.length ? (shown + " of " + entries.length + " shown") : (entries.length + " entries");
    };
    filter.addEventListener("input", function () { apply(); remember(filter.value); });
    var initial = fromAddress();
    if (initial) filter.value = initial;
    apply();
    if (location.hash) { var el = document.getElementById(location.hash.slice(1)); if (el) { el.hidden = false; if (el.closest(".d-section")) el.closest(".d-section").hidden = false; el.scrollIntoView(); } }
  }

  // ---- the front page: search everything
  var box = document.getElementById("docs-search");
  if (!box) return;
  var results = document.getElementById("docs-results"), status = document.getElementById("docs-status"), cards = document.getElementById("docs-cards");
  var index = null, loading = null;
  function load() {
    if (index) return Promise.resolve(index);
    if (!loading) loading = fetch("/docs/docs-index.json").then(function (r) { return r.json(); }).then(function (d) {
      d.forEach(function (e) { var n = norm(e.n); e._n = n + " " + n.replace(/[-_.]+/g, " "); e._n0 = n; e._s = norm(e.s); e._x = norm(e.x); });
      index = d; return d;
    });
    return loading;
  }
  var STOP = {the:1,and:1,for:1,not:1,that:1,this:1,with:1,from:1,are:1,was:1,has:1,have:1,its:1,you:1,your:1,can:1,may:1,but:1,try:1,then:1,they:1,been:1,will:1,into:1};
  // A short query must match every word. A long one (a whole message pasted or sent from the app) only has to match most of its words, since its names and numbers change.
  function prepare(toks) {
    if (toks.length <= 4) return { toks: toks, need: toks.length };
    var kept = toks.filter(function (t) { return t.length > 2 && !STOP[t]; });
    if (kept.length < 2) kept = toks;
    return { toks: kept, need: Math.max(2, Math.ceil(kept.length * 0.6)) };
  }
  function score(e, q) {
    var s = 0, matched = 0;
    for (var i = 0; i < q.toks.length; i++) {
      var t = q.toks[i], hit = 0;
      if (e._n0 === t) hit = 100;
      else if (e._n.indexOf(t) === 0) hit = 60;
      else if (e._n.indexOf(t) !== -1) hit = 40;
      else if (e._s.indexOf(t) !== -1) hit = 15;
      else if (e._x.indexOf(t) !== -1) hit = 8;
      if (hit) { matched++; s += hit; }
    }
    if (matched < q.need) return 0;
    if (e.t === "Error") s += 30; else if (e.t === "Message") s += 10;
    return s;
  }
  var timer;
  function run() {
    var q = box.value, toks = tokens(q), prep = prepare(toks);
    remember(q);
    if (!toks.length) { results.innerHTML = ""; status.textContent = ""; if (cards) cards.hidden = false; return; }
    if (cards) cards.hidden = true;
    load().then(function (idx) {
      var hits = [];
      idx.forEach(function (e) { var sc = score(e, prep); if (sc) hits.push([sc, e]); });
      hits.sort(function (a, b) { return b[0] - a[0]; });
      status.textContent = hits.length ? (hits.length + " found" + (hits.length > 60 ? ", showing the best 60" : "")) : "Nothing found. Try fewer or shorter words, or a word from the message.";
      results.innerHTML = hits.slice(0, 60).map(function (h) {
        var e = h[1];
        return '<a class="d-hit" href="' + esc(e.u) + '"><b>' + mark(e.n, toks) + '</b><small>' + esc(e.t) + ' · ' + mark(e.s, toks) + '</small>' + (e.x ? '<p>' + mark(e.x.slice(0, 220), toks) + (e.x.length > 220 ? "…" : "") + '</p>' : "") + '</a>';
      }).join("");
    });
  }
  box.addEventListener("input", function () { clearTimeout(timer); timer = setTimeout(run, 80); });
  box.addEventListener("focus", load);
  document.addEventListener("keydown", function (e) { if (e.key === "/" && document.activeElement !== box && !/INPUT|TEXTAREA/.test((document.activeElement || {}).tagName || "")) { e.preventDefault(); box.focus(); } });
  var initialQ = fromAddress();
  if (!initialQ && /[?&]search\b/.test(location.search)) box.focus();
  if (initialQ) { box.value = initialQ; run(); }
  window.addEventListener("hashchange", function () { var v = fromAddress(); if (v && v !== box.value) { box.value = v; run(); } });
})();
