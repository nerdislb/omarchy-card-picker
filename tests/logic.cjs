// node tests/logic.cjs: the picker's pure logic (Logic.js), without a shell.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const ctx = { module: {} };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(root, 'Logic.js'), 'utf8').replace('.pragma library', ''), ctx);
const L = ctx.module.exports;
let checks = 0;
const check = (label, fn) => { fn(); checks++; console.log('PASS ' + label); };
const plain = x => JSON.parse(JSON.stringify(x));

const rows = [
  '/s/backgrounds/1-rauchband.jpg\t/c/aaa.jpg',
  '/s/backgrounds/2-regenglas.jpg\t/c/bbb.jpg',
  '/s/backgrounds/3-rauchquarz.jpg\t/c/ccc.jpg',
  '/s/backgrounds/4-nebel-bewegt.mp4\t/c/ddd.jpg',
  'broken line without a tab',
  '',
].join('\n');

check('rows: Omarchy order, titles, video flag; broken lines skipped', () => {
  const e = L.parseRows(rows);
  assert.equal(e.length, 4);
  assert.deepEqual(plain(e.map(x => [x.name, x.title, x.order, x.video])), [
    ['1-rauchband', 'Rauchband', 0, false], ['2-regenglas', 'Regenglas', 1, false],
    ['3-rauchquarz', 'Rauchquarz', 2, false], ['4-nebel-bewegt', 'Nebel Bewegt', 3, true]]);
  assert.equal(L.isAnimated('/x/a.webp'), true);
});

check('favourite keys: a theme by name, a background by theme and file (one applied folder for all themes)', () => {
  const [a] = L.parseRows(rows);
  assert.equal(L.favKey('theme', 'smoke', { name: 'smoke' }), 'smoke');
  assert.equal(L.favKey('wallpaper', 'smoke', a), 'smoke/1-rauchband.jpg');
  assert.notEqual(L.favKey('wallpaper', 'frost', a), L.favKey('wallpaper', 'smoke', a));
  assert.notEqual(L.favKey('wallpaper', 'smoke', a), L.favKey('wallpaper', 'smoke', {path:'/home/test/.config/omarchy/backgrounds/smoke/1-rauchband.jpg'}));
});

check('colour keys from ImageMagick histograms', () => {
  // dark picture with a copper glow: copper, not grey
  const copper = L.colourKey('   700: (6,6,8) #060608 srgb(6,6,8);    90: (190,110,50) #BE6E32 srgb(190,110,50);    30: (30,30,32) #1E1E20 srgb(30,30,32);');
  assert.equal(copper.grey, false);
  assert(copper.hue > 15 && copper.hue < 40, 'copper hue ' + copper.hue);
  const ice = L.colourKey('500: (120,192,228) #78C0E4 srgb;\n300: (240,244,248) #F0F4F8 srgb;');
  assert(ice.hue > 185 && ice.hue < 215, 'ice hue ' + ice.hue);
  const silver = L.colourKey('600: (200,202,206) #C8CACE gray;300: (150,152,156) #96989C gray;');
  assert.equal(silver.grey, true, 'a barely tinted picture is grey');
  assert.equal(L.colourKey(''), null);
});

check('sort: name keeps Omarchy order; colour runs round the hue wheel, greys last (light to dark); newest first', () => {
  const e = L.parseRows(rows);
  const colours = { '/c/aaa.jpg': { hue: 25, grey: false, light: 0.1 }, '/c/bbb.jpg': { hue: 200, grey: false, light: 0.2 },
                    '/c/ccc.jpg': { grey: true, light: 0.3 }, '/c/ddd.jpg': { grey: true, light: 0.8 } };
  assert.deepEqual(plain(L.sortEntries(e, 'name').map(x => x.order)), [0, 1, 2, 3]);
  assert.deepEqual(plain(L.sortEntries(e, 'colour', { colours }).map(x => x.order)), [0, 1, 3, 2]);
  assert.deepEqual(plain(L.sortEntries(e, 'colour', { colours: { '/c/bbb.jpg': colours['/c/bbb.jpg'] } }).map(x => x.order)), [1, 0, 2, 3], 'unknown colours last, in order');
  const mtimes = { '/s/backgrounds/1-rauchband.jpg': 10, '/s/backgrounds/3-rauchquarz.jpg': 30 };
  assert.deepEqual(plain(L.sortEntries(e, 'newest', { mtimes }).map(x => x.order)), [2, 0, 1, 3]);
  assert.deepEqual(plain(e.map(x => x.order)), [0, 1, 2, 3], 'the input is not reordered');
  assert.equal(L.nextSort('name'), 'colour'); assert.equal(L.nextSort('newest'), 'name'); assert.equal(L.nextSort('?'), 'name');
});

check('visible: favourites view and the typed filter', () => {
  const e = L.parseRows(rows);
  const favs = ['smoke/2-regenglas.jpg', 'frost/1-rauchband.jpg'];
  const v = L.visibleEntries(e, { mode: 'wallpaper', theme: 'smoke', view: 'favourites', favourites: favs });
  assert.deepEqual(plain(v.map(x => x.name)), ['2-regenglas'], 'another theme\'s favourite of the same file does not count');
  assert.deepEqual(plain(L.visibleEntries(e, { mode: 'wallpaper', theme: 'smoke', filter: 'RAUCH' }).map(x => x.name)), ['1-rauchband', '3-rauchquarz']);
  assert.deepEqual(plain(L.toggled(['a'], 'b')), ['a', 'b']);
  assert.deepEqual(plain(L.toggled(['a', 'b'], 'a')), ['b']);
});

check('state: defaults, unknown values fall back, broken JSON is empty', () => {
  const d = L.readState('');
  assert.deepEqual(plain(d), { version: 1, sort: { theme: 'name', wallpaper: 'name' }, live: false, favourites: { theme: [], wallpaper: [] }, colours: {} });
  const s = L.readState(JSON.stringify({ sort: { theme: 'colour', wallpaper: 'loud' }, live: true, favourites: { theme: ['tusche', 3] } }));
  assert.equal(s.sort.theme, 'colour'); assert.equal(s.sort.wallpaper, 'name'); assert.equal(s.live, true);
  assert.deepEqual(plain(s.favourites), { theme: ['tusche', '3'], wallpaper: [] });
  assert.deepEqual(plain(L.readState('{not json')), plain(d));
});

check('grow: from the card, through the middle (a little larger), to the full screen; glow peaks in between', () => {
  const card = [800, 600, 288, 409], screen = [0, 0, 1920, 1080];
  assert.deepEqual(plain(L.growRect(card, screen, 0)), card);
  const mid = L.growRect(card, screen, 0.4);
  assert(Math.abs(mid[0] + mid[2] / 2 - 960) < 0.01 && Math.abs(mid[1] + mid[3] / 2 - 540) < 0.01, 'centred');
  assert(Math.abs(mid[2] - card[2] * 1.12) < 0.01);
  assert.deepEqual(plain(L.growRect(card, screen, 1)), screen);
  let last = 0;
  for (let i = 0; i <= 100; i++) { const r = L.growRect(card, screen, i / 100); assert(r[2] >= last - 1e-9, 'never shrinks'); last = r[2]; }
  assert(L.growGlow(0.42) > 0.2 && L.growGlow(0) < 0.001 && L.growGlow(1) < 0.001);
});

console.log(checks + ' logic checks passed');
