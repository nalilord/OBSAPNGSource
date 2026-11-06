// Generated artwork and pixel checks for OBSRenderProbe; Node.js built-ins only.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const width = 508, height = 286;
const colors = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]];
function frame(color, premultiplied) {
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    let rgba = [0, 0, 0, 0];
    if (Math.min(x, y, width - x - 1, height - y - 1) < 8) rgba = color;
    else if (x >= 20 && x < 40 && y >= 20 && y < 40)
      rgba = premultiplied ? [60, 40, 20, 128] : [120, 80, 40, 128];
    pixels.set(rgba, (y * width + x) * 4);
  }
  return pixels;
}
const crcTable = Array.from({length: 256}, (_, i) => {
  let c = i;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function chunk(type, data = Buffer.alloc(0)) {
  const out = Buffer.alloc(data.length + 12);
  out.writeUInt32BE(data.length);
  out.write(type, 4, 4, 'ascii');
  data.copy(out, 8);
  let crc = 0xffffffff;
  for (const b of out.subarray(4, out.length - 4)) crc = crcTable[(crc ^ b) & 255] ^ (crc >>> 8);
  out.writeUInt32BE((crc ^ 0xffffffff) >>> 0, out.length - 4);
  return out;
}
function generate(file) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  const animation = Buffer.alloc(8); animation.writeUInt32BE(colors.length);
  const chunks = [Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('acTL', animation)];
  let sequence = 0;
  colors.forEach((color, index) => {
    const control = Buffer.alloc(26);
    control.writeUInt32BE(sequence++); control.writeUInt32BE(width, 4); control.writeUInt32BE(height, 8);
    control.writeUInt16BE(3, 20); control.writeUInt16BE(10, 22);
    chunks.push(chunk('fcTL', control));
    const pixels = frame(color, false), rows = Buffer.alloc((width * 4 + 1) * height);
    for (let y = 0; y < height; y++) pixels.copy(rows, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
    const data = zlib.deflateSync(rows);
    if (index === 0) chunks.push(chunk('IDAT', data));
    else {
      const prefix = Buffer.alloc(4); prefix.writeUInt32BE(sequence++);
      chunks.push(chunk('fdAT', Buffer.concat([prefix, data])));
    }
  });
  chunks.push(chunk('IEND'));
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, Buffer.concat(chunks));
}
function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function verify(directory) {
  const expected = new Set(colors.map(color => digest(frame(color, true))));
  for (const [speed, min, max] of [[50, 6, 9], [100, 13, 17], [200, 28, 33]]) {
    const hashes = Array.from({length: 45}, (_, i) => {
      const pixels = fs.readFileSync(path.join(directory, `speed-${speed}`, `render-${i}.rgba`));
      assert.equal(pixels.length, width * height * 4);
      const hash = digest(pixels);
      assert.ok(expected.has(hash), `${speed}% capture ${i}: rendered pixels differ from the expected fixture`);
      return hash;
    });
    assert.deepEqual(new Set(hashes), expected, `${speed}%: not all frames were displayed`);
    const transitions = hashes.slice(1).filter((hash, i) => hash !== hashes[i]).length;
    assert.ok(transitions >= min && transitions <= max, `${speed}%: unexpected transition count ${transitions}`);
    console.log(`PASS: ${speed}%: 45 pixel-exact captures, ${transitions} frame transitions`);
  }
}
const [command, target] = process.argv.slice(2);
if (!target || !['generate', 'verify'].includes(command))
  throw new Error('Usage: node render-fixture.cjs generate fixture.apng | verify capture-root');
if (command === 'generate') generate(target);
else verify(target);
