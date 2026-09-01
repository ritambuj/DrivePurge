/* ─────────────────────────────────────────────────────────────────────────
   DrivePurge landing page — the two interactive pieces of the design:
   the hero disk map (a squarified treemap) and the "safe to delete" chips.
   No dependencies, no build step.
   ───────────────────────────────────────────────────────────────────────── */

(function () {
  'use strict';

  var SCANNED_GB = 226.9;

  /* The example disk, as shown in the design. `safe` marks the categories
     DrivePurge would flag as safe to remove — those are drawn in the accent. */
  var TILES = [
    { name: 'App support files', gb: 43.5, safe: false },
    { name: 'Developer files',   gb: 22.0, safe: true  },
    { name: 'Apps',              gb: 18.6, safe: false },
    { name: 'Photos',            gb: 15.2, safe: false },
    { name: 'Videos',            gb: 12.4, safe: false },
    { name: 'App caches',        gb: 11.8, safe: true  },
    { name: 'macOS system',      gb: 11.9, safe: false },
    { name: 'Old backups',       gb:  9.3, safe: true  },
    { name: 'Duplicate photos',  gb:  7.9, safe: true  },
    { name: 'Downloads',         gb:  5.1, safe: true  },
    { name: 'Trash',             gb:  1.4, safe: true  },
    { name: 'Documents',         gb:  3.4, safe: false }
  ];

  var CHIPS = [
    ['App caches', 11.8], ['Old downloads', 9.1], ['Leftover installers', 3.7],
    ['Duplicate photos', 6.4], ['Large videos', 12.4], ['Old backups', 8.1],
    ['Unused apps', 4.2], ['Mail attachments', 2.4], ['Trash', 3.8],
    ['Developer files', 18.4]
  ];

  var CHIPS_ON_BY_DEFAULT = { 'App caches': true, 'Old downloads': true, 'Large videos': true };

  /* Neutral ramp for the "leave this alone" blocks, cycled by position so
     neighbouring rectangles never share a value. */
  var NEUTRAL_RAMP = [
    'var(--color-neutral-900)', 'var(--color-neutral-700)', 'var(--color-neutral-800)',
    'var(--color-neutral-900)', 'var(--color-neutral-700)', 'var(--color-neutral-800)'
  ];

  /* — squarified treemap ─────────────────────────────────────────────────
     Bruls, Huizing & van Wijk. Items are laid out into rows/columns whose
     rectangles stay as close to square as the values allow. Coordinates come
     out as percentages of a 100×100 box, so the map is purely CSS-scaled. */
  function squarify(items, W, H) {
    var out = [];
    var x = 0, y = 0, w = W, h = H;
    var remaining = items.reduce(function (s, i) { return s + i.gb; }, 0);
    var k = 0;

    function worst(row, sum) {
      var frac = sum / remaining;
      var len = (w >= h ? w : h) * frac;
      var other = (w >= h ? h : w);
      var ratio = 1;
      row.forEach(function (it) {
        var seg = other * (it.gb / sum);
        if (seg <= 0 || len <= 0) { ratio = Infinity; return; }
        ratio = Math.max(ratio, Math.max(len / seg, seg / len));
      });
      return ratio;
    }

    while (k < items.length && remaining > 0) {
      var row = [], sum = 0, best = Infinity, j = k;
      while (j < items.length) {
        var candidate = sum + items[j].gb;
        var ratio = worst(row.concat([items[j]]), candidate);
        if (!row.length || ratio <= best) {
          row.push(items[j]); sum = candidate; best = ratio; j++;
        } else break;
      }

      var frac = sum / remaining;
      if (w >= h) {
        var rw = w * frac, ry = y;
        row.forEach(function (it) {
          var rh = h * (it.gb / sum);
          out.push({ item: it, x: x, y: ry, w: rw, h: rh });
          ry += rh;
        });
        x += rw; w -= rw;
      } else {
        var rh2 = h * frac, rx = x;
        row.forEach(function (it) {
          var rw2 = w * (it.gb / sum);
          out.push({ item: it, x: rx, y: y, w: rw2, h: rh2 });
          rx += rw2;
        });
        y += rh2; h -= rh2;
      }
      remaining -= sum;
      k = j;
    }
    return out;
  }

  /* — hero disk map ──────────────────────────────────────────────────────── */

  function mountDiskMap() {
    var canvas = document.getElementById('diskmap-canvas');
    var readout = document.getElementById('diskmap-readout');
    var fill = document.getElementById('diskmap-fill');
    var total = document.getElementById('diskmap-total');
    if (!canvas) return;

    var queued = Object.create(null);
    var rects = squarify(TILES.slice().sort(function (a, b) { return b.gb - a.gb; }), 100, 100);
    var nodes = [];

    rects.forEach(function (r, index) {
      var t = r.item;

      var el = document.createElement('button');
      el.type = 'button';
      el.className = 'tile';
      el.style.left = r.x + '%';
      el.style.top = r.y + '%';
      el.style.width = r.w + '%';
      el.style.height = r.h + '%';

      var name = document.createElement('span');
      name.className = 'tile-name';
      name.textContent = (r.w > 11 && r.h > 9) ? t.name : '';
      el.appendChild(name);

      var size = document.createElement('span');
      size.className = 'tile-size';
      size.textContent = (r.w > 20 && r.h > 16) ? t.gb.toFixed(1) + ' GB' : '';
      el.appendChild(size);

      var action = document.createElement('span');
      action.className = 'tile-action';
      action.hidden = true;
      var badge = document.createElement('span');
      action.appendChild(badge);
      el.appendChild(action);

      var roomyEnoughForAction = r.w > 16 && r.h > 18;

      function describe() {
        return t.name + ' · ' + t.gb.toFixed(1) + ' GB' +
               (t.safe ? ' · safe to remove' : '') +
               (queued[t.name] ? ' · selected' : '');
      }

      function paint() {
        var isQueued = !!queued[t.name];
        var hovered = el.matches(':hover, :focus-visible');
        el.classList.toggle('is-queued', isQueued);
        el.style.background = isQueued
          ? 'var(--color-accent-200)'
          : t.safe
            ? (hovered ? 'var(--color-accent-600)' : 'var(--color-accent)')
            : NEUTRAL_RAMP[index % NEUTRAL_RAMP.length];
        el.style.color = isQueued ? 'var(--color-accent-800)' : 'var(--color-bg)';
        badge.textContent = isQueued ? 'Selected ✓' : 'Clean';
        action.hidden = !(hovered && roomyEnoughForAction);
        el.setAttribute('aria-pressed', String(isQueued));
        el.setAttribute('aria-label', describe());
      }

      function enter() { readout.textContent = t.name + ' · ' + t.gb.toFixed(1) + ' GB'; paint(); }
      function leave() { readout.textContent = 'Point at a block to see its size'; paint(); }

      el.addEventListener('mouseenter', enter);
      el.addEventListener('focus', enter);
      el.addEventListener('mouseleave', leave);
      el.addEventListener('blur', leave);
      el.addEventListener('click', function () {
        if (queued[t.name]) delete queued[t.name]; else queued[t.name] = true;
        render();
      });

      nodes.push(paint);
      canvas.appendChild(el);
    });

    function render() {
      nodes.forEach(function (paint) { paint(); });
      var gb = Object.keys(queued).reduce(function (s, key) {
        var t = TILES.filter(function (x) { return x.name === key; })[0];
        return s + (t ? t.gb : 0);
      }, 0);
      // A queued sliver still deserves a visible sliver of bar.
      fill.style.width = Math.min(100, gb / SCANNED_GB * 100 + (gb ? 2 : 0)) + '%';
      total.textContent = gb ? gb.toFixed(1) + ' GB selected' : 'Nothing selected yet';
      total.classList.toggle('is-active', gb > 0);
    }

    render();
  }

  /* — "safe to delete" chips ─────────────────────────────────────────────── */

  function mountChips() {
    var host = document.getElementById('chips');
    var summary = document.getElementById('chip-summary');
    if (!host) return;

    var on = Object.create(null);
    Object.keys(CHIPS_ON_BY_DEFAULT).forEach(function (k) { on[k] = true; });

    CHIPS.forEach(function (entry) {
      var name = entry[0], gb = entry[1];

      var chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'chip';

      var label = document.createElement('span');
      label.textContent = name;
      chip.appendChild(label);

      var size = document.createElement('span');
      size.className = 'chip-size';
      size.textContent = gb.toFixed(1) + ' GB';
      chip.appendChild(size);

      chip.addEventListener('click', function () {
        if (on[name]) delete on[name]; else on[name] = true;
        render();
      });

      chip.dataset.name = name;
      host.insertBefore(chip, summary);
    });

    function render() {
      var selected = CHIPS.filter(function (c) { return on[c[0]]; });
      Array.prototype.forEach.call(host.querySelectorAll('.chip'), function (chip) {
        chip.setAttribute('aria-pressed', String(!!on[chip.dataset.name]));
      });
      var gb = selected.reduce(function (s, c) { return s + c[1]; }, 0);
      summary.textContent = gb > 0
        ? gb.toFixed(1) + ' GB in ' + selected.length + ' categories — all safe to remove'
        : 'Pick a category to see how much space it is using';
    }

    render();
  }

  mountDiskMap();
  mountChips();
})();
