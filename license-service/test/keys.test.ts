import { describe, expect, it } from 'vitest';
import { isManualKey, mintKey, normaliseManualKey, MANUAL_PREFIX } from '../src/keys';

describe('manual licence keys', () => {
  it('mints keys in the documented shape', () => {
    const key = mintKey();
    expect(key).toMatch(/^DP1-[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/);
    expect(isManualKey(key)).toBe(true);
  });

  it('round-trips every minted key through the checksum', () => {
    for (let i = 0; i < 500; i++) {
      const key = mintKey();
      expect(normaliseManualKey(key)).toBe(key);
    }
  });

  it('accepts a key typed without dashes or in lower case', () => {
    const key = mintKey();
    const mangled = key.replace(/-/g, '').toLowerCase().replace(/^dp1/, 'DP1-');
    expect(normaliseManualKey(mangled)).toBe(key);
  });

  it('repairs the confusable characters a human would mistype', () => {
    // O→0, I/L→1, U→V are the substitutions Crockford base32 defines. A key
    // read aloud and retyped should still validate.
    const key = mintKey();
    const body = key.slice(MANUAL_PREFIX.length).replace(/-/g, '');
    const mistyped = body.replace(/0/g, 'O').replace(/1/g, 'I');
    expect(normaliseManualKey(MANUAL_PREFIX + mistyped)).toBe(key);
  });

  it('rejects a key with a single altered character', () => {
    let caught = 0;
    for (let i = 0; i < 300; i++) {
      const key = mintKey();
      const body = [...key.slice(MANUAL_PREFIX.length).replace(/-/g, '')];
      const at = Math.floor(Math.random() * body.length);
      const original = body[at]!;
      body[at] = original === 'Z' ? 'Y' : 'Z';
      if (body.join('') === key.slice(MANUAL_PREFIX.length).replace(/-/g, '')) continue;
      if (normaliseManualKey(MANUAL_PREFIX + body.join('')) === null) caught++;
    }
    // The mod-37 checksum is not perfect, but it must catch the overwhelming
    // majority of single-character typos before we hit the database.
    expect(caught).toBeGreaterThan(280);
  });

  it('rejects keys of the wrong length or alphabet', () => {
    expect(normaliseManualKey('DP1-ABCD')).toBeNull();
    expect(normaliseManualKey('DP1-ABCD-EFGH-JKMN-PQRS-TVWX')).toBeNull();
    expect(normaliseManualKey('not-a-key')).toBeNull();
    expect(normaliseManualKey('')).toBeNull();
  });

  it('does not mistake a Dodo UUID key for one of ours', () => {
    expect(isManualKey('2b1f8e2d-c41e-4e8f-b2d3-d9fd61c38f43')).toBe(false);
    expect(normaliseManualKey('2b1f8e2d-c41e-4e8f-b2d3-d9fd61c38f43')).toBeNull();
  });
});
