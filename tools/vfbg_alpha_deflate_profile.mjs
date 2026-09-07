#!/usr/bin/env node
// Offline VFBG alpha deflate comparison. Reads one fixture and writes only JSON
// statistics to stdout; it never writes image or alpha data.
import { closeSync, fstatSync, openSync, readSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { deflateSync, inflateSync } from 'node:zlib';

const HEADER_BYTES = 20;
const MAX_PIXEL_BYTES = 64 * 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function readBoundedRegularFile(path) {
  const fd = openSync(path, 'r');
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) fail('input must be a regular file');
    if (stat.size < HEADER_BYTES || stat.size > MAX_PIXEL_BYTES + 24) {
      fail('input file length is outside bounded limit');
    }
    const bytes = Buffer.allocUnsafe(stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const count = readSync(fd, bytes, offset, bytes.length - offset, offset);
      if (count === 0) fail('input file changed while it was read');
      offset += count;
    }
    if (readSync(fd, Buffer.allocUnsafe(1), 0, 1, bytes.length) !== 0) {
      fail('input file grew while it was read');
    }
    return bytes;
  } finally {
    closeSync(fd);
  }
}

function readVfbg(bytes) {
  if (!bytes.subarray(0, 8).equals(Buffer.from([0x56, 0x46, 0x42, 0x47, 1, 1, 0, 0]))) {
    fail('unsupported VFBG header');
  }
  const width = bytes.readUInt32BE(8);
  const height = bytes.readUInt32BE(12);
  const stride = bytes.readUInt32BE(16);
  const row = width * 4;
  if (!width || !height || !Number.isSafeInteger(row) || stride < row) {
    fail('invalid VFBG dimensions or stride');
  }
  const payloadBytes = stride * height;
  if (!Number.isSafeInteger(payloadBytes) || payloadBytes !== bytes.length - HEADER_BYTES) {
    fail('VFBG payload size does not match stride times height');
  }
  const alpha = Buffer.allocUnsafe(width * height);
  let at = 0;
  for (let y = 0; y < height; y += 1) {
    const offset = HEADER_BYTES + y * stride;
    for (let x = 0; x < row; x += 4) {
      const blue = bytes[offset + x];
      const green = bytes[offset + x + 1];
      const red = bytes[offset + x + 2];
      const value = bytes[offset + x + 3];
      if (blue > value || green > value || red > value) fail('VFBG pixels are not premultiplied');
      alpha[at++] = value;
    }
  }
  return { format: 'VFBG', width, height, stride, alpha };
}

function readVfar(bytes) {
  if (bytes.length < 24 || !bytes.subarray(0, 4).equals(Buffer.from('VFAR'))) fail('invalid VFAR header');
  if (bytes[4] !== 1 || (bytes[5] !== 0 && bytes[5] !== 1) || bytes.readUInt16BE(6) !== 0) {
    fail('unsupported VFAR v1 header');
  }
  const width = bytes.readUInt32BE(8);
  const height = bytes.readUInt32BE(12);
  const decodedBytes = Number(bytes.readBigUInt64BE(16));
  const count = width * height;
  if (!width || !height || width > 8192 || height > 8192 || !Number.isSafeInteger(count) ||
      count > MAX_PIXEL_BYTES || decodedBytes !== count) fail('VFAR dimensions or declared size exceed bounds');
  const payload = bytes.subarray(24);
  let alpha;
  if (bytes[5] === 0) {
    if (payload.length !== count) fail('VFAR raw payload length mismatch');
    alpha = Buffer.from(payload);
  } else {
    alpha = Buffer.allocUnsafe(count);
    let input = 0;
    let output = 0;
    while (output < count) {
      if (input >= payload.length) fail('VFAR truncated run');
      const control = payload[input++];
      const run = (control & 0x7f) + 1;
      if (run > count - output) fail('VFAR run overflows output');
      if (control & 0x80) {
        if (input >= payload.length) fail('VFAR truncated repeat');
        alpha.fill(payload[input++], output, output + run);
      } else {
        if (payload.length - input < run) fail('VFAR truncated literal');
        payload.copy(alpha, output, input, input + run);
        input += run;
      }
      output += run;
    }
    if (input !== payload.length) fail('VFAR trailing bytes');
  }
  return { format: 'VFAR', width, height, stride: null, alpha };
}

function readInput(path) {
  const bytes = readBoundedRegularFile(path);
  const decoded = bytes.subarray(0, 4).equals(Buffer.from('VFBG')) ? readVfbg(bytes) : readVfar(bytes);
  return { ...decoded, fixture_sha256: createHash('sha256').update(bytes).digest('hex') };
}

function elapsedUs(start) {
  return Number(process.hrtime.bigint() - start) / 1000;
}

function profile(alpha, level) {
  const encodeStarted = process.hrtime.bigint();
  const compressed = deflateSync(alpha, { level });
  const encodeUs = elapsedUs(encodeStarted);
  const decodeStarted = process.hrtime.bigint();
  const decoded = inflateSync(compressed, { maxOutputLength: alpha.length });
  const decodeUs = elapsedUs(decodeStarted);
  if (!decoded.equals(alpha)) fail(`deflate level ${level} changed alpha bytes`);
  return { level, bytes: compressed.length, encode_us: encodeUs, decode_us: decodeUs, roundtrip: 'exact' };
}

if (process.argv.length !== 3) {
  console.error('usage: node tools/vfbg_alpha_deflate_profile.mjs VFBG_OR_VFAR_FILE');
  process.exit(2);
}
try {
  const fixture = readInput(process.argv[2]);
  console.log(JSON.stringify({
    format: fixture.format,
    fixture_sha256: fixture.fixture_sha256,
    width: fixture.width,
    height: fixture.height,
    stride: fixture.stride,
    alpha_bytes: fixture.alpha.length,
    deflate: [1, 3, 6].map((level) => profile(fixture.alpha, level)),
  }));
} catch (error) {
  console.error(`alpha deflate profile: ${error.message}`);
  process.exit(1);
}
